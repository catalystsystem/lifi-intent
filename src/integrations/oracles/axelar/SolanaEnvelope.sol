// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// Axelar 1.1.1 ExecutablePayload::Borsh: scheme, byte vector, account vector.
/// The destination configuration is the sole extra account, read-only and not a signer.
library SolanaEnvelope {
    uint256 internal constant MAX_PAYLOAD = 320;
    error InvalidSolanaEnvelope();

    function encode(bytes memory message, bytes32 configuration) internal pure returns (bytes memory) {
        if (configuration == 0 || message.length < 36 || message.length > 36 + MAX_PAYLOAD
            || uint8(message[32]) != 0 || uint8(message[33]) != 1) revert InvalidSolanaEnvelope();
        uint256 n = message.length;
        return abi.encodePacked(
            bytes1(0), bytes1(uint8(n)), bytes1(uint8(n >> 8)), bytes2(0), message,
            hex"01000000", configuration, bytes1(0)
        );
    }
}
