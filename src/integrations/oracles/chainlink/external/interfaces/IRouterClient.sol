// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import { Client } from "../Client.sol";

/**
 * @notice Chainlink CCIP router interface for sending messages.
 * @dev Copied from Chainlink CCIP contracts-ccip-v2.0.0 (commit c2c125c27f056db2e98d21501922b6eff5750f36) on
 * 2026-10-09:
 * https://github.com/smartcontractkit/chainlink-ccip/blob/c2c125c27f056db2e98d21501922b6eff5750f36/chains/evm/contracts/interfaces/IRouterClient.sol
 * Modifications: removed the unused isChainSupported function.
 */
interface IRouterClient {
    error UnsupportedDestinationChain(uint64 destChainSelector);
    error InsufficientFeeTokenAmount();
    error InvalidMsgValue();

    /// @param destinationChainSelector The destination chainSelector.
    /// @param message The cross-chain CCIP message including data and/or tokens.
    /// @return fee returns execution fee for the message.
    /// delivery to destination chain, denominated in the feeToken specified in the message.
    /// @dev Reverts with appropriate reason upon invalid message.
    function getFee(
        uint64 destinationChainSelector,
        Client.EVM2AnyMessage memory message
    ) external view returns (uint256 fee);

    /// @notice Request a message to be sent to the destination chain.
    /// @param destinationChainSelector The destination chain ID.
    /// @param message The cross-chain CCIP message including data and/or tokens.
    /// @return messageId The message ID.
    /// @dev Note if msg.value is larger than the required fee (from getFee) we accept.
    /// the overpayment with no refund.
    /// @dev Reverts with appropriate reason upon invalid message.
    function ccipSend(
        uint64 destinationChainSelector,
        Client.EVM2AnyMessage calldata message
    ) external payable returns (bytes32);
}
