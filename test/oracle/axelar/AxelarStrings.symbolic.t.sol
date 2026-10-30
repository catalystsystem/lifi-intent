// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { AxelarStrings } from "../../../src/integrations/oracles/axelar/AxelarStrings.sol";
import { AddressStrings } from "./AddressStrings.sol";
import { Test } from "forge-std/Test.sol";

/// External entry points, so that library reverts surface as a failed `staticcall` instead of ending the symbolic
/// path.
contract AxelarStringsSymbolicHarness {
    /// `chainKey` of a string whose length field is `length` and whose first word is `word`. Bytes past `length` keep
    /// their (symbolic) contents as dirty padding.
    function keyOf(
        bytes32 word,
        uint256 length
    ) external pure returns (uint256) {
        bytes memory data = new bytes(32);
        assembly ("memory-safe") {
            mstore(add(data, 0x20), word)
            mstore(data, length)
        }
        return AxelarStrings.chainKey(string(data));
    }

    /// `chainName` as its raw length and first word, avoiding an ABI copy of a symbolic-length string.
    function nameOf(
        uint256 packed
    ) external pure returns (uint256 n, bytes32 w) {
        string memory s = AxelarStrings.chainName(packed);
        assembly ("memory-safe") {
            n := mload(s)
            w := mload(add(s, 0x20))
        }
    }

    /// The `AxelarOracle` chain-map setter check.
    function canonical(
        uint256 packed
    ) external pure returns (bool) {
        return AxelarStrings.chainKey(AxelarStrings.chainName(packed)) == packed;
    }

    function decode(
        string calldata value
    ) external pure returns (bytes32) {
        return AxelarStrings.decodeAddress(value);
    }
}

