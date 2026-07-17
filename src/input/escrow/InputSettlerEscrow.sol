// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import { Address } from "openzeppelin/utils/Address.sol";

import { EIP712 } from "openzeppelin/utils/cryptography/EIP712.sol";
import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { IERC3009 } from "../../interfaces/IERC3009.sol";

import { IInputCallback } from "../../interfaces/IInputCallback.sol";
import { IInputOracle } from "../../interfaces/IInputOracle.sol";
import { IInputSettlerEscrow } from "../../interfaces/IInputSettlerEscrow.sol";

import { BytesLib } from "../../libs/BytesLib.sol";
import { IsContractLib } from "../../libs/IsContractLib.sol";
import { LibAddress } from "../../libs/LibAddress.sol";

import { MandateOutput } from "../types/MandateOutputType.sol";
import { OrderPurchase } from "../types/OrderPurchaseType.sol";
import { StandardOrder, StandardOrderType } from "../types/StandardOrderType.sol";

import { InputSettlerPurchase } from "../InputSettlerPurchase.sol";
import { Permit2WitnessType } from "./Permit2WitnessType.sol";

/**
 * @title OIF Input Settler supporting using an explicit escrow.
 * @notice This implementation contains an escrow to manage input assets. Intents are initiated by
 * depositing assets through either `::open` by msg.sender or `::openFor` by `order.user`. Since tokens are collected on
 * the `::open(For)` call, it is important to wait for the `::open(For)` call to be final before filling the intent.
 *
 * Using Permit2 to call `::openFor` with, `openDeadline` is identical to `order.fillDeadline`. Before calling
 * `::openFor` ensure there is sufficient time to fill.
 *
 * If an order has not been finalised / claimed before `order.expires`, anyone may call `::refund` to send
 * `order.inputs` to `order.user`. Note that if this is not done, an order finalised after `order.expires` still claims
 * `order.inputs` for the solver.
 */
