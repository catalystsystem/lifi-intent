// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

/**
 * @title Base58
 * @notice Minimal on-chain Base58 encoder using the Bitcoin/Solana alphabet.
 * @dev Implements the canonical "big-number" base58 encoding (as used by Bitcoin/Solana): the input is treated as a
 *      big-endian integer, repeatedly divided by 58, and each leading `0x00` byte maps to one leading `'1'` character.
 *      This is the exact rendering Solana uses for program ids (e.g. bytes32
 *      `0x06ddf6e1...eff00a9` -> "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA").
 *
 *      Test-only: used to cross-check the program id Polymer returns for a Solana proof. `PolymerOracle` does not
 *      use it (Polymer strips the `"program: <base58>, "` template off-chain and returns the program id as bytes32).
 */
library Base58 {
    /// @dev Bitcoin/Solana base58 alphabet (no 0, O, I, l).
    bytes internal constant ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

    /**
     * @notice Base58-encodes an arbitrary byte string.
     * @param data The raw bytes to encode.
     * @return The base58 string.
     */
    function encode(
        bytes memory data
    ) internal pure returns (string memory) {
        uint256 dataLen = data.length;
        if (dataLen == 0) return "";

        // Count leading zero bytes; each maps to a leading '1'.
        uint256 zeros = 0;
        while (zeros < dataLen && data[zeros] == 0x00) {
            ++zeros;
        }

        // Upper bound on the number of base58 digits: log(256)/log(58) ~= 1.365, so 138/100 + 1 is safe.
        uint256 size = ((dataLen - zeros) * 138) / 100 + 1;
        bytes memory b58 = new bytes(size);

        // Process each remaining byte as "b58 = b58 * 256 + byte", accumulating base58 digits from the LSB end.
        uint256 length = 0;
        for (uint256 i = zeros; i < dataLen; ++i) {
            uint256 carry = uint256(uint8(data[i]));
            uint256 k = 0;
            for (uint256 rev = 0; rev < size; ++rev) {
                if (carry == 0 && k >= length) break;
                uint256 idx = size - 1 - rev;
                carry += 256 * uint256(uint8(b58[idx]));
                b58[idx] = bytes1(uint8(carry % 58));
                carry /= 58;
                ++k;
            }
            length = k;
        }

        // The significant digits occupy b58[size - length : size].
        uint256 start = size - length;

        bytes memory out = new bytes(zeros + length);
        for (uint256 i = 0; i < zeros; ++i) {
            out[i] = ALPHABET[0]; // '1'
        }
        for (uint256 i = 0; i < length; ++i) {
            out[zeros + i] = ALPHABET[uint8(b58[start + i])];
        }
        return string(out);
    }

    /**
     * @notice Base58-encodes a 32-byte value (e.g. a Solana program id), preserving leading zero bytes.
     * @param data The 32-byte value to encode.
     * @return The base58 string.
     */
    function encode(
        bytes32 data
    ) internal pure returns (string memory) {
        bytes memory buf = new bytes(32);
        assembly {
            mstore(add(buf, 32), data)
        }
        return encode(buf);
    }
}
