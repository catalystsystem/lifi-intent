// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin/token/ERC20/utils/SafeERC20.sol";

import { IAttester } from "../../../interfaces/IAttester.sol";
import { LibAddress } from "../../../libs/LibAddress.sol";
import { MessageEncodingLib } from "../../../libs/MessageEncodingLib.sol";
import { BaseInputOracle } from "../../../oracles/BaseInputOracle.sol";
import { ChainMap } from "../../../oracles/ChainMap.sol";

import { CCIPReceiver } from "./external/CCIPReceiver.sol";
import { Client } from "./external/Client.sol";
import { IRouterClient } from "./external/interfaces/IRouterClient.sol";

/**
 * @notice Chainlink CCIP Oracle.
 * Sends attested payloads through Chainlink CCIP and stores attestations of payloads received from the CCIP router.
 * @dev CCIP identifies chains by 64-bit chain selectors rather than chain ids. The owner translates selectors into
 * chain ids through `ChainMap`; each map is set once and cannot be changed afterwards. Messages from unmapped selectors
 * revert and can be executed manually through CCIP once the selector is mapped.
 * Messages are sent without token transfers. The remote oracle identifier is the 32-byte CCIP sender, which for EVM
 * chains is the left-padded address.
 */
contract ChainlinkCCIPOracle is ChainMap, BaseInputOracle, CCIPReceiver {
    using LibAddress for address;

    error InsufficientFee(uint256 provided, uint256 required);
    error InvalidSender(bytes sender);
    error NotAllPayloadsValid();
    error RefundFailed();

    constructor(
        address _owner,
        address router
    ) ChainMap(_owner) CCIPReceiver(router) { }

    // --- Sending Proofs --- //

    /**
     * @notice Returns the CCIP fee for submitting payloads.
     * @param destinationChainSelector CCIP chain selector of the destination chain.
     * @param recipientOracle Identifier of the oracle on the destination chain.
     * @param extraArgs CCIP extra args, e.g. destination gas limit. Empty bytes use the CCIP defaults.
     * @param feeToken Token to pay the fee in. address(0) pays in native currency.
     * @param source Application that has payloads that are marked as valid.
     * @param payloads List of payloads to broadcast.
     * @return fee Fee denominated in feeToken.
     */
    function getFee(
        uint64 destinationChainSelector,
        bytes32 recipientOracle,
        bytes calldata extraArgs,
        address feeToken,
        address source,
        bytes[] calldata payloads
    ) external view returns (uint256 fee) {
        return IRouterClient(getRouter())
            .getFee(destinationChainSelector, _buildMessage(recipientOracle, extraArgs, feeToken, source, payloads));
    }

    /**
     * @notice Takes proofs that have been marked as valid by a source and submits them to CCIP for broadcast.
     * @dev Native fees are paid from msg.value and the excess is refunded to msg.sender. Token fees are collected from
     * msg.sender, which must have approved this contract for the fee; any msg.value is refunded.
     * @param destinationChainSelector CCIP chain selector of the destination chain.
     * @param recipientOracle Identifier of the oracle on the destination chain.
     * @param extraArgs CCIP extra args, e.g. destination gas limit. Empty bytes use the CCIP defaults.
     * @param feeToken Token to pay the fee in. address(0) pays in native currency.
     * @param source Application that has payloads that are marked as valid.
     * @param payloads List of payloads to broadcast.
     * @return refund Excess native value returned to msg.sender.
     */
    function submit(
        uint64 destinationChainSelector,
        bytes32 recipientOracle,
        bytes calldata extraArgs,
        address feeToken,
        address source,
        bytes[] calldata payloads
    ) external payable returns (uint256 refund) {
        if (!IAttester(source).hasAttested(payloads)) revert NotAllPayloadsValid();

        Client.EVM2AnyMessage memory message = _buildMessage(recipientOracle, extraArgs, feeToken, source, payloads);
        address router = getRouter();
        uint256 fee = IRouterClient(router).getFee(destinationChainSelector, message);

        uint256 nativeFee;
        if (feeToken == address(0)) {
            nativeFee = fee;
            if (msg.value < nativeFee) revert InsufficientFee(msg.value, nativeFee);
        } else {
            SafeERC20.safeTransferFrom(IERC20(feeToken), msg.sender, address(this), fee);
            SafeERC20.forceApprove(IERC20(feeToken), router, fee);
        }

        IRouterClient(router).ccipSend{ value: nativeFee }(destinationChainSelector, message);

        // Refund excess value if any.
        refund = msg.value - nativeFee;
        if (refund != 0) {
            (bool success,) = msg.sender.call{ value: refund }("");
            if (!success) revert RefundFailed();
        }
    }

    function _buildMessage(
        bytes32 recipientOracle,
        bytes calldata extraArgs,
        address feeToken,
        address source,
        bytes[] calldata payloads
    ) internal pure returns (Client.EVM2AnyMessage memory) {
        return Client.EVM2AnyMessage({
            receiver: abi.encode(recipientOracle),
            data: MessageEncodingLib.encodeMessage(source.toIdentifier(), payloads),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: feeToken,
            extraArgs: extraArgs
        });
    }

    // --- Receiving Proofs --- //

    /**
     * @notice Stores attestations of payloads delivered by the CCIP router.
     * @param message CCIP message. The sender must be a 32-byte identifier.
     */
    function _ccipReceive(
        Client.Any2EVMMessage calldata message
    ) internal override {
        if (message.sender.length != 32) revert InvalidSender(message.sender);
        bytes32 remoteSenderIdentifier = bytes32(message.sender);
        uint256 remoteChainId = _getMappedChainId(uint256(message.sourceChainSelector));

        (bytes32 application, bytes32[] memory payloadHashes) =
            MessageEncodingLib.getHashesOfEncodedPayloads(message.data);

        uint256 numPayloads = payloadHashes.length;
        for (uint256 i; i < numPayloads; ++i) {
            bytes32 payloadHash = payloadHashes[i];
            _attestations[remoteChainId][remoteSenderIdentifier][application][payloadHash] = true;

            emit OutputProven(remoteChainId, remoteSenderIdentifier, application, payloadHash);
        }
    }
}
