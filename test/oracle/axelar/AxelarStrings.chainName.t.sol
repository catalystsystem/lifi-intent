// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { AxelarStrings } from "../../../src/integrations/oracles/axelar/AxelarStrings.sol";
import { Test } from "forge-std/Test.sol";

contract ChainNameHarness {
    function key(
        string memory chainName
    ) external pure returns (uint256) {
        return AxelarStrings.chainKey(chainName);
    }

    function name(
        uint256 packed
    ) external pure returns (string memory) {
        return AxelarStrings.chainName(packed);
    }
}

/// `AxelarStrings.chainKey` (word-at-a-time) against a byte-by-byte reference: ASCII A–Z lowercased, every other
/// nonzero byte kept, 1–32 bytes, NUL rejected.
contract AxelarStringsChainNameTest is Test {
    ChainNameHarness h;

    function setUp() public {
        h = new ChainNameHarness();
    }

    function reference_(
        bytes memory b
    ) internal pure returns (bool ok, uint256 key) {
        if (b.length == 0 || b.length > 32) return (false, 0);
        for (uint256 i; i < b.length; ++i) {
            uint8 c = uint8(b[i]);
            if (c == 0) return (false, 0);
            if (c >= 0x41 && c <= 0x5a) c += 32;
            key |= uint256(c) << (248 - 8 * i);
        }
        return (true, key);
    }

    function check(
        bytes memory b
    ) internal view {
        (bool ok, uint256 expected) = reference_(b);
        (bool success, bytes memory ret) = address(h).staticcall(abi.encodeCall(ChainNameHarness.key, (string(b))));
        assertEq(success, ok, "revert mismatch");
        if (ok) assertEq(abi.decode(ret, (uint256)), expected, "key mismatch");
        else assertEq(ret, abi.encodeWithSelector(AxelarStrings.InvalidChainName.selector), "wrong error");
    }

    function filled(
        uint256 n,
        bytes1 c
    ) internal pure returns (bytes memory b) {
        b = new bytes(n);
        for (uint256 i; i < n; ++i) {
            b[i] = c;
        }
    }

    /// ASCII lowercasing of one byte, the reference rule.
    function lower(
        uint256 c
    ) internal pure returns (uint256) {
        return c >= 0x41 && c <= 0x5a ? c + 32 : c;
    }

    /// Every nonzero byte value at every position of every length 1–32, beside `filler` neighbours. With one byte
    /// differing from a uniform name, the expected key is the filler's key with that lane replaced, so each check is
    /// O(1) and in-process; byte 0 is covered by `testNulAnywhereReverts`.
    function sweep(
        bytes1 filler
    ) internal pure {
        uint256 f = lower(uint8(filler));
        for (uint256 n = 1; n <= 32; ++n) {
            bytes memory b = filled(n, filler);
            string memory s = string(b);
            uint256 base;
            for (uint256 i; i < n; ++i) {
                base |= f << (248 - 8 * i);
            }
            for (uint256 p; p < n; ++p) {
                uint256 shift = 248 - 8 * p;
                uint256 others = base & ~(uint256(0xff) << shift);
                for (uint256 c = 1; c < 256; ++c) {
                    b[p] = bytes1(uint8(c));
                    uint256 got = AxelarStrings.chainKey(s);
                    uint256 expected = others | (lower(c) << shift);
                    if (got != expected) {
                        string memory at = string.concat(vm.toString(n), "/", vm.toString(p), "/", vm.toString(c));
                        assertEq(got, expected, string.concat("key mismatch at length/position/byte ", at));
                    }
                }
                b[p] = filler;
            }
        }
    }

    /// Together: all nonzero byte values at every position of every length 1–32, beside neighbours that stay
    /// unchanged (`a`) and that are lowercased (`Z`).
    function testEveryByteLowerNeighbours() public pure {
        sweep("a");
    }

    function testEveryByteUpperNeighbours() public pure {
        sweep("Z");
    }

    /// A single byte of every value, as a whole name: exact lowercasing boundaries.
    function testSingleByteMapping() public view {
        for (uint256 c = 1; c < 256; ++c) {
            uint256 expected = (c >= 0x41 && c <= 0x5a ? c + 32 : c) << 248;
            assertEq(h.key(string(abi.encodePacked(uint8(c)))), expected);
        }
        assertEq(h.key("@"), uint256(0x40) << 248);
        assertEq(h.key("A"), uint256(0x61) << 248);
        assertEq(h.key("Z"), uint256(0x7a) << 248);
        assertEq(h.key("["), uint256(0x5b) << 248);
        assertEq(h.key(string(abi.encodePacked(uint8(0x80)))), uint256(0x80) << 248);
        assertEq(h.key(string(abi.encodePacked(uint8(0xc1)))), uint256(0xc1) << 248); // 0x41 | 0x80: not uppercase
        assertEq(h.key(string(abi.encodePacked(uint8(0xda)))), uint256(0xda) << 248); // 0x5a | 0x80: not uppercase
    }

    function testWholeAlphabet() public view {
        assertEq(h.key("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), uint256(bytes32(bytes("abcdefghijklmnopqrstuvwxyz"))));
        assertEq(h.key("abcdefghijklmnopqrstuvwxyz"), uint256(bytes32(bytes("abcdefghijklmnopqrstuvwxyz"))));
        assertEq(h.key("0123456789-_.:/ !~"), uint256(bytes32(bytes("0123456789-_.:/ !~"))));
        assertEq(h.key("Ethereum"), uint256(bytes32(bytes("ethereum"))));
        assertEq(h.key("STELLAR-2026-Q1-2"), uint256(bytes32(bytes("stellar-2026-q1-2"))));
    }

    function testLengthBounds() public view {
        check("");
        check(filled(32, "A"));
        check(filled(33, "a"));
        check(filled(64, "a"));
        assertEq(h.key(string(filled(32, "A"))), uint256(bytes32(filled(32, "a"))));
    }

    function testNulAnywhereReverts() public view {
        for (uint256 n = 1; n <= 32; ++n) {
            for (uint256 p; p < n; ++p) {
                bytes memory b = filled(n, "a");
                b[p] = 0;
                vm.assertFalse(_ok(b));
            }
        }
    }

    function _ok(
        bytes memory b
    ) internal view returns (bool success) {
        (success,) = address(h).staticcall(abi.encodeCall(ChainNameHarness.key, (string(b))));
    }

    /// Random bytes at random lengths 0–40.
    function testFuzzRandomBytes(
        bytes32 lo,
        bytes32 hi,
        uint8 len
    ) public view {
        bytes memory raw = abi.encodePacked(lo, hi);
        bytes memory b = new bytes(bound(len, 0, 40));
        for (uint256 i; i < b.length; ++i) {
            b[i] = raw[i];
        }
        check(b);
    }

    /// Random names over printable ASCII (no NUL), the realistic input space, lengths 1–32.
    function testFuzzPrintable(
        bytes32 seed,
        uint8 len
    ) public view {
        bytes memory b = new bytes(bound(len, 1, 32));
        for (uint256 i; i < b.length; ++i) {
            b[i] = bytes1(uint8(0x20 + uint8(seed[i]) % 95));
        }
        check(b);
        assertTrue(_ok(b));
    }

    /// `name` inverts `key` up to lowercasing, and `key(name(k)) == k` (the setter's canonical check).
    function testFuzzNameRoundTrip(
        bytes32 seed,
        uint8 len
    ) public view {
        bytes memory b = new bytes(bound(len, 1, 32));
        for (uint256 i; i < b.length; ++i) {
            b[i] = bytes1(uint8(1 + uint8(seed[i]) % 255));
        }
        uint256 k = h.key(string(b));
        string memory n = h.name(k);
        assertEq(bytes(n).length, b.length);
        assertEq(uint256(bytes32(bytes(n))), k);
        assertEq(h.key(n), k);
    }

    function testNameStopsAtFirstZeroByte() public view {
        assertEq(h.name(0), "");
        assertEq(h.name(uint256(bytes32("base"))), "base");
        assertEq(h.name(uint256(bytes32("evm")) | 0xff), "evm");
        assertEq(h.name(uint256(bytes32("evm")) >> 8), "");
        assertEq(bytes(h.name(type(uint256).max)).length, 32);
    }
}
