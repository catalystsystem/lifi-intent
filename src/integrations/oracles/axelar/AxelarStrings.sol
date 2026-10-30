// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Base58 } from "@openzeppelin/contracts/utils/Base58.sol";
import { LibString } from "solady/utils/LibString.sol";

/// @title AxelarStrings
/// @notice Conversions between Axelar's string identifiers and the OIF's packed integers: chain names ↔ chain-map
/// keys, and address strings → 32-byte identifiers.
/// @dev Chain names: the key is the ASCII-lowercased name packed left-aligned and zero-padded,
/// `uint256(bytes32(bytes(name)))`. Names are 1–32 bytes without NUL; no character set is imposed.
/// ASCII case variants share an internal lookup key; strings sent to Axelar must keep their original spelling.
///
/// Addresses: the format is inferred from the string's shape. EVM: `0x`-prefixed 20-byte hex, left-padded into the
/// identifier. Stellar: 56-character contract StrKey (`C...`, version byte 0x10) whose CRC16-XModem checksum is
/// stored little-endian. Solana: 32–44-character base58 public key, decoded with OpenZeppelin Base58. The shapes
/// cannot overlap: `0` is not in the base58 alphabet, and 56 is outside Solana's 32–44 length range.
///
/// Chain names and the EVM and Stellar address branches are processed a whole word at a time (SWAR) instead of
/// per character; the StrKey checksum is a 4-bit table-driven CRC16-XModem whose 16-entry table fits in one word.
/// Base58 carries across the whole string, so the Solana branch has no word-parallel form.
library AxelarStrings {
    /// @notice The name is empty, longer than 32 bytes, or contains a NUL byte.
    error InvalidChainName();
    /// @notice The string is not a valid address of the format its shape selects.
    error InvalidOracleAddress();

    uint256 private constant ONES = type(uint256).max / 0xff; // 0x01 in every byte lane
    uint256 private constant HIGH = ONES << 7; // 0x80 in every byte lane
    uint256 private constant HIGH8 = HIGH >> 192; // 0x80 in the low 8 byte lanes
    uint256 private constant HIGH24 = HIGH >> 64; // 0x80 in the low 24 byte lanes
    uint256 private constant ONES16 = type(uint256).max / 0xffff;
    uint256 private constant ONES32 = type(uint256).max / 0xffffffff;
    uint256 private constant ONES64 = type(uint256).max / 0xffffffffffffffff;
    uint256 private constant ONES128 = type(uint256).max / type(uint128).max;
    uint256 private constant M40 = 0xffffffffff;

    /// @dev CRC16-XModem nibble table: entry i (bits 16i..16i+15) is the CRC of `i << 12` after four shifts.
    uint256 private constant CRC_TABLE = 0xf1efe1ced1adc18cb16ba14a9129810870e760c650a540843063204210210000;
    /// @dev CRC16-XModem of the contract StrKey version byte 0x10.
    uint256 private constant CRC_VERSION = 0x1231;

    /// @notice ASCII-lowercases `name` and packs it left-aligned, word-at-a-time.
    /// @dev Only 0x41–0x5a change (by setting bit 0x20); bytes ≥ 0x80 are left as is.
    /// @param name Axelar chain name, in any ASCII case.
    /// @return packed Packed lowercase name.
    function chainKey(
        string memory name
    ) internal pure returns (uint256 packed) {
        uint256 n = bytes(name).length;
        if (n == 0 || n > 32) revert InvalidChainName();
        bool nul;
        assembly ("memory-safe") {
            let ones := 0x0101010101010101010101010101010101010101010101010101010101010101
            let highs := shl(7, ones)
            // Mask of the bytes past the name. n = 32 shifts by 256, which yields 0 (no tail).
            let tail := shr(shl(3, n), not(0))
            let w := and(mload(add(name, 0x20)), not(tail))
            // NUL test on a copy `v` whose tail bytes are 0x01, so the zero padding does not count; `w` and the key
            // keep a zero tail. The has-zero-byte test is exact for a yes/no answer.
            let v := or(w, and(tail, ones))
            nul := iszero(iszero(and(and(sub(v, ones), not(v)), highs)))
            // With high bits cleared each byte is ≤ 0x7f, so adding ≤ 0x3f per byte never carries across bytes.
            // Bit 7 of (b + 0x3f) is set iff b ≥ 0x41; of (b + 0x25) iff b ≥ 0x5b.
            let low := and(w, not(highs))
            let ge41 := and(add(low, mul(0x3f, ones)), highs)
            let ge5b := and(add(low, mul(0x25, ones)), highs)
            // Uppercase ASCII: ≥ 0x41, < 0x5b, and the original high bit clear; move bit 7 to bit 5.
            packed := or(w, shr(2, and(and(ge41, not(ge5b)), not(w))))
        }
        if (nul) revert InvalidChainName();
    }

    /// @notice Unpacks a key into its name: the bytes up to the first zero byte.
    /// @param packed Packed name.
    /// @return Chain name.
    function chainName(
        uint256 packed
    ) internal pure returns (string memory) {
        return LibString.fromSmallString(bytes32(packed));
    }

    /// @notice Decodes an Axelar address string into an OIF identifier.
    /// @dev Rejects malformed input instead of normalising it. Dispatch: a `0x` prefix selects EVM, which must be
    /// 42 characters of hex in either case (the EIP-55 checksum is not checked); otherwise a length of 56 selects a
    /// Stellar contract StrKey with a valid checksum; otherwise the string must be a Solana key that decodes to
    /// exactly 32 bytes in its canonical spelling.
    /// @param value Axelar address string.
    /// @return id Raw 32-byte identifier. EVM addresses are left-padded with zeros.
    function decodeAddress(
        string calldata value
    ) internal pure returns (bytes32 id) {
        bytes calldata input = bytes(value);
        uint256 len = input.length;
        // Words past the end of calldata read as zero; only the lanes a branch's length check covers are used.
        uint256 w1;
        uint256 w2;
        assembly ("memory-safe") {
            w1 := calldataload(input.offset)
            w2 := calldataload(add(input.offset, 32))
        }
        if (len >= 2 && w1 >> 240 == 0x3078) {
            if (len != 42) revert InvalidOracleAddress();
            // Characters 2–33 and 34–41.
            uint256 hi = _hex((w1 << 16) | (w2 >> 240), HIGH);
            uint256 lo = _hex((w2 >> 176) & type(uint64).max, HIGH8);
            return bytes32((hi << 32) | lo);
        }
        if (len == 56) {
            // Characters 0–31 and 32–55; 8 characters (40 bits) per 64-bit lane in both.
            uint256 v1 = _base32(w1, HIGH);
            uint256 v2 = _base32(w2 >> 64, HIGH24);
            // 280 bits: version (8) ‖ id (256) ‖ checksum (16).
            uint256 g1 = ((v1 >> 192) << 120) | (((v1 >> 128) & M40) << 80) | (((v1 >> 64) & M40) << 40) | (v1 & M40);
            uint256 g2 = (((v2 >> 128) & M40) << 80) | (((v2 >> 64) & M40) << 40) | (v2 & M40);
            if (g1 >> 152 != 0x10) revert InvalidOracleAddress();
            id = bytes32((g1 << 104) | (g2 >> 16));
            // The checksum is stored little-endian.
            if (_crc(id) != (((g2 >> 8) & 0xff) | ((g2 & 0xff) << 8))) revert InvalidOracleAddress();
            return id;
        }
        if (len < 32 || len > 44) revert InvalidOracleAddress();
        // Invalid characters revert with OpenZeppelin's `InvalidBase58Char`.
        bytes memory decoded = Base58.decode(value);
        if (decoded.length != 32) revert InvalidOracleAddress();
        // The length is exactly 32, so the cast keeps every byte.
        // forge-lint: disable-next-line(unsafe-typecast)
        id = bytes32(decoded);
        // Base58 is a bijection, so this never fails today; it pins one spelling per ID
        // independently of the library's decoder.
        if (keccak256(bytes(Base58.encode(decoded))) != keccak256(input)) revert InvalidOracleAddress();
    }

    /// @dev Lanes (under `high`) whose byte is at least `lo`. Requires every byte < 0x80, so no lane carries.
    function _ge(
        uint256 x,
        uint256 lo,
        uint256 high
    ) private pure returns (uint256) {
        unchecked {
            return (x + (high >> 7) * (0x80 - lo)) & high;
        }
    }

    /// @dev Decodes the hex characters in the byte lanes selected by `high` (one bit per used lane) into their
    /// nibbles, packed in order into the low half of the lanes' bit width.
    function _hex(
        uint256 x,
        uint256 high
    ) private pure returns (uint256) {
        if (x & HIGH != 0) revert InvalidOracleAddress();
        uint256 digit = _ge(x, 0x30, high) & ~_ge(x, 0x3a, high);
        uint256 upper = _ge(x, 0x41, high) & ~_ge(x, 0x47, high);
        uint256 lower = _ge(x, 0x61, high) & ~_ge(x, 0x67, high);
        if (digit | upper | lower != high) revert InvalidOracleAddress();
        unchecked {
            uint256 ones = high >> 7;
            // Letters have bit 0x40 set: 'A'/'a' & 0x0f = 1, + 9 = 10.
            x = (x & (ones * 0x0f)) + ((x >> 6) & ones) * 9;
        }
        // Each step joins neighbouring values, which are half their lane wide, into one full-width value.
        x = (x | (x >> 4)) & (ONES16 * 0xff);
        x = (x | (x >> 8)) & (ONES32 * 0xffff);
        x = (x | (x >> 16)) & (ONES64 * 0xffffffff);
        x = (x | (x >> 32)) & (ONES128 * type(uint64).max);
        return (x | (x >> 64)) & type(uint128).max;
    }

    /// @dev Decodes the RFC 4648 base32 characters in the byte lanes selected by `high` into 5-bit values, then
    /// packs each 64-bit lane's 8 values in order into its low 40 bits.
    function _base32(
        uint256 x,
        uint256 high
    ) private pure returns (uint256) {
        if (x & HIGH != 0) revert InvalidOracleAddress();
        uint256 letter = _ge(x, 0x41, high) & ~_ge(x, 0x5b, high);
        uint256 digit = _ge(x, 0x32, high) & ~_ge(x, 0x38, high);
        if (letter | digit != high) revert InvalidOracleAddress();
        unchecked {
            // 'A'–'Z' → 0–25 and '2'–'7' → 26–31; no lane borrows since every used lane is ≥ 65 after the
            // add.
            x = x + (digit >> 7) * 41 - (high >> 7) * 65;
        }
        x = ((x >> 3) & (ONES16 * 0x03e0)) | (x & (ONES16 * 0x001f));
        x = ((x >> 6) & (ONES32 * 0x000ffc00)) | (x & (ONES32 * 0x3ff));
        return ((x >> 12) & (ONES64 * 0xfffff00000)) | (x & (ONES64 * 0xfffff));
    }

    /// @dev CRC16-XModem over the version byte 0x10 followed by `id`, one nibble per step.
    function _crc(
        bytes32 id
    ) private pure returns (uint256 crc) {
        assembly ("memory-safe") {
            crc := CRC_VERSION
            for { let s := 256 } s { } {
                s := sub(s, 4)
                let i := xor(shr(12, crc), and(shr(s, id), 0xf))
                crc := xor(and(shl(4, crc), 0xffff), and(shr(shl(4, i), CRC_TABLE), 0xffff))
            }
        }
    }
}
