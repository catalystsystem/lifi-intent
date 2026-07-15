// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.26;

import { IdLib } from "the-compact/src/lib/IdLib.sol";
import { BatchClaim } from "the-compact/src/types/BatchClaims.sol";
import { BatchClaimComponent, Component } from "the-compact/src/types/Components.sol";

import { InputSettlerCompact } from "OIF/src/input/compact/InputSettlerCompact.sol";
import { StandardOrder, StandardOrderType } from "OIF/src/input/types/StandardOrderType.sol";
import { IInputCallback } from "OIF/src/interfaces/IInputCallback.sol";
import { LibAddress } from "OIF/src/libs/LibAddress.sol";

import { GovernanceFee } from "../../libs/GovernanceFee.sol";
import { RegisterIntentLib } from "../../libs/RegisterIntentLib.sol";

/**
 * @title LIFI Input Settler supporting The Compact
 * @notice This contract is implemented as an extension of the OIF InputSettlerCompact. It inherits all of the
 * functionality of InputSettlerCompact but adds broadcast, same chain swaps, and governance fee.
 *
 * This contract does not support fee on transfer tokens.
 *
 * The ownable component of the smart contract is only used for fees.
 */
contract InputSettlerCompactLIFI is InputSettlerCompact, GovernanceFee {
    using LibAddress for uint256;
    using LibAddress for bytes32;

    error NotRegistered();

    event IntentRegistered(bytes32 indexed orderId, StandardOrder order);

    constructor(
        address compact,
        address initialOwner
    ) InputSettlerCompact(compact) {
        _initializeOwner(initialOwner);
    }

    /**
     * @notice Returns the domain name of the EIP712 signature.
     * @dev This function is only called in the constructor and the returned value is cached
     * by the EIP712 base contract.
     * @return name The domain name.
     */
    function _domainName() internal pure override returns (string memory) {
        return "OIFCompactLIFI";
    }

    /**
     * @notice Validates that an intent has been registered against TheCompact and broadcasts and event for
     * permissionless consumption.
     * @param order Order to be broadcasts for consumption by off-chain solvers.
     */
    function broadcast(
        StandardOrder calldata order
    ) external {
        RegisterIntentLib._validateChain(order.originChainId);
        RegisterIntentLib._validateExpiry(order.fillDeadline, order.expires);

        bool registered = COMPACT.isRegistered(
            order.user,
            RegisterIntentLib.compactClaimHash(address(this), order),
            RegisterIntentLib.STANDARD_ORDER_BATCH_COMPACT_TYPE_HASH
        );
        if (!registered) revert NotRegistered();

        bytes32 orderId = _orderIdentifier(order);
        emit IntentRegistered(orderId, order);
    }

    /**
     * @notice Finalises an order when called directly by the solver
     * @dev The caller must be the address corresponding to the first solver in the solvers array.
     * @param order StandardOrder signed in conjunction with a Compact to form an order
     * @param signatures A signature for the sponsor and the allocator. abi.encode(bytes(sponsorSignature),
     * bytes(allocatorData))
     * @param solveParams List of solve parameters for when the outputs were filled
     * @param destination Where to send the inputs. If the solver wants to send the inputs to themselves, they should
     * pass their address to this parameter.
     * @param call Optional callback data. If non-empty, will call orderFinalised on the destination
     */
    function finalise(
        StandardOrder calldata order,
        bytes calldata signatures,
        SolveParams[] calldata solveParams,
        bytes32 destination,
        bytes calldata call
    ) external override {
        _validateDestination(destination);
        _validateInputChain(order.originChainId);

        bytes32 orderId = _orderIdentifier(order);
        bytes32 orderOwner = _purchaseGetOrderOwner(orderId, solveParams);
        _orderOwnerIsCaller(orderOwner);

        _finalise(order, signatures, orderId, solveParams[0].solver, destination);
        if (call.length > 0) IInputCallback(destination.fromIdentifier()).orderFinalised(order.inputs, call);

        _validateFills(order.fillDeadline, order.inputOracle, order.outputs, orderId, solveParams);
    }

    /**
     * @notice Finalises a cross-chain order on behalf of someone else using their signature
     * @dev This function serves to finalise intents on the origin chain with proper authorization from the order owner.
     * @param order StandardOrder signed in conjunction with a Compact to form an order
     * @param signatures A signature for the sponsor and the allocator. abi.encode(bytes(sponsorSignature),
     * bytes(allocatorData))
     * @param solveParams List of solve parameters for when the outputs were filled
     * element
     * @param destination Where to send the inputs
     * @param call Optional callback data. If non-empty, will call orderFinalised on the destination
     * @param orderOwnerSignature Signature from the order owner authorizing this external call
     */
    function finaliseWithSignature(
        StandardOrder calldata order,
        bytes calldata signatures,
        SolveParams[] calldata solveParams,
        bytes32 destination,
        bytes calldata call,
        bytes calldata orderOwnerSignature
    ) external virtual override {
        _validateDestination(destination);
        _validateInputChain(order.originChainId);

        bytes32 orderId = _orderIdentifier(order);
        bytes32 orderOwner = _purchaseGetOrderOwner(orderId, solveParams);
        // Validate the external claimant with signature
        _allowExternalClaimant(orderId, orderOwner.fromIdentifier(), destination, call, orderOwnerSignature);

        _finalise(order, signatures, orderId, solveParams[0].solver, destination);
        if (call.length > 0) IInputCallback(destination.fromIdentifier()).orderFinalised(order.inputs, call);

        _validateFills(order.fillDeadline, order.inputOracle, order.outputs, orderId, solveParams);
    }

    //--- The Compact & Resource Locks ---//

    function _resolveLock(
        StandardOrder calldata order,
        bytes calldata sponsorSignature,
        bytes calldata allocatorData,
        bytes32 claimant
    ) internal override {
        {
            bytes32 orderId = _orderIdentifier(order);
            // Check the order status:
            OrderStatus status = orderStatus[orderId];
            // Mark order as deposited. If we can't make the deposit, we will
            // revert and it will unmark it. This acts as a reentry check.
            if (status != OrderStatus.None) revert AlreadyClaimed();

            orderStatus[orderId] = OrderStatus.Claimed;
        }

        BatchClaimComponent[] memory batchClaimComponents;
        {
            uint256 numInputs = order.inputs.length;
            batchClaimComponents = new BatchClaimComponent[](numInputs);
            uint256[2][] calldata maxInputs = order.inputs;
            address _owner = owner();
            uint64 fee = _owner != address(0) ? governanceFee : 0;
            for (uint256 i; i < numInputs; ++i) {
                uint256[2] calldata input = maxInputs[i];
                uint256 tokenId = input[0];
                uint256 allocatedAmount = input[1];

                Component[] memory components;

                // If the governance fee is set, we need to add a governance fee split.
                uint256 governanceShare = _calcFee(allocatedAmount, fee);
                if (governanceShare != 0) {
                    unchecked {
                        // To reduce the cost associated with the governance fee,
                        // we want to do a 6909 transfer instead of burn and mint.
                        // Note: While this function is called with replaced token, it
                        // replaces the rightmost 20 bytes. So it takes the locktag from TokenId
                        // and places it infront of the current vault owner.
                        uint256 ownerId = IdLib.withReplacedToken(tokenId, _owner);
                        components = new Component[](2);
                        // For the user
                        components[0] =
                            Component({ claimant: uint256(claimant), amount: allocatedAmount - governanceShare });
                        // For governance
                        components[1] = Component({ claimant: uint256(ownerId), amount: governanceShare });
                        batchClaimComponents[i] = BatchClaimComponent({
                            id: tokenId, // The token ID of the ERC6909 token to allocate.
                            allocatedAmount: allocatedAmount, // The original allocated amount of ERC6909 tokens.
                            portions: components
                        });
                        continue;
                    }
                }

                components = new Component[](1);
                components[0] = Component({ claimant: uint256(claimant), amount: allocatedAmount });
                batchClaimComponents[i] = BatchClaimComponent({
                    id: tokenId, // The token ID of the ERC6909 token to allocate.
                    allocatedAmount: allocatedAmount, // The original allocated amount of ERC6909 tokens.
                    portions: components
                });
            }
        }
        address user = order.user;
        // The Compact skips signature checks for msg.sender. Ensure no accidental intents are issued.
        if (user == address(this)) revert UserCannotBeSettler();
        require(
            COMPACT.batchClaim(
                BatchClaim({
                    allocatorData: allocatorData,
                    sponsorSignature: sponsorSignature,
                    sponsor: user,
                    nonce: order.nonce,
                    expires: order.expires,
                    witness: StandardOrderType.witnessHash(order),
                    witnessTypestring: string(StandardOrderType.BATCH_COMPACT_SUB_TYPES),
                    claims: batchClaimComponents
                })
            ) != bytes32(0)
        );
    }
}
