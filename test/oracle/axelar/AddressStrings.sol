// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Base58 } from "@openzeppelin/contracts/utils/Base58.sol";

/// Test-only encoders from OIF identifiers to Axelar address strings.
library AddressStrings {
    bytes internal constant HEX = "0123456789abcdef";
    bytes internal constant BASE32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

    /// Lowercase `0x` + 40 hex digits; the upper 12 bytes of `id` must be zero.
    function evm(
        bytes32 id
    ) internal pure returns (string memory) {
        require(uint256(id) >> 160 == 0, "not an EVM address");
        bytes memory out = new bytes(42);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i; i < 20; ++i) {
            uint8 b = uint8(id[i + 12]);
            out[2 + i * 2] = HEX[b >> 4];
            out[3 + i * 2] = HEX[b & 15];
        }
        return string(out);
    }

    /// Stellar contract StrKey: version byte 0x10, id, little-endian CRC16-XModem, base32.
    function stellar(
        bytes32 id
    ) internal pure returns (string memory) {
        bytes memory raw = abi.encodePacked(bytes1(0x10), id, bytes2(0));
        uint16 crc = _crc(raw);
        raw[33] = bytes1(uint8(crc));
        raw[34] = bytes1(uint8(crc >> 8));
        bytes memory out = new bytes(56);
        uint256 acc;
        uint256 bits;
        uint256 j;
        for (uint256 i; i < 35; ++i) {
            acc = (acc << 8) | uint8(raw[i]);
            bits += 8;
            while (bits >= 5) {
                bits -= 5;
                out[j++] = BASE32[(acc >> bits) & 31];
            }
        }
        return string(out);
    }

    /// Solana base58 public key.
    function solana(
        bytes32 id
    ) internal pure returns (string memory) {
        return Base58.encode(abi.encodePacked(id));
    }

    function _crc(
        bytes memory data
    ) private pure returns (uint16 crc) {
        for (uint256 i; i < 33; ++i) {
            crc ^= uint16(uint8(data[i])) << 8;
            for (uint256 k; k < 8; ++k) {
                crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1;
            }
        }
    }
}
