// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// Axelar native strings <-> OIF raw identifiers. Stellar CRC16-XModem is stored little-endian.
library OracleAddress {
    enum Kind {
        Evm,
        Stellar,
        Solana
    }
    error InvalidOracleAddress();
    bytes internal constant BASE32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    bytes internal constant HEX = "0123456789abcdef";
    bytes internal constant BASE58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

    function encode(
        bytes32 id,
        Kind kind
    ) internal pure returns (string memory) {
        if (kind == Kind.Solana) {
            uint256 n = uint256(id);
            bytes memory digits = new bytes(44);
            uint256 length;
            while (n != 0) {
                digits[length++] = BASE58[n % 58];
                n /= 58;
            }
            uint256 zeros;
            while (zeros < 32 && id[zeros] == 0) ++zeros;
            bytes memory out58 = new bytes(zeros + length);
            for (uint256 i; i < zeros; ++i) out58[i] = "1";
            for (uint256 i; i < length; ++i) out58[zeros + i] = digits[length - 1 - i];
            return string(out58);
        }
        if (kind == Kind.Evm) {
            if (uint256(id) >> 160 != 0) revert InvalidOracleAddress();
            bytes memory evm = new bytes(42);
            evm[0] = "0";
            evm[1] = "x";
            for (uint256 i; i < 20; ++i) {
                uint8 b = uint8(id[i + 12]);
                evm[2 + i * 2] = HEX[b >> 4];
                evm[3 + i * 2] = HEX[b & 15];
            }
            return string(evm);
        }
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

    function decode(
        string calldata value,
        Kind kind
    ) internal pure returns (bytes32 id) {
        bytes calldata input = bytes(value);
        if (kind == Kind.Solana) {
            if (input.length < 32 || input.length > 44) revert InvalidOracleAddress();
            uint256 n;
            for (uint256 i; i < input.length; ++i) {
                uint256 digit;
                while (digit < 58 && BASE58[digit] != input[i]) ++digit;
                if (digit == 58 || n > (type(uint256).max - digit) / 58) revert InvalidOracleAddress();
                n = n * 58 + digit;
            }
            id = bytes32(n);
            if (keccak256(bytes(encode(id, kind))) != keccak256(input)) revert InvalidOracleAddress();
            return id;
        }
        if (kind == Kind.Evm) {
            if (input.length != 42 || input[0] != "0" || input[1] != "x") revert InvalidOracleAddress();
            uint256 n;
            for (uint256 i = 2; i < 42; ++i) {
                n = (n << 4) | _hex(uint8(input[i]));
            }
            return bytes32(n);
        }
        if (input.length != 56) revert InvalidOracleAddress();
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
    }

    function _hex(
        uint8 c
    ) private pure returns (uint256) {
        if (c >= 48 && c <= 57) return c - 48;
        if (c >= 65 && c <= 70) return c - 55;
        if (c >= 97 && c <= 102) return c - 87;
        revert InvalidOracleAddress();
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
