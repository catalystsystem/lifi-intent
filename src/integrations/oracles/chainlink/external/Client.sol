// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @notice Chainlink CCIP message structs.
 * @dev Copied from Chainlink CCIP contracts-ccip-v2.0.0 (commit c2c125c27f056db2e98d21501922b6eff5750f36) on
 * 2026-10-09:
 * https://github.com/smartcontractkit/chainlink-ccip/blob/c2c125c27f056db2e98d21501922b6eff5750f36/chains/evm/contracts/libraries/Client.sol
 * Modifications: kept only the message structs; removed extraArgs tags, structs and encoders.
 */
library Client {
    struct EVMTokenAmount {
        address token; // token address on the local chain.
        uint256 amount; // Amount of tokens.
    }

    struct Any2EVMMessage {
        bytes32 messageId; // MessageId corresponding to ccipSend on source.
        uint64 sourceChainSelector; // Source chain selector.
        bytes sender; // abi.encode(address) on EVM source chains; abi.decode(sender, (address)) to recover.
        bytes data; // payload sent in original message.
        EVMTokenAmount[] destTokenAmounts; // Tokens and their amounts in their destination chain representation.
    }

    // If extraArgs is empty bytes, the default is 200k gas limit.
    struct EVM2AnyMessage {
        bytes receiver; // abi.encode(receiver address) for dest EVM chains.
        bytes data; // Data payload.
        EVMTokenAmount[] tokenAmounts; // Token transfers.
        address feeToken; // Address of feeToken. address(0) means you will send msg.value.
        bytes extraArgs; // Populate this with _argsToBytes(EVMExtraArgsV3).
    }
}
