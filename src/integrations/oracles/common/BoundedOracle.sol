// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IAttester } from "../../../interfaces/IAttester.sol";
import { MessageEncodingLib } from "../../../libs/MessageEncodingLib.sol";
import { BaseInputOracle } from "../../../oracles/BaseInputOracle.sol";

/// Shared Stellar-compatible admission limits; transport authentication belongs to each adapter.
abstract contract BoundedOracle is BaseInputOracle {
    error InvalidConfiguration();
    error UnknownChain();
    error MessageLimit();
    error NotAttested();
    uint256 public constant MAX_PAYLOADS = 4;
    uint256 public constant MAX_PAYLOAD = 684;
    uint256 public constant MAX_MESSAGE = 2778;

    function _encode(
        address source,
        bytes[] calldata payloads
    ) internal pure returns (bytes memory) {
        if (source == address(0) || payloads.length == 0 || payloads.length > MAX_PAYLOADS) revert MessageLimit();
        for (uint256 i; i < payloads.length; ++i) {
            if (payloads[i].length > MAX_PAYLOAD) revert MessageLimit();
        }
        return MessageEncodingLib.encodeMessage(bytes32(uint256(uint160(source))), payloads);
    }

    function _export(
        address source,
        bytes[] calldata payloads
    ) internal view returns (bytes memory message) {
        message = _encode(source, payloads);
        if (!IAttester(source).hasAttested(payloads)) revert NotAttested();
    }

    function _record(
        uint256 chain,
        bytes32 sender,
        bytes calldata message
    ) internal {
        if (message.length < 34 || message.length > MAX_MESSAGE) revert MessageLimit();
        uint256 count = uint16(bytes2(message[32:34]));
        if (count == 0 || count > MAX_PAYLOADS) revert MessageLimit();
        uint256 cursor = 34;
        for (uint256 i; i < count; ++i) {
            uint256 size = uint16(bytes2(message[cursor:cursor + 2]));
            if (size > MAX_PAYLOAD) revert MessageLimit();
            cursor += 2 + size;
        }
        (bytes32 application, bytes32[] memory hashes) = MessageEncodingLib.getHashesOfEncodedPayloads(message);
        for (uint256 i; i < hashes.length; ++i) {
            if (!_attestations[chain][sender][application][hashes[i]]) {
                _attestations[chain][sender][application][hashes[i]] = true;
                emit OutputProven(chain, sender, application, hashes[i]);
            }
        }
    }
}
