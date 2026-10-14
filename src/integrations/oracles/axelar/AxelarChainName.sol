// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { LibString } from "solady/utils/LibString.sol";

/// @title AxelarChainName
/// @notice Axelar chain name ↔ packed `uint256` chain-map key.
/// @dev The key is the ASCII-lowercased name packed left-aligned and zero-padded: `uint256(bytes32(bytes(name)))`.
/// Names are 1–32 bytes without NUL; no character set is imposed. Axelar compares names ASCII-case-insensitively,
/// so lowercasing gives each chain exactly one key.
library AxelarChainName {
    /// @notice The name is empty, longer than 32 bytes, or contains a NUL byte.
    error InvalidChainName();

    /// @notice ASCII-lowercases `chainName` and packs it left-aligned, word-at-a-time.
    /// @dev Only 0x41–0x5a change (by setting bit 0x20); bytes ≥ 0x80 are left as is.
    /// @param chainName Axelar chain name, in any ASCII case.
    /// @return packed Packed lowercase name.
    function key(
        string memory chainName
    ) internal pure returns (uint256 packed) {
        uint256 n = bytes(chainName).length;
        if (n == 0 || n > 32) revert InvalidChainName();
        bool nul;
        assembly ("memory-safe") {
            let ones := 0x0101010101010101010101010101010101010101010101010101010101010101
            let highs := shl(7, ones)
            // Mask of the bytes past the name. n = 32 shifts by 256, which yields 0 (no tail).
            let tail := shr(shl(3, n), not(0))
            let w := and(mload(add(chainName, 0x20)), not(tail))
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
    function name(
        uint256 packed
    ) internal pure returns (string memory) {
        return LibString.fromSmallString(bytes32(packed));
    }
}