contract InputSettlerEscrow is InputSettlerPurchase, IInputSettlerEscrow {
    using StandardOrderType for StandardOrder;
    using LibAddress for bytes32;
    using LibAddress for uint256;

    /**
     * @dev The order status is invalid.
     */
    error InvalidOrderStatus();
    /**
     * @dev Mismatch between the provided and computed order IDs.
     */
    error OrderIdMismatch(bytes32 provided, bytes32 computed);
    /**
     * @dev Mismatch between the number of inputs and signatures.
     */
    error SignatureAndInputsNotEqual();
    /**
     * @dev Reentrancy detected.
     */
    error ReentrancyDetected();
    /**
     * Signature type not supported.
     */
    error SignatureNotSupported(bytes1);
    /**
     * @dev The provided output index is out of bounds for the order's outputs array.
     */
    error OutputIndexOutOfBounds(uint256 index, uint256 length);
    /**
     * @dev An ERC-3009 collection did not increase this contract's token balance by exactly the input amount.
     */
    error InvalidBalanceDelta(uint256 expectedBalance, uint256 actualBalance);
    /**
     * @dev The attached msg.value does not exactly match the sum of the order's native inputs.
     */
    error InvalidNativeValue(uint256 expected, uint256 actual);
    /**
     * @dev A native (token 0) input is not supported on this code path or by this settler variant.
     */
    error NativeTokenNotSupported();
    /**
     * @dev `order.user` is the zero address. The user is the refund recipient; a zero user would burn refunds.
     */
    error UserIsZero();

    /**
     * @notice Emitted when an order is opened.
     * @param orderId The order identifier.
     * @param order The order.
     */
    event Open(bytes32 indexed orderId, StandardOrder order);

    /**
     * @notice Emitted when an order is refunded.
     * @param orderId The order identifier.
     */
    event Refunded(bytes32 indexed orderId);

    /// Signature types allowed.
    bytes1 internal constant SIGNATURE_TYPE_PERMIT2 = 0x00;
    bytes1 internal constant SIGNATURE_TYPE_3009 = 0x01;
    bytes1 internal constant SIGNATURE_TYPE_SELF = 0xff;

    enum OrderStatus {
        None,
        Deposited,
        Claimed,
        Refunded
    }

    mapping(bytes32 orderId => OrderStatus) public orderStatus;

    constructor() EIP712(_domainName(), _domainVersion()) { }

    /**
     * @notice Returns the domain name of the EIP712 signature.
     * @dev This function is only called in the constructor and the returned value is cached
     * by the EIP712 base contract.
     * @return name The domain name.
     */
    function _domainName() internal view virtual returns (string memory) {
        return "OIFEscrow";
    }

    /**
     * @notice Returns the domain version of the EIP712 signature.
     * @dev This function is only called in the constructor and the returned value is cached
     * by the EIP712 base contract.
     * @return version The domain version.
     */
    function _domainVersion() internal view virtual returns (string memory) {
        return "1";
    }

    /**
     * @notice Returns the Permit2 contract used to collect escrowed inputs.
     * @dev Defaults to the canonical cross-chain Permit2 deployment. Override on chains where Permit2 is deployed at a
     * different address (e.g. Tron, where CREATE2 address derivation differs from the EVM).
     * @return The Permit2 (ISignatureTransfer) contract.
     */
    function _PERMIT2() internal pure virtual returns (ISignatureTransfer) {
        return ISignatureTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    }

    // --- Generic order identifier --- //
    function orderIdentifier(
        StandardOrder calldata order
    ) external view returns (bytes32) {
        return order.orderIdentifier();
    }

    /**
     * @notice Opens an intent for `order.user`. `order.input` tokens are collected from msg.sender.
     * @dev Native inputs (token 0) are collected from msg.value, which must equal the sum of the order's native
     * input amounts exactly (msg.value must be 0 for orders without native inputs).
     * @param order StandardOrder representing the intent.
     */
    function open(
        StandardOrder calldata order
    ) external payable {
        // Validate the order structure.
        _validateInputChain(order.originChainId);
        _validateTimestampHasNotPassed(order.fillDeadline);
        _validateTimestampHasNotPassed(order.expires);
        _validateFillDeadlineBeforeExpiry(order.fillDeadline, order.expires);
        _validateUser(order.user);

        bytes32 orderId = order.orderIdentifier();

        if (orderStatus[orderId] != OrderStatus.None) revert InvalidOrderStatus();
        // Mark order as deposited. If we can't make the deposit, we will
        // revert and it will unmark it. This acts as a reentry check.
        orderStatus[orderId] = OrderStatus.Deposited;

        // Collect input tokens.
        _open(order);

        // Validate that there has been no reentrancy.
        if (orderStatus[orderId] != OrderStatus.Deposited) revert ReentrancyDetected();

        emit Open(orderId, order);
    }

    /**
     * @notice Returns whether this settler accepts native (token 0) inputs.
     * @dev Override to false on variants whose chain-native currency is out of scope (e.g. Tron, where the payout
     * hooks are ERC-20-only and native TRX support is not an intended feature).
     */
    function _nativeInputSupported() internal pure virtual returns (bool) {
        return true;
    }

    /**
     * @notice Validates that the order's user is non-zero.
     * @dev `order.user` is the refund recipient; refunds to the zero address would be burned.
     */
    function _validateUser(
        address user
    ) internal pure {
        if (user == address(0)) revert UserIsZero();
    }

    /**
     * @notice Collect input tokens directly from msg.sender.
     * @dev Two passes: the first validates identifiers and requires msg.value to equal the sum of native (token 0)
     * input amounts exactly, before any external call is made; the second pulls the ERC20 inputs. Native inputs are
     * push-based via msg.value — the exact-equality check makes msg.value the sole funding source, so the contract's
     * pooled (and force-feedable) ETH balance is never consulted.
     * @param order StandardOrder representing the intent.
     */
    function _open(
        StandardOrder calldata order
    ) internal {
        uint256[2][] calldata inputs = order.inputs;
        uint256 numInputs = inputs.length;

        // Pass 1: validate identifiers and establish the exact native value before any external interaction.
        uint256 nativeAmount;
        for (uint256 i = 0; i < numInputs; ++i) {
            uint256[2] calldata input = inputs[i];
            // Reverts on dirty upper bits: token 0 is the only representation of native.
            input[0].validatedCleanAddress();
            if (input[0] == 0) {
                if (!_nativeInputSupported()) revert NativeTokenNotSupported();
                // Checked arithmetic: an overflowing native sum reverts.
                nativeAmount += input[1];
            }
        }
        if (msg.value != nativeAmount) revert InvalidNativeValue(nativeAmount, msg.value);

        // Pass 2: collect the ERC20 inputs.
        for (uint256 i = 0; i < numInputs; ++i) {
            uint256[2] calldata input = inputs[i];
            if (input[0] == 0) continue;
            SafeERC20.safeTransferFrom(IERC20(input[0].validatedCleanAddress()), msg.sender, address(this), input[1]);
        }
    }

    /**
     * @notice Opens an intent for `order.user`. `order.input` tokens are collected from `sponsor` through transferFrom,
     * permit2 or ERC-3009.
     * @dev This function may make multiple sub-call calls either directly from this contract or from deeper inside the
     * call tree. To protect against reentry, the function uses the `orderStatus`. Local reentry (calling twice) is
     * protected through a checks-effect pattern while global reentry is enforced by not allowing existing the function
     * with `orderStatus` not set to `Deposited`
     * @param order StandardOrder representing the intent.
     * @param sponsor Address to collect tokens from.
     * @param signature Allowance signature from sponsor with a signature type encoded as:
     * - SIGNATURE_TYPE_PERMIT2:  b1:0x00 | bytes:signature
     * - SIGNATURE_TYPE_3009:     b1:0x01 | bytes:signature OR abi.encode(bytes[]:signatures)
     *
     * Native inputs (token 0) are only supported on the SIGNATURE_TYPE_SELF path (msg.sender == sponsor), funded by
     * msg.value. Native ETH cannot be pulled from a sponsor by signature: Permit2 and ERC-3009 are ERC20 mechanisms,
     * so those paths reject native inputs and any attached msg.value.
     */
    function openFor(
        StandardOrder calldata order,
        address sponsor,
        bytes calldata signature
    ) external payable {
        // Validate the order structure.
        _validateInputChain(order.originChainId);
        _validateTimestampHasNotPassed(order.fillDeadline);
        _validateTimestampHasNotPassed(order.expires);
        _validateFillDeadlineBeforeExpiry(order.fillDeadline, order.expires);
        _validateUser(order.user);

        bytes32 orderId = order.orderIdentifier();

        if (orderStatus[orderId] != OrderStatus.None) revert InvalidOrderStatus();
        // Mark order as deposited. If we can't make the deposit, we will
        // revert and it will unmark it. This acts as a reentry check.
        orderStatus[orderId] = OrderStatus.Deposited;

        // Check the first byte of the signature for signature type then collect inputs.
        bytes1 signatureType = signature.length > 0 ? signature[0] : SIGNATURE_TYPE_SELF;
        if (msg.sender == sponsor && signatureType == SIGNATURE_TYPE_SELF) {
            _open(order);
        } else if (msg.value != 0) {
            // Only the self path is funded by msg.value; stray value on signature paths would be stranded.
            revert InvalidNativeValue(0, msg.value);
        } else if (signatureType == SIGNATURE_TYPE_PERMIT2) {
            _openForWithPermit2(order, sponsor, signature[1:], address(this));
        } else if (signatureType == SIGNATURE_TYPE_3009) {
            _openForWithAuthorization(order.inputs, order.fillDeadline, sponsor, signature[1:], orderId);
        } else {
            revert SignatureNotSupported(signatureType);
        }

        // Validate that there has been no reentrancy.
        if (orderStatus[orderId] != OrderStatus.Deposited) revert ReentrancyDetected();

        emit Open(orderId, order);
    }

    /**
     * @notice Helper function for using permit2 to collect assets represented by a StandardOrder.
     * @param order StandardOrder representing the intent.
     * @param signer Provider of the permit2 funds and signer of the intent.
     * @param signature permit2 signature with Permit2Witness representing `order` signed by the `signer`.
     * @param to recipient of the inputs tokens. In most cases, should be address(this).
     */
    function _openForWithPermit2(
        StandardOrder calldata order,
        address signer,
        bytes calldata signature,
        address to
    ) internal {
        ISignatureTransfer.TokenPermissions[] memory permitted;
        ISignatureTransfer.SignatureTransferDetails[] memory transferDetails;

        {
            uint256[2][] calldata orderInputs = order.inputs;
            // Load the number of inputs. We need them to set the array size & convert each
            // input struct into a transferDetails struct.
            uint256 numInputs = orderInputs.length;
            permitted = new ISignatureTransfer.TokenPermissions[](numInputs);
            transferDetails = new ISignatureTransfer.SignatureTransferDetails[](numInputs);
            // Iterate through each input.
            for (uint256 i; i < numInputs; ++i) {
                uint256[2] calldata orderInput = orderInputs[i];
                uint256 inputToken = orderInput[0];
                uint256 amount = orderInput[1];

                // Dirty bits will be pruned when compared against the permit2 signature, however, they are still
                // considered in the orderId. By intentionally setting dirty bits, the caller of open will be able to
                // open the order with unexpected orderIds. To ensure there is a 1:1 map of signed Permit2 message to
                // order, dirty bits are explicitly checked for.
                // => This ensures a signed order can only have exactly 1 orderId.
                address token = inputToken.validatedCleanAddress();

                // Native ETH cannot be pulled by a Permit2 signature. This guard is load-bearing: a collection path
                // that marks an order Deposited without receiving ETH would let its finalise drain ETH escrowed for
                // other orders.
                if (token == address(0)) revert NativeTokenNotSupported();
                // Check if input tokens are contracts.
                IsContractLib.validateContainsCode(token);
                // Set the allowance. This is the explicit max allowed amount approved by the user.
                permitted[i] = ISignatureTransfer.TokenPermissions({ token: token, amount: amount });
                // Set our requested transfer. This has to be less than or equal to the allowance
                transferDetails[i] = ISignatureTransfer.SignatureTransferDetails({ to: to, requestedAmount: amount });
            }
        }
        ISignatureTransfer.PermitBatchTransferFrom memory permitBatch = ISignatureTransfer.PermitBatchTransferFrom({
            permitted: permitted, nonce: order.nonce, deadline: order.fillDeadline
        });
        _PERMIT2()
            .permitWitnessTransferFrom(
                permitBatch,
                transferDetails,
                signer,
                Permit2WitnessType.Permit2WitnessHash(order),
                Permit2WitnessType.PERMIT2_PERMIT2_TYPESTRING,
                signature
            );
    }

    /**
     * @notice Helper function for using ERC-3009 to collect assets represented by a StandardOrder.
     * @dev For the `receiveWithAuthorization` call, the nonce is set as the orderId to select the order associated with
     * the authorization.
     *
     * Every collection is strictly balance-checked: this contract's token balance must increase by exactly the input
     * amount or the call reverts with {InvalidBalanceDelta}. This is required on the ERC-3009 path in particular
     * because the single-input branch performs a raw `call` whose success would otherwise be trusted without any
     * evidence that tokens moved.
     * @param inputs Order inputs to be collected.
     * @param fillDeadline Deadline for calling the open function.
     * @param signer Provider of the ERC-3009 funds and signer of the intent.
     * @param _signature_ Either a single ERC-3009 signature or abi.encoded bytes[] of signatures. A single signature is
     * only allowed if the order has exactly 1 input.
     */
    function _openForWithAuthorization(
        uint256[2][] calldata inputs,
        uint32 fillDeadline,
        address signer,
        bytes calldata _signature_,
        bytes32 orderId
    ) internal {
        uint256 numInputs = inputs.length;
        // Native ETH cannot be pulled by an ERC-3009 authorization. As on the Permit2 path, this guard is
        // load-bearing: no collection path may mark an order Deposited without actually receiving its inputs.
        for (uint256 i; i < numInputs; ++i) {
            if (inputs[i][0] == 0) revert NativeTokenNotSupported();
        }
        if (numInputs == 1) {
            // If there is only 1 input, try using the provided signature as is.
            uint256[2] calldata input = inputs[0];
            bytes memory callData = abi.encodeCall(
                IERC3009.receiveWithAuthorization,
                (signer, address(this), input[1], 0, fillDeadline, orderId, _signature_)
            );
            // The above calldata encoding is equivalent to:
            // IERC3009(input[0].validatedCleanAddress().receiveWithAuthorization({
            //     from: signer,
            //     to: address(this),
            //     value: input[1],
            //     validAfter: 0,
            //     validBefore: fillDeadline,
            //     nonce: orderId,
            //     signature: _signature_
            // })
            address token = input[0].validatedCleanAddress();
            IsContractLib.validateContainsCode(token); // Ensure called contract has code.
            uint256 balanceBefore = IERC20(token).balanceOf(address(this));
            (bool success,) = token.call(callData);
            // If the call succeeded, require the exact balance increase.
            if (success) {
                _validateBalanceIncrease(token, balanceBefore, input[1]);
                return;
            }
            // Otherwise it could be because of a lot of reasons. One being the signature is abi.encoded as bytes[].
        }
        {
            uint256 numSignatures = BytesLib.getLengthOfBytesArray(_signature_);
            if (numInputs != numSignatures) revert SignatureAndInputsNotEqual();
        }
        for (uint256 i; i < numInputs; ++i) {
            uint256[2] calldata input = inputs[i];
            bytes calldata signature = BytesLib.getBytesOfArray(_signature_, i);
            address token = input[0].validatedCleanAddress();
            uint256 balanceBefore = IERC20(token).balanceOf(address(this));
            _receiveWithAuthorization(input, fillDeadline, signer, signature, orderId);
            _validateBalanceIncrease(token, balanceBefore, input[1]);
        }
    }

    function _receiveWithAuthorization(
        uint256[2] calldata input,
        uint32 fillDeadline,
        address signer,
        bytes calldata signature,
        bytes32 orderId
    ) private {
        // forgefmt: disable-next-line
        IERC3009(input[0].validatedCleanAddress()).receiveWithAuthorization({
            from: signer,
            to: address(this),
            value: input[1],
            validAfter: 0,
            validBefore: fillDeadline,
            nonce: orderId,
            signature: signature
        });
    }

    /**
     * @notice Validates that this contract's balance of `token` increased by exactly `amount` over `balanceBefore`.
     * @dev The expected balance is computed with checked arithmetic because `amount` is attacker-controlled.
     * @param token The collected token.
     * @param balanceBefore This contract's balance of `token` before the collection.
     * @param amount The exact increase required.
     */
    function _validateBalanceIncrease(
        address token,
        uint256 balanceBefore,
        uint256 amount
    ) internal view {
        uint256 expectedBalance = balanceBefore + amount;
        uint256 actualBalance = IERC20(token).balanceOf(address(this));
        if (actualBalance != expectedBalance) revert InvalidBalanceDelta(expectedBalance, actualBalance);
    }

    // --- Refund --- //

    /**
     * @notice Refunds an order that has not been finalised before it expired. This order may have been filled but
     * finalise has not been called yet.
     * @param order StandardOrder description of the intent.
     */
    function refund(
        StandardOrder calldata order
    ) external {
        _validateInputChain(order.originChainId);
        _validateTimestampHasPassed(order.expires);

        bytes32 orderId = order.orderIdentifier();
        _resolveLock(orderId, order.inputs, order.user, OrderStatus.Refunded);
        emit Refunded(orderId);
    }

    /**
     * @notice Refunds an order as soon as any one of its outputs is proven not filled before the order's fill
     * deadline — without waiting for `order.expires`. The time-based `refund` remains available as the backstop.
     * @dev Permissionless; the inputs always go to `order.user`. Safe because:
     * - Fills are frozen after `order.fillDeadline`, so a proven non-fill is permanent.
     * - The proof hash is reconstructed from the signed `order.fillDeadline` (committed inside `orderId`), so
     *   attestations for fabricated deadlines are inert.
     * - `_resolveLock` requires `Deposited` and flips it: this and `finalise` can never both settle the same order.
     * - A single missing output suffices since `finalise` requires every output proven filled.
     * @param order StandardOrder description of the intent.
     * @param outputIndex Index of the output proven not filled.
     */
    function refundOnNonFill(
        StandardOrder calldata order,
        uint256 outputIndex
    ) external virtual {
        _validateInputChain(order.originChainId);
        _validateTimestampHasPassed(order.fillDeadline);

        if (outputIndex >= order.outputs.length) {
            revert OutputIndexOutOfBounds(outputIndex, order.outputs.length);
        }

        bytes32 orderId = order.orderIdentifier();
        _validateNonFill(order.fillDeadline, order.inputOracle, order.outputs[outputIndex], orderId);

        _resolveLock(orderId, order.inputs, order.user, OrderStatus.Refunded);
        emit Refunded(orderId);
    }

    // --- Finalise Orders --- //

    /**
     * @notice Finalise an order, paying the inputs to the solver.
     * @param order that has been filled.
     * @param orderId A unique identifier for the order.
     * @param solver Solver of the outputs.
     * @param destination Destination of the inputs funds signed for by the user.
     */
    function _finalise(
        StandardOrder calldata order,
        bytes32 orderId,
        bytes32 solver,
        bytes32 destination
    ) internal virtual {
        _resolveLock(orderId, order.inputs, destination.fromIdentifier(), OrderStatus.Claimed);
        emit Finalised(orderId, solver, destination);
    }

    /**
     * @notice Finalises an order when called directly by the solver
     * @dev Finalise is not blocked after the expiry of orders.
     * The caller must be the address corresponding to the first solver in the solvers array.
     * @param order StandardOrder description of the intent.
     * @param solveParams List of solve parameters for when the outputs were filled
     * @param destination Address to send the inputs to. If the solver wants to send the inputs to themselves, they
     * should pass their address to this parameter.
     * @param call Optional callback data. If non-empty, will call orderFinalised on the destination
     */
    function finalise(
        StandardOrder calldata order,
        SolveParams[] calldata solveParams,
        bytes32 destination,
        bytes calldata call
    ) external virtual {
        _validateDestination(destination);
        _validateInputChain(order.originChainId);

        bytes32 orderId = order.orderIdentifier();
        bytes32 orderOwner = _purchaseGetOrderOwner(orderId, solveParams);
        _orderOwnerIsCaller(orderOwner);

        _validateFills(order.fillDeadline, order.inputOracle, order.outputs, orderId, solveParams);

        _finalise(order, orderId, solveParams[0].solver, destination);

        if (call.length > 0) IInputCallback(destination.fromIdentifier()).orderFinalised(order.inputs, call);
    }

    /**
     * @notice Finalises a cross-chain order on behalf of someone else using their signature
     * @dev Finalise is not blocked after the expiry of orders.
     * This function serves to finalise intents on the origin chain with proper authorization from the order owner.
     * @param order StandardOrder description of the intent.
     * @param solveParams List of solve parameters for when the outputs were filled
     * @param destination Address to send the inputs to.
     * @param call Optional callback data. If non-empty, will call orderFinalised on the destination
     * @param orderOwnerSignature Signature from the order owner authorizing this external call
     */
    function finaliseWithSignature(
        StandardOrder calldata order,
        SolveParams[] calldata solveParams,
        bytes32 destination,
        bytes calldata call,
        bytes calldata orderOwnerSignature
    ) external virtual {
        // _validateDestination has been moved down to circumvent stack issue.
        _validateInputChain(order.originChainId);

        bytes32 orderId = order.orderIdentifier();

        {
            bytes32 orderOwner = _purchaseGetOrderOwner(orderId, solveParams);

            // Validate the external claimant with signature
            _validateDestination(destination);
            _allowExternalClaimant(orderId, orderOwner.fromIdentifier(), destination, call, orderOwnerSignature);
        }

        _validateFills(order.fillDeadline, order.inputOracle, order.outputs, orderId, solveParams);

        _finalise(order, orderId, solveParams[0].solver, destination);

        if (call.length > 0) IInputCallback(destination.fromIdentifier()).orderFinalised(order.inputs, call);
    }

    //--- Asset Lock & Escrow ---//

    /**
     * @dev This function employs a local reentry guard: we check the order status and then we update it afterwards.
     * This is an important check as it is intended to process external ERC20 transfers.
     * @param orderId The order identifier.
     * @param inputs The inputs to transfer.
     * @param destination The destination to transfer the inputs to.
     * @param newStatus specifies the new status to set the order to. Should never be `OrderStatus.Deposited`.
     */
    function _resolveLock(
        bytes32 orderId,
        uint256[2][] calldata inputs,
        address destination,
        OrderStatus newStatus
    ) internal virtual {
        // Check the order status:
        if (orderStatus[orderId] != OrderStatus.Deposited) revert InvalidOrderStatus();
        // Mark order as deposited. If we can't make the deposit, we will
        // revert and it will unmark it. This acts as a reentry check.
        orderStatus[orderId] = newStatus;

        // We have now ensured that this point can only be reached once. We can now process the asset delivery.
        uint256 numInputs = inputs.length;
        for (uint256 i; i < numInputs; ++i) {
            uint256[2] calldata input = inputs[i];
            _sendInputAsset(input[0], destination, input[1]);
        }
    }

    /**
     * @dev Pays out a single escrowed input, native or ERC20. Non-virtual on purpose: the token 0 branch must not be
     * bypassable by `_transfer` overrides (an ERC20-only override handed token 0 could "succeed" without moving
     * funds). Native payouts are push-only — a rejecting recipient reverts the whole resolution; for refunds this
     * means a reverting `order.user` blocks its own refund. Zero-amount native payouts are skipped so a recipient
     * without a receive function cannot block an otherwise valueless leg.
     * @param tokenId The input token identifier; 0 is native ETH.
     * @param destination The recipient of the asset.
     * @param amount The amount to transfer.
     */
    function _sendInputAsset(uint256 tokenId, address destination, uint256 amount) internal {
        if (tokenId == 0) {
            if (amount > 0) Address.sendValue(payable(destination), amount);
        } else {
            _transfer(tokenId.validatedCleanAddress(), destination, amount);
        }
    }

    /**
     * @dev Pays out a single escrowed ERC20 input. Virtual so subclasses can customise the outbound transfer for
     * non-standard tokens (e.g. {InputSettlerEscrowTron} for TRON USDT, whose `transfer` returns `false` on success).
     * Never called with the native sentinel; token 0 is handled by {_sendInputAsset}.
     * @param token The input token to transfer.
     * @param destination The recipient of the tokens.
     * @param amount The amount to transfer.
     */
    function _transfer(
        address token,
        address destination,
        uint256 amount
    ) internal virtual {
        SafeERC20.safeTransfer(IERC20(token), destination, amount);
    }

    // --- Purchase Order --- //

    /**
     * @notice This function is called to buy an order from a solver.
     * If the order was purchased in time, then when the order is settled, the inputs will go to the purchaser instead
     * of the original solver.
     * @param orderPurchase Order purchase description signed by solver.
     * @param order Order to purchase.
     * @param orderSolvedByIdentifier Solver of the order. Is not validated, if wrong the purchase will be skipped.
     * @param purchaser The new order owner.
     * @param expiryTimestamp Set to ensure if your transaction does not mine quickly, you don't end up purchasing an
     * order that you can not prove OR is outside the timeToBuy window.
     * @param solverSignature EIP712 Signature of OrderPurchase by orderOwner.
     */
    function purchaseOrder(
        OrderPurchase calldata orderPurchase,
        StandardOrder calldata order,
        bytes32 orderSolvedByIdentifier,
        bytes32 purchaser,
        uint256 expiryTimestamp,
        bytes calldata solverSignature
    ) external payable virtual {
        _validateInputChain(order.originChainId);
        _validateTimestampHasNotPassed(order.expires);
        bytes32 computedOrderId = order.orderIdentifier();
        // Sanity check to ensure the user thinks they are buying the right order.
        if (computedOrderId != orderPurchase.orderId) revert OrderIdMismatch(orderPurchase.orderId, computedOrderId);

        // Validate that the order has been opened.
        OrderStatus status = orderStatus[computedOrderId];
        if (status != OrderStatus.Deposited) revert InvalidOrderStatus();

        _validatePurchaseNativeValue(order.inputs, orderPurchase.discount);
        _purchaseOrder(
            orderPurchase, order.inputs, orderSolvedByIdentifier, purchaser, expiryTimestamp, solverSignature
        );
    }

    /**
     * @dev Requires msg.value to exactly fund every discounted native input before the purchase makes external calls.
     * This prevents a purchaser from paying a native-input solver with ETH pooled for other escrowed orders.
     */
    function _validatePurchaseNativeValue(uint256[2][] calldata inputs, uint256 discount) internal view {
        uint256 nativeAmount = 0;
        uint256 numInputs = inputs.length;
        for (uint256 i = 0; i < numInputs; ++i) {
            uint256[2] calldata input = inputs[i];
            if (input[0] == 0) {
                // Native inputs are deliberately rejected by Tron variants.
                // forge-lint: disable-next-line(require-revert-in-loop)
                if (!_nativeInputSupported()) revert NativeTokenNotSupported();
                nativeAmount += (input[1] * (DISCOUNT_DENOM - discount)) / DISCOUNT_DENOM;
            }
        }
        if (msg.value != nativeAmount) revert InvalidNativeValue(nativeAmount, msg.value);
    }

    /**
     * @inheritdoc InputSettlerPurchase
     * @dev Native purchase funds are pushed from the exact msg.value validated before {_purchaseOrder}; ERC20 funds
     * remain pull-based from msg.sender. Zero-value native sends are skipped for recipients without a receive hook.
     */
    function _transferInput(uint256 tokenId, address to, uint256 amount) internal virtual override {
        if (tokenId == 0) {
            if (!_nativeInputSupported()) revert NativeTokenNotSupported();
            // The exact-value guard makes msg.value, rather than pooled escrow, the source of this payment.
            // forge-lint: disable-next-line(arbitrary-send-eth)
            if (amount > 0) Address.sendValue(payable(to), amount);
        } else {
            super._transferInput(tokenId, to, amount);
        }
    }
}