/// Symbolic properties (`forge test --symbolic`) comparing `AxelarStrings` with independent, branch-free
/// specifications. The specifications do not call the library or reuse its constants; `testSpecVectors` checks them
/// against concrete data in the normal suite. Address strings are explored up to 96 bytes; Base58 (Solana) is out of
/// scope and covered by the fuzz and differential tests.
contract AxelarStringsSymbolicTest is Test {
    AxelarStringsSymbolicHarness h;

    function setUp() public {
        h = new AxelarStringsSymbolicHarness();
    }

    // --- Calls ---

    /// `decodeAddress` on a string of length `len` (≤ 96) whose calldata words are `w1`, `w2`, `w3`. Every byte,
    /// including those past `len`, is the caller's.
    function _decode(
        uint256 len,
        bytes32 w1,
        bytes32 w2,
        bytes32 w3
    ) internal view returns (bool ok, bytes memory ret) {
        (ok, ret) = address(h)
            .staticcall(abi.encodePacked(AxelarStringsSymbolicHarness.decode.selector, uint256(0x20), len, w1, w2, w3));
    }

    /// `ret` is exactly the custom error `sel` without arguments. Compares words, never hashes.
    function _isError(
        bytes memory ret,
        bytes4 sel
    ) internal pure returns (bool r) {
        assembly ("memory-safe") {
            r := and(eq(mload(ret), 4), eq(shr(224, mload(add(ret, 0x20))), shr(224, sel)))
        }
    }

    function _hasPrefix(
        bytes32 w1
    ) internal pure returns (bool) {
        return uint256(w1) >> 240 == 0x3078;
    }

    function _assertDecodes(
        bool ok,
        bytes memory ret,
        bytes32 id
    ) internal pure {
        assertTrue(ok, "reverted");
        assertEq(ret.length, 32, "return size");
        assertEq(abi.decode(ret, (bytes32)), id, "id");
    }

    function _assertRejects(
        bool ok,
        bytes memory ret
    ) internal pure {
        assertFalse(ok, "accepted");
        assertTrue(_isError(ret, AxelarStrings.InvalidOracleAddress.selector), "wrong error");
    }

    // --- Specifications ---

    /// Chain key of the exact first `len` bytes of `word`: 1–32 bytes, no NUL.
    function _exactKey(
        bytes32 word,
        uint256 len
    ) internal pure returns (bool valid, uint256 key) {
        assembly ("memory-safe") {
            valid := 1
            for { let i := 0 } lt(i, 32) { i := add(i, 1) } {
                let b := byte(i, word)
                let inRange := lt(i, len)
                valid := and(valid, or(iszero(inRange), iszero(iszero(b))))
                key := or(key, shl(mul(8, sub(31, i)), mul(inRange, b)))
            }
            valid := and(valid, and(gt(len, 0), lt(len, 33)))
        }
    }

    /// Index of the first zero byte of `p`, or 32.
    function _firstZero(
        bytes32 p
    ) internal pure returns (uint256 n) {
        assembly ("memory-safe") {
            n := 32
            for { let i := 32 } i { } {
                i := sub(i, 1)
                n := xor(n, mul(iszero(byte(i, p)), xor(n, i)))
            }
        }
    }

    /// `p` is a nonempty name followed only by zero bytes.
    function _isCanonical(
        uint256 p
    ) internal pure returns (bool ok) {
        uint256 n = _firstZero(bytes32(p));
        assembly ("memory-safe") {
            ok := and(gt(n, 0), iszero(and(p, shr(shl(3, n), not(0)))))
        }
    }

    /// The 40 hex digits after `0x` (bytes 2–41 of `w1 ‖ w2`), either case.
    function _hexSpec(
        bytes32 w1,
        bytes32 w2
    ) internal pure returns (bool valid, bytes32 id) {
        assembly ("memory-safe") {
            function nibble(c) -> ok, v {
                let d := and(gt(c, 0x2f), lt(c, 0x3a))
                let u := and(gt(c, 0x40), lt(c, 0x47))
                let l := and(gt(c, 0x60), lt(c, 0x67))
                ok := or(d, or(u, l))
                v := add(add(mul(d, sub(c, 48)), mul(u, sub(c, 55))), mul(l, sub(c, 87)))
            }
            valid := 1
            for { let i := 2 } lt(i, 32) { i := add(i, 1) } {
                let ok, v := nibble(byte(i, w1))
                valid := and(valid, ok)
                id := or(shl(4, id), v)
            }
            for { let i := 0 } lt(i, 10) { i := add(i, 1) } {
                let ok, v := nibble(byte(i, w2))
                valid := and(valid, ok)
                id := or(shl(4, id), v)
            }
        }
    }

    /// RFC 4648 base32 character: 'A'–'Z' → 0–25, '2'–'7' → 26–31.
    function _b32(
        uint256 c
    ) internal pure returns (uint256 ok, uint256 v) {
        assembly ("memory-safe") {
            let letter := and(gt(c, 0x40), lt(c, 0x5b))
            let digit := and(gt(c, 0x31), lt(c, 0x38))
            ok := or(letter, digit)
            v := add(mul(letter, sub(c, 65)), mul(digit, sub(c, 24)))
        }
    }

    /// CRC16-XModem (poly 0x1021, init 0) of the byte 0x10 followed by `id`, in its GF(2)-linear form: the message
    /// bit k places from the end contributes x^(16+k) mod P. This equals the bitwise shift register, whose running
    /// CRC appears twice per bit and so grows the engine's expression exponentially.
    function _crcSpec(
        bytes32 id
    ) internal pure returns (uint256 crc) {
        assembly ("memory-safe") {
            // r · x mod P.
            function times_x(r) -> s {
                s := xor(and(shl(1, r), 0xffff), mul(shr(15, r), 0x1021))
            }
            let r := 0x1021 // x^16 mod P
            for { let k := 0 } lt(k, 256) { k := add(k, 1) } {
                crc := xor(crc, mul(and(shr(k, id), 1), r))
                r := times_x(r)
            }
            for { let k := 0 } lt(k, 8) { k := add(k, 1) } {
                crc := xor(crc, mul(and(shr(k, 0x10), 1), r))
                r := times_x(r)
            }
        }
    }

    /// Shape of a 56-character contract StrKey in bytes 0–55 of `w1 ‖ w2`: every character in the base32 alphabet
    /// and version 0x10. Returns the id the characters carry; the checksum is not checked.
    function _stellarShape(
        bytes32 w1,
        bytes32 w2
    ) internal pure returns (bool valid, bytes32 id) {
        uint256 all = 1;
        uint256 a;
        uint256 b;
        for (uint256 i; i < 32; ++i) {
            (uint256 ok, uint256 v) = _b32(uint8(w1[i]));
            assembly ("memory-safe") {
                all := and(all, ok)
                a := or(shl(5, a), v)
            }
        }
        for (uint256 i; i < 24; ++i) {
            (uint256 ok, uint256 v) = _b32(uint8(w2[i]));
            assembly ("memory-safe") {
                all := and(all, ok)
                b := or(shl(5, b), v)
            }
        }
        assembly ("memory-safe") {
            id := or(shl(104, and(a, sub(shl(152, 1), 1))), shr(16, b))
            valid := and(all, eq(shr(152, a), 0x10))
        }
    }

    /// Encodes `id` as a contract StrKey: characters 0–31 in `w1`, 32–55 in the top 24 bytes of `w2`.
    function _strKey(
        bytes32 id
    ) internal pure returns (bytes32 w1, bytes32 w2) {
        uint256 c = _crcSpec(id);
        assembly ("memory-safe") {
            function char(v) -> r {
                r := add(v, sub(65, mul(41, gt(v, 25))))
            }
            let a := or(shl(152, 0x10), shr(104, id))
            let b := or(or(shl(16, and(id, sub(shl(104, 1), 1))), shr(8, c)), shl(8, and(c, 0xff)))
            for { let i := 0 } lt(i, 32) { i := add(i, 1) } {
                w1 := or(w1, shl(sub(248, shl(3, i)), char(and(shr(sub(155, mul(5, i)), a), 31))))
            }
            for { let i := 0 } lt(i, 24) { i := add(i, 1) } {
                w2 := or(w2, shl(sub(248, shl(3, i)), char(and(shr(sub(115, mul(5, i)), b), 31))))
            }
        }
    }

    // --- Chain names ---

    /// `chainKey` exactly packs valid names (lengths 0, 1–32 and > 32, NUL anywhere, bytes
    /// ≥ 0x80, dirty padding) and rejects the rest with `InvalidChainName`.
    function check_chainKeyMatchesSpec(
        bytes32 word,
        uint256 length
    ) public view {
        (bool valid, uint256 key) = _exactKey(word, length);
        (bool ok, bytes memory ret) =
            address(h).staticcall(abi.encodeCall(AxelarStringsSymbolicHarness.keyOf, (word, length)));
        if (valid) {
            assertTrue(ok, "reverted");
            assertEq(ret.length, 32, "return size");
            assertEq(abi.decode(ret, (uint256)), key, "key");
        } else {
            assertFalse(ok, "accepted");
            assertTrue(_isError(ret, AxelarStrings.InvalidChainName.selector), "wrong error");
        }
    }

    /// `chainName` returns the bytes before the first zero byte, with the rest of its word zeroed.
    function check_chainNameMatchesSpec(
        uint256 packed
    ) public view {
        uint256 n = _firstZero(bytes32(packed));
        uint256 expected;
        assembly ("memory-safe") {
            expected := and(packed, not(shr(shl(3, n), not(0))))
        }
        (bool ok, bytes memory ret) =
            address(h).staticcall(abi.encodeCall(AxelarStringsSymbolicHarness.nameOf, (packed)));
        assertTrue(ok, "reverted");
        assertEq(ret.length, 64, "return size");
        (uint256 len, bytes32 w) = abi.decode(ret, (uint256, bytes32));
        assertEq(len, n, "length");
        assertEq(w, bytes32(expected), "word");
    }

    /// The chain-map setter check accepts exactly the canonical keys.
    function check_setterAcceptsExactlyCanonicalKeys(
        uint256 packed
    ) public view {
        (bool ok, bytes memory ret) =
            address(h).staticcall(abi.encodeCall(AxelarStringsSymbolicHarness.canonical, (packed)));
        bool accepted = ok && ret.length == 32 && abi.decode(ret, (bool));
        assertEq(accepted, _isCanonical(packed), "canonical");
    }

    // --- Addresses ---

    /// A 42-character `0x` string decodes to its 20 hex bytes, left-padded, exactly when every digit is hex.
    function check_evmMatchesSpec(
        bytes32 w1,
        bytes32 w2,
        bytes32 w3
    ) public view {
        vm.assume(_hasPrefix(w1));
        (bool valid, bytes32 id) = _hexSpec(w1, w2);
        (bool ok, bytes memory ret) = _decode(42, w1, w2, w3);
        if (valid) _assertDecodes(ok, ret, id);
        else _assertRejects(ok, ret);
    }

    /// A `0x` prefix with any other length is rejected, including Solana and Stellar lengths.
    function check_evmPrefixWrongLengthReverts(
        uint256 len,
        bytes32 w1,
        bytes32 w2,
        bytes32 w3
    ) public view {
        vm.assume(_hasPrefix(w1));
        vm.assume(len >= 2);
        vm.assume(len <= 96);
        vm.assume(len != 42);
        (bool ok, bytes memory ret) = _decode(len, w1, w2, w3);
        _assertRejects(ok, ret);
    }

    /// A 56-character string with a character outside the base32 alphabet or a version other than 0x10 is rejected.
    /// The assumption makes the checksum step unreachable, so the library's CRC is never explored.
    function check_stellarRejectsBadShape(
        bytes32 w1,
        bytes32 w2,
        bytes32 w3
    ) public view {
        (bool valid,) = _stellarShape(w1, w2);
        vm.assume(!valid);
        (bool ok, bytes memory ret) = _decode(56, w1, w2, w3);
        _assertRejects(ok, ret);
    }

    /// Fixed ids' StrKeys decode back to the ids whatever follows the string in calldata (`junk` fills the rest of
    /// the second word, `w3` the next). The ids are concrete because forge 1.8.4 does not terminate once any id bit
    /// is symbolic: its expressions for the library's 64-step nibble CRC grow exponentially with the symbolic steps.
    function check_stellarRoundTripFixedIds(
        bytes8 junk,
        bytes32 w3
    ) public view {
        bytes32[4] memory ids = [bytes32(0), bytes32(uint256(1)), bytes32(type(uint256).max), keccak256("axelar")];
        for (uint256 i; i < ids.length; ++i) {
            (bytes32 w1, bytes32 w2) = _strKey(ids[i]);
            w2 |= bytes32(uint256(uint64(junk)));
            (bool ok, bytes memory ret) = _decode(56, w1, w2, w3);
            _assertDecodes(ok, ret, ids[i]);
        }
    }

    /// Strings without a `0x` prefix whose length is neither 56 nor 32–44 are rejected.
    function check_unshapedLengthsRevert(
        uint256 len,
        bytes32 w1,
        bytes32 w2,
        bytes32 w3
    ) public view {
        vm.assume(len <= 96);
        vm.assume(len < 2 || !_hasPrefix(w1));
        vm.assume(len != 56);
        vm.assume(len < 32 || len > 44);
        (bool ok, bytes memory ret) = _decode(len, w1, w2, w3);
        _assertRejects(ok, ret);
    }

    // --- Specification self-test (runs in the normal suite) ---

    function testSpecVectors() public pure {
        (bool valid, uint256 key) = _exactKey(bytes32("Base"), 4);
        assertTrue(valid, "Base valid");
        assertEq(key, uint256(bytes32("Base")), "Base key");
        (valid,) = _exactKey(bytes32(0), 0);
        assertFalse(valid, "empty valid");
        assertEq(_firstZero(bytes32("base")), 4, "firstZero");

        bytes memory evm = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed";
        bytes32 e1;
        bytes32 e2;
        assembly ("memory-safe") {
            e1 := mload(add(evm, 0x20))
            e2 := mload(add(evm, 0x40))
        }
        bytes32 id;
        (valid, id) = _hexSpec(e1, e2);
        assertTrue(valid, "hex valid");
        assertEq(id, bytes32(uint256(uint160(0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed))), "hex id");

        bytes32[4] memory ids = [bytes32(0), bytes32(uint256(5)), bytes32(type(uint256).max), keccak256("axelar")];
        for (uint256 i; i < ids.length; ++i) {
            (bytes32 s1, bytes32 s2) = _strKey(ids[i]);
            bytes memory enc = bytes(AddressStrings.stellar(ids[i]));
            bytes32 r1;
            bytes32 r2;
            assembly ("memory-safe") {
                r1 := mload(add(enc, 0x20))
                r2 := mload(add(enc, 0x40))
            }
            assertEq(s1, r1, "strKey word 1");
            assertEq(s2, r2 & ~bytes32(uint256(type(uint64).max)), "strKey word 2");
            (valid, id) = _stellarShape(s1, s2);
            assertTrue(valid, "strKey valid");
            assertEq(id, ids[i], "strKey id");
        }
        // id 0's StrKey with a single defect each: version character 'A' (version 0), then '1' at character 32.
        (bytes32 z1, bytes32 z2) = _strKey(bytes32(0));
        (valid,) = _stellarShape(bytes32("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"), z2);
        assertFalse(valid, "version 0 valid");
        (valid,) = _stellarShape(z1, (z2 & ~bytes32(bytes1(0xff))) | bytes32(bytes1("1")));
        assertFalse(valid, "'1' valid");

        (bytes32 k1, bytes32 k2) = _strKey(bytes32(uint256(5)));
        assertEq(
            abi.encodePacked(k1, bytes24(k2)),
            bytes("CAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAK3IM"),
            "fixture"
        );
    }
}
