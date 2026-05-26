// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.26;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { InputSettlerEscrow } from "OIF/src/input/escrow/InputSettlerEscrow.sol";
import { MandateOutput } from "OIF/src/input/types/MandateOutputType.sol";
import { StandardOrder, StandardOrderType } from "OIF/src/input/types/StandardOrderType.sol";

import { IInputCallback } from "OIF/src/interfaces/IInputCallback.sol";
import { IInputOracle } from "OIF/src/interfaces/IInputOracle.sol";
import { LibAddress } from "OIF/src/libs/LibAddress.sol";

import { GovernanceFee } from "../../libs/GovernanceFee.sol";

/**
 * @title LIFI Input Settler supporting an explicit escrow
 * @notice This contract is implemented as an extension of the OIF
 * It inherits all of the functionality of InputSettlerEscrow but adds same chain swaps and governance fee.
 *
 * This contract does not support fee on transfer tokens.
 *
 * The ownable component of the smart contract is only used for fees.
 */
contract InputSettlerEscrowLIFI is InputSettlerEscrow, GovernanceFee {
    using LibAddress for address;
    using LibAddress for uint256;
    using LibAddress for bytes32;
    using StandardOrderType for bytes;
    using StandardOrderType for StandardOrder;

    /// @dev Simpler open event to reduce gas costs. Used specifically for openForAndFinalise.
    event Open(bytes32 indexed orderId);

    constructor(
        address initialOwner
    ) InputSettlerEscrow() {
        _initializeOwner(initialOwner);
    }

    /**
     * @notice Returns the domain name of the EIP712 signature.
     * @dev This function is only called in the constructor and the returned value is cached
     * by the EIP712 base contract.
     * @return name The domain name.
     */
    function _domainName() internal pure virtual override returns (string memory) {
        return "OIFEscrowLIFI";
    }

    /**
     * @notice Check if a series of outputs has been proven.
     * @dev An alternative to _validateFills that assumes the fills have been filled instantly and by the current
     * msg.sender.
     * Does not validate fillDeadline.
     */
    function _validateFillsNow(
        address inputOracle,
        MandateOutput[] calldata outputs,
        bytes32 orderId
    ) internal view {
        uint256 numOutputs = outputs.length;
        bytes memory proofSeries = new bytes(32 * 4 * numOutputs);
        for (uint256 i; i < numOutputs; ++i) {
            MandateOutput calldata output = outputs[i];
            bytes32 payloadHash = _proofPayloadHash(orderId, msg.sender.toIdentifier(), uint32(block.timestamp), output);

            uint256 chainId = output.chainId;
            bytes32 outputOracle = output.oracle;
            bytes32 outputSettler = output.settler;
            assembly ("memory-safe") {
                let offset := add(add(proofSeries, 0x20), mul(i, 0x80))
                mstore(offset, chainId)
                mstore(add(offset, 0x20), outputOracle)
                mstore(add(offset, 0x40), outputSettler)
                mstore(add(offset, 0x60), payloadHash)
            }
        }
        IInputOracle(inputOracle).efficientRequireProven(proofSeries);
    }

    /**
     * @dev This function can only be used when the intent described is a same-chain intent.
     * Set the solver as msg.sender (of this call). Timestamp will be collected from block.timestamp.
     */
    function openForAndFinalise(
        StandardOrder calldata order,
        address sponsor,
        bytes calldata signature,
        address destination,
        bytes calldata call
    ) external {
        // Validate the order structure.
        _validateInputChain(order.originChainId);
        _validateTimestampHasNotPassed(order.fillDeadline);
        _validateTimestampHasNotPassed(order.expires);
        _validateDestination(destination.toIdentifier());

        bytes32 orderId = order.orderIdentifier();

        if (orderStatus[orderId] != OrderStatus.None) revert InvalidOrderStatus();
        // Mark order as deposited. If we can't make the deposit, we will
        // revert and it will unmark it. This acts as a reentry check.
        orderStatus[orderId] = OrderStatus.Deposited;
        emit Open(orderId);

        // Send input tokens to the provided destination so the tokens can be used for secondary purposes.
        bytes1 signatureType = signature.length > 0 ? signature[0] : SIGNATURE_TYPE_SELF;
        if (signatureType == SIGNATURE_TYPE_PERMIT2) {
            _openForWithPermit2(order, sponsor, signature[1:], address(this));
        } else if (signatureType == SIGNATURE_TYPE_3009) {
            _openForWithAuthorization(order.inputs, order.fillDeadline, sponsor, signature[1:], orderId);
        } else {
            revert SignatureNotSupported(signatureType);
        }

        // There should be a validation that the order status is currently deposited, that is checked in the
        // _resolveLock.
        // Send tokens to solver.
        uint256[2][] calldata inputs = order.inputs;
        _resolveLock(orderId, inputs, destination, OrderStatus.Claimed);
        // Emit the finalise event to follow the normal finalise event emit.
        emit Finalised(orderId, msg.sender.toIdentifier(), destination.toIdentifier());

        // Call the destination (if needed) so the caller can inject logic into our call.
        if (call.length > 0) IInputCallback(destination).orderFinalised(inputs, call);

        // Validate the fill. The solver may use the reentrance of the above line to execute the fill.
        _validateFillsNow(order.inputOracle, order.outputs, orderId);
    }

    // --- Finalise Orders --- //

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
    ) external virtual override {
        _validateDestination(destination);
        _validateInputChain(order.originChainId);

        bytes32 orderId = order.orderIdentifier();
        bytes32 orderOwner = _purchaseGetOrderOwner(orderId, solveParams);
        _orderOwnerIsCaller(orderOwner);

        _finalise(order, orderId, solveParams[0].solver, destination);

        if (call.length > 0) IInputCallback(destination.fromIdentifier()).orderFinalised(order.inputs, call);

        _validateFills(order.fillDeadline, order.inputOracle, order.outputs, orderId, solveParams);
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
    ) external virtual override {
        // _validateDestination has been moved down to circumvent stack issue.
        _validateInputChain(order.originChainId);

        bytes32 orderId = order.orderIdentifier();

        {
            bytes32 orderOwner = _purchaseGetOrderOwner(orderId, solveParams);

            // Validate the external claimant with signature
            _validateDestination(destination);
            _allowExternalClaimant(orderId, orderOwner.fromIdentifier(), destination, call, orderOwnerSignature);
        }

        _finalise(order, orderId, solveParams[0].solver, destination);

        if (call.length > 0) IInputCallback(destination.fromIdentifier()).orderFinalised(order.inputs, call);

        _validateFills(order.fillDeadline, order.inputOracle, order.outputs, orderId, solveParams);
    }

    //--- Asset Locks ---//

    /**
     * @dev This function employs a local reentry guard: we check the order status and then we update it afterwards.
     * This is an important check as it is intended to process external ERC20 transfers.
     * @param newStatus specifies the new status to set the order to. Should never be OrderStatus.Deposited.
     */
    function _resolveLock(
        bytes32 orderId,
        uint256[2][] calldata inputs,
        address destination,
        OrderStatus newStatus
    ) internal virtual override {
        // Check the order status:
        if (orderStatus[orderId] != OrderStatus.Deposited) revert InvalidOrderStatus();
        // Mark order as deposited. If we can't make the deposit, we will
        // revert and it will unmark it. This acts as a reentry check.
        orderStatus[orderId] = newStatus;

        address _owner = owner();
        uint64 fee = _owner != address(0) ? governanceFee : 0;
        // We have now ensured that this point can only be reached once. We can now process the asset delivery.
        uint256 numInputs = inputs.length;
        for (uint256 i; i < numInputs; ++i) {
            uint256[2] memory input = inputs[i];
            address token = input[0].fromIdentifier();
            uint256 amount = input[1];

            uint256 calculatedFee = _calcFee(amount, fee);
            if (calculatedFee > 0) {
                _transfer(token, _owner, calculatedFee);
                unchecked {
                    amount = amount - calculatedFee;
                }
            }

            _transfer(token, destination, amount);
        }
    }

    function _transfer(address token, address to, uint256 amount) internal virtual {
        SafeTransferLib.safeTransfer(token, to, amount);
    }
}
