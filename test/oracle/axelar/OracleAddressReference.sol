// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Base58 } from "@openzeppelin/contracts/utils/Base58.sol";

/// @title OracleAddressReference
/// @notice Test-only reference: the straightforward per-character decoder `AxelarStrings.decodeAddress` must agree
/// with.
/// @dev The format is inferred from the string's shape. EVM: `0x`-prefixed 20-byte hex, left-padded into the
/// identifier. Stellar: 56-character contract StrKey (`C...`, version byte 0x10) whose CRC16-XModem checksum is
/// stored little-endian. Solana: 32–44-character base58 public key, decoded with OpenZeppelin Base58. The shapes
/// cannot overlap: `0` is not in the base58 alphabet, and 56 is outside Solana's 32–44 length range.
library OracleAddressReference {
    /// @notice The string is not a valid address of the format its shape selects.
    error InvalidOracleAddress();

    /// @dev RFC 4648 base32 alphabet used by Stellar StrKeys.
    bytes internal constant BASE32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

    /// @notice Decodes an Axelar address string into an OIF identifier.
    /// @dev Rejects malformed input instead of normalising it. Dispatch: a `0x` prefix selects EVM, which must be
    /// 42 characters of hex in either case (the EIP-55 checksum is not checked); otherwise a length of 56 selects a
    /// Stellar contract StrKey with a valid checksum; otherwise the string must be a Solana key that decodes to
    /// exactly 32 bytes in its canonical spelling.
    /// @param value Axelar address string.
    /// @return id Raw 32-byte identifier. EVM addresses are left-padded with zeros.
    function decode(
        string calldata value
    ) internal pure returns (bytes32 id) {
        bytes calldata input = bytes(value);
        if (input.length >= 2 && input[0] == "0" && input[1] == "x") {
            if (input.length != 42) revert InvalidOracleAddress();
            uint256 n;
            for (uint256 i = 2; i < 42; ++i) {
                n = (n << 4) | _hex(uint8(input[i]));
            }
            return bytes32(n);
        }
        if (input.length == 56) {
            bytes memory raw = new bytes(35);
            uint256 acc;
            uint256 bits;
            uint256 j;
            for (uint256 i; i < 56; ++i) {
                uint8 c = uint8(input[i]);
                uint256 v;
                if (c >= 65 && c <= 90) v = c - 65;
                else if (c >= 50 && c <= 55) v = c - 24;
                else revert InvalidOracleAddress();
                acc = (acc << 5) | v;
                bits += 5;
                if (bits >= 8) {
                    bits -= 8;
                    raw[j++] = bytes1(uint8(acc >> bits));
                }
            }
            if (raw[0] != 0x10 || _crc(raw) != (uint16(uint8(raw[33])) | uint16(uint8(raw[34])) << 8)) {
                revert InvalidOracleAddress();
            }
            assembly ("memory-safe") { id := mload(add(raw, 33)) }
            return id;
        }
        if (input.length < 32 || input.length > 44) revert InvalidOracleAddress();
        // Invalid characters revert with OpenZeppelin's `InvalidBase58Char`.
        bytes memory decoded = Base58.decode(value);
        if (decoded.length != 32) revert InvalidOracleAddress();
        id = bytes32(decoded);
        // Base58 is a bijection, so this never fails today; it pins one spelling per ID
        // independently of the library's decoder.
        if (keccak256(bytes(Base58.encode(decoded))) != keccak256(input)) revert InvalidOracleAddress();
    }

    /// @dev Value of one ASCII hex digit, accepting either case.
    /// @param c ASCII character.
    /// @return Digit value in [0, 15].
    function _hex(
        uint8 c
    ) private pure returns (uint256) {
        if (c >= 48 && c <= 57) return c - 48;
        if (c >= 65 && c <= 70) return c - 55;
        if (c >= 97 && c <= 102) return c - 87;
        revert InvalidOracleAddress();
    }

    /// @dev CRC16-XModem (polynomial 0x1021, initial value 0) over the first 33 bytes, which are the
    /// StrKey version byte and payload.
    /// @param data StrKey bytes, at least 33 long.
    /// @return crc Checksum.
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
