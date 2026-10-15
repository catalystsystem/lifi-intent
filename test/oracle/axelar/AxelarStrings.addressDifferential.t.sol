// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import { AxelarStrings } from "../../../src/integrations/oracles/axelar/AxelarStrings.sol";
import { AddressStrings } from "./AddressStrings.sol";
import { OracleAddressReference } from "./OracleAddressReference.sol";
import { Test, console } from "forge-std/Test.sol";

contract Decoders {
    function ref(
        string calldata s
    ) external pure returns (bytes32) {
        return OracleAddressReference.decode(s);
    }

    function decode(
        string calldata s
    ) external pure returns (bytes32) {
        return AxelarStrings.decodeAddress(s);
    }

    /// Gas of each decoder alone, excluding call overhead.
    function gasOf(
        string calldata s
    ) external view returns (uint256 r, uint256 w) {
        uint256 g = gasleft();
        OracleAddressReference.decode(s);
        r = g - gasleft();
        g = gasleft();
        AxelarStrings.decodeAddress(s);
        w = g - gasleft();
    }
}

/// The word-at-a-time `AxelarStrings.decodeAddress` must agree with the per-character `OracleAddressReference.decode`
/// on every input: the same identifier, or the same revert data.
contract AxelarStringsAddressDifferentialTest is Test {
    Decoders d;

    bytes constant HEXCHARS = "0123456789abcdefABCDEF";
    bytes constant BASE32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    bytes constant BASE58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

    function setUp() public {
        d = new Decoders();
    }

    /// Compares both decoders on `data` (selector excluded); frees the memory the comparison allocates.
    function compareRaw(
        bytes memory args,
        bytes memory label
    ) internal view {
        uint256 fmp;
        assembly ("memory-safe") { fmp := mload(0x40) }
        (bool ok1, bytes memory r1) = address(d).staticcall(bytes.concat(Decoders.ref.selector, args));
        (bool ok2, bytes memory r2) = address(d).staticcall(bytes.concat(Decoders.decode.selector, args));
        if (ok1 != ok2 || keccak256(r1) != keccak256(r2)) {
            console.logBytes(label);
            assertEq(ok2, ok1, "success differs");
            assertEq(r2, r1, "result differs");
        }
        assembly ("memory-safe") { mstore(0x40, fmp) }
    }

    function check(
        bytes memory b
    ) internal view {
        compareRaw(abi.encode(string(b)), b);
    }

    function decodes(
        bytes memory b
    ) internal view returns (bool ok) {
        (ok,) = address(d).staticcall(abi.encodeCall(Decoders.decode, (string(b))));
    }

    function _evm(
        bytes32 id
    ) internal pure returns (bytes memory) {
        return bytes(AddressStrings.evm(bytes32(uint256(id) >> 96)));
    }

    // ---------------------------------------------------------------- valid inputs

    function testFuzzValidAddresses(
        bytes32 id
    ) public view {
        bytes32 low = bytes32(uint256(id) >> 96);
        assertEq(d.decode(string(_evm(id))), low);
        assertEq(d.decode(vm.toString(address(uint160(uint256(id))))), bytes32(uint256(uint160(uint256(id)))));
        assertEq(d.decode(AddressStrings.stellar(id)), id);
        assertEq(d.decode(AddressStrings.solana(id)), id);
    }

    /// Every case mix of every lowercase-hex EVM string decodes to the same identifier.
    function testFuzzEvmCaseInsensitive(
        address a,
        uint256 caseMask
    ) public view {
        bytes memory s = _evm(bytes32(uint256(uint160(a)) << 96));
        for (uint256 i = 2; i < 42; ++i) {
            if (caseMask >> i & 1 == 1 && s[i] >= "a") s[i] = bytes1(uint8(s[i]) - 32);
        }
        assertEq(d.decode(string(s)), bytes32(uint256(uint160(a))));
    }

    function testBoundaryIdentifiers() public view {
        bytes32[6] memory ids = [
            bytes32(0),
            bytes32(type(uint256).max),
            bytes32(uint256(1)),
            bytes32(uint256(1) << 255),
            bytes32(0x5555555555555555555555555555555555555555555555555555555555555555),
            bytes32(0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
        ];
        for (uint256 i; i < ids.length; ++i) {
            bytes32 low = bytes32(uint256(ids[i]) >> 96);
            assertEq(d.decode(string(_evm(ids[i]))), low);
            assertEq(d.decode(AddressStrings.stellar(ids[i])), ids[i]);
            assertEq(d.decode(AddressStrings.solana(ids[i])), ids[i]);
        }
    }

    /// Every single-bit identifier: exercises each nibble/5-bit lane and each CRC table entry in isolation.
    function testEverySingleBitIdentifier() public view {
        for (uint256 bit; bit < 256; ++bit) {
            bytes32 id = bytes32(uint256(1) << bit);
            assertEq(d.decode(AddressStrings.stellar(id)), id);
            if (bit < 160) assertEq(d.decode(string(_evm(bytes32(uint256(id) << 96)))), id);
        }
    }

    function testKnownVectors() public view {
        // Stellar zero contract and EIP-55 examples from the EIP.
        assertEq(d.decode("CAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABSC4"), bytes32(0));
        assertEq(d.decode("CAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD2KM"), bytes32(uint256(1)));
        assertEq(
            d.decode("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"),
            bytes32(uint256(uint160(0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed)))
        );
        assertEq(
            d.decode("0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"),
            bytes32(uint256(uint160(0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359)))
        );
        // Mainnet native XLM and USDC Stellar asset contracts: accepted, and equal to the reference.
        check("CAS3J7GYLGXMF6TDJBBYYSE3HQ6BBSMLNUQ34T6TZMYMW2EVH34XOWMA");
        check("CCW67TSZV3SSS2HXMBQ5JFGCKJNXKZM7UQUWUZPUTHXSTZLEO7SJMI75");
        assertTrue(decodes("CAS3J7GYLGXMF6TDJBBYYSE3HQ6BBSMLNUQ34T6TZMYMW2EVH34XOWMA"));
        assertTrue(decodes("CCW67TSZV3SSS2HXMBQ5JFGCKJNXKZM7UQUWUZPUTHXSTZLEO7SJMI75"));
    }

    // ---------------------------------------------------------------- rejection

    function testRejectsShapes() public view {
        string[12] memory bad = [
            "",
            "0",
            "0x",
            "0x0",
            "0X0000000000000000000000000000000000000000",
            "0x000000000000000000000000000000000000000",
            "0x00000000000000000000000000000000000000000",
            "0x000000000000000000000000000000000000000g",
            "0x 000000000000000000000000000000000000000",
            // G… account StrKey (version 0x30), lowercase StrKey, StrKey with padding character.
            "GAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAWHF",
            "caaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaad2km",
            "CAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABSC="
        ];
        for (uint256 i; i < bad.length; ++i) {
            check(bytes(bad[i]));
            assertFalse(decodes(bytes(bad[i])), bad[i]);
        }
    }

    /// Every byte value at every position of a valid mixed-case EVM string, prefix included.
    function testEveryByteEveryPositionEvm() public view {
        bytes memory base = bytes(vm.toString(0xabCDeF0123456789AbcdEf0123456789aBCDEF01));
        for (uint256 pos; pos < 42; ++pos) {
            bytes1 keep = base[pos];
            for (uint256 c; c < 256; ++c) {
                base[pos] = bytes1(uint8(c));
                check(base);
            }
            base[pos] = keep;
        }
    }

    function _stellarSweep(
        uint256 from,
        uint256 to
    ) internal view {
        bytes memory base = bytes(AddressStrings.stellar(keccak256("stellar sweep")));
        for (uint256 pos = from; pos < to; ++pos) {
            bytes1 keep = base[pos];
            for (uint256 c; c < 256; ++c) {
                base[pos] = bytes1(uint8(c));
                check(base);
            }
            base[pos] = keep;
        }
    }

    /// Every byte value at every position of a valid StrKey, version and checksum characters included.
    function testEveryByteEveryPositionStellar0To19() public view {
        _stellarSweep(0, 19);
    }

    function testEveryByteEveryPositionStellar19To38() public view {
        _stellarSweep(19, 38);
    }

    function testEveryByteEveryPositionStellar38To56() public view {
        _stellarSweep(38, 56);
    }

    /// Every length 0–100 of strings drawn from each alphabet, with and without the `0x` prefix: only the shapes
    /// the dispatch selects can succeed, and both decoders agree on all of them.
    function testEveryLength() public view {
        bytes memory hexs = new bytes(100);
        bytes memory b32 = new bytes(100);
        bytes memory b58 = new bytes(100);
        for (uint256 i; i < 100; ++i) {
            hexs[i] = HEXCHARS[i % HEXCHARS.length];
            b32[i] = BASE32[i % 32];
            b58[i] = BASE58[i % 58];
        }
        (hexs[0], hexs[1]) = ("0", "x");
        for (uint256 n; n <= 100; ++n) {
            bytes memory h = new bytes(n);
            bytes memory s = new bytes(n);
            bytes memory t = new bytes(n);
            for (uint256 i; i < n; ++i) {
                h[i] = hexs[i];
                s[i] = b32[i];
                t[i] = b58[i];
            }
            check(h);
            check(s);
            check(t);
            if (n != 42) assertFalse(decodes(h));
        }
    }

    /// Bytes after the string in calldata (junk instead of zero padding, or no padding at all at the end of
    /// calldata) must not affect the result, since the decoder reads whole words past the string's end.
    function testFuzzCalldataAroundString(
        bytes32 id,
        bytes32 junk,
        uint8 shape
    ) public view {
        bytes memory s =
            shape % 3 == 0 ? _evm(id) : bytes(shape % 3 == 1 ? AddressStrings.stellar(id) : AddressStrings.solana(id));
        bytes memory head = abi.encodePacked(uint256(0x20), s.length, s);
        // Junk where zero padding would be, plus a full junk word after it.
        bytes memory padded = bytes.concat(head, new bytes((32 - s.length % 32) % 32), junk);
        for (uint256 i = head.length; i < padded.length; ++i) {
            padded[i] = junk[i % 32];
        }
        compareRaw(padded, s);
        compareRaw(head, s);
        (bool ok,) = address(d).staticcall(bytes.concat(Decoders.decode.selector, padded));
        assertTrue(ok);
        (ok,) = address(d).staticcall(bytes.concat(Decoders.decode.selector, head));
        assertTrue(ok);
    }

    /// A valid EVM string followed by a valid-hex continuation in calldata is still rejected at length 41.
    function testTruncatedEvmWithHexAfterIt() public view {
        bytes memory s = _evm(keccak256("t"));
        bytes memory head = abi.encodePacked(uint256(0x20), uint256(41), s, bytes22("0000000000000000000000"));
        compareRaw(head, s);
        (bool ok,) = address(d).staticcall(bytes.concat(Decoders.decode.selector, head));
        assertFalse(ok);
    }

    // ---------------------------------------------------------------- random

    /// Valid-alphabet hex strings of random content at lengths 0–50, prefixed with `0x`.
    function testFuzzHexShaped(
        bytes32 a,
        bytes32 b,
        uint8 len
    ) public view {
        uint256 n = bound(len, 0, 50);
        bytes memory s = new bytes(n);
        for (uint256 i; i < n; ++i) {
            bytes32 r = i < 32 ? a : b;
            s[i] = HEXCHARS[uint8(r[i % 32]) % HEXCHARS.length];
        }
        if (n >= 2) (s[0], s[1]) = ("0", "x");
        check(s);
    }

    /// Random 42-byte strings behind `0x`: mostly non-hex lanes in random positions.
    function testFuzzEvmRandomBody(
        bytes32 a,
        bytes8 b
    ) public view {
        check(abi.encodePacked("0x", a, b));
    }

    /// Random alphabet StrKey-length strings: mostly version or checksum failures.
    function testFuzzBase32Shaped(
        bytes32 a,
        bytes24 b
    ) public view {
        bytes memory s = abi.encodePacked(a, b);
        for (uint256 i; i < 56; ++i) {
            s[i] = BASE32[uint8(s[i]) % 32];
        }
        check(s);
    }

    /// A valid StrKey with one or two characters replaced by random alphabet characters. A single replacement is a
    /// burst of at most 5 bits, which CRC16 always detects; two distant replacements are not guaranteed to be.
    function testFuzzStellarCharFlips(
        bytes32 id,
        uint8 p1,
        uint8 c1,
        uint8 p2,
        uint8 c2,
        bool two
    ) public view {
        bytes memory s = bytes(AddressStrings.stellar(id));
        bytes memory orig = bytes.concat(s);
        s[p1 % 56] = BASE32[c1 % 32];
        if (two) s[p2 % 56] = BASE32[c2 % 32];
        check(s);
        if (!two) assertEq(decodes(s), keccak256(s) == keccak256(orig));
    }

    /// Random bytes of random length.
    function testFuzzRawBytes(
        bytes calldata s
    ) public view {
        check(s);
    }

    /// Valid-looking base58 strings of random content at lengths 30–46.
    function testFuzzBase58Shaped(
        bytes32 a,
        bytes32 b,
        uint8 len
    ) public view {
        uint256 n = bound(len, 30, 46);
        bytes memory s = new bytes(n);
        for (uint256 i; i < n; ++i) {
            bytes32 r = i < 32 ? a : b;
            s[i] = BASE58[uint8(r[i % 32]) % 58];
        }
        check(s);
    }

    function testGas() public view {
        bytes32 id = keccak256("x");
        (uint256 r, uint256 w) = d.gasOf(string(_evm(id)));
        console.log("evm     reference %d new %d", r, w);
        (r, w) = d.gasOf(AddressStrings.stellar(id));
        console.log("stellar reference %d new %d", r, w);
        (r, w) = d.gasOf(AddressStrings.solana(id));
        console.log("solana  reference %d new %d", r, w);
    }
}
