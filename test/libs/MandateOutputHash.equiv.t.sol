// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test, console2 } from "forge-std/Test.sol";
import { MandateOutput } from "../../src/input/types/MandateOutputType.sol";
import { MandateOutputEncodingLib } from "../../src/libs/MandateOutputEncodingLib.sol";
import { RefEncodingLib } from "test/util/RefEncodingLib.sol";

/// @notice Harness exposing calldata + memory entrypoints so the assembly hashers can be compared, on identical
/// inputs, against `keccak256(encode*(...))` built by the (still-present) reference encoders. Each bench entrypoint
/// runs exactly ONE implementation and returns its hash, so the external-call overhead cancels in the A/B delta and
/// the pure call cannot be optimised away.
contract HashEquivHarness {
    // --- equivalence (both impls, same call) ---
    function mo(
        MandateOutput calldata o
    ) external pure returns (bytes32 asmHash, bytes32 encHash) {
        asmHash = MandateOutputEncodingLib.getMandateOutputHash(o);
        encHash = keccak256(RefEncodingLib.encodeMandateOutput(o));
    }

    function fill(bytes32 s, bytes32 id, uint32 t, MandateOutput calldata o)
        external
        pure
        returns (bytes32 asmHash, bytes32 encHash)
    {
        asmHash = MandateOutputEncodingLib.hashFillDescription(s, id, t, o);
        encHash = keccak256(RefEncodingLib.encodeFillDescription(s, id, t, o));
    }

    function notFilled(bytes32 id, uint32 d, MandateOutput calldata o)
        external
        pure
        returns (bytes32 asmHash, bytes32 encHash)
    {
        asmHash = MandateOutputEncodingLib.hashNotFilledDescription(id, d, o);
        encHash = keccak256(RefEncodingLib.encodeNotFilledDescription(id, d, o));
    }

    function moMem(
        MandateOutput memory o
    ) external pure returns (bytes32 asmHash, bytes32 encHash) {
        asmHash = MandateOutputEncodingLib.getMandateOutputHashMemory(o);
        encHash = keccak256(RefEncodingLib.encodeMandateOutputMemory(o));
    }

    function fillMem(bytes32 s, bytes32 id, uint32 t, MandateOutput memory o)
        external
        pure
        returns (bytes32 asmHash, bytes32 encHash)
    {
        asmHash = MandateOutputEncodingLib.hashFillDescriptionMemory(s, id, t, o);
        encHash = keccak256(RefEncodingLib.encodeFillDescriptionMemory(s, id, t, o));
    }

    function notFilledMem(bytes32 id, uint32 d, MandateOutput memory o)
        external
        pure
        returns (bytes32 asmHash, bytes32 encHash)
    {
        asmHash = MandateOutputEncodingLib.hashNotFilledDescriptionMemory(id, d, o);
        encHash = keccak256(RefEncodingLib.encodeNotFilledDescriptionMemory(id, d, o));
    }

    // --- single-impl bench entrypoints ---
    function fillAsm(bytes32 s, bytes32 id, uint32 t, MandateOutput calldata o) external pure returns (bytes32) {
        return MandateOutputEncodingLib.hashFillDescription(s, id, t, o);
    }

    function fillEnc(bytes32 s, bytes32 id, uint32 t, MandateOutput calldata o) external pure returns (bytes32) {
        return keccak256(RefEncodingLib.encodeFillDescription(s, id, t, o));
    }

    function moAsm(
        MandateOutput calldata o
    ) external pure returns (bytes32) {
        return MandateOutputEncodingLib.getMandateOutputHash(o);
    }

    function moEnc(
        MandateOutput calldata o
    ) external pure returns (bytes32) {
        return keccak256(RefEncodingLib.encodeMandateOutput(o));
    }
}

contract MandateOutputHashEquivTest is Test {
    HashEquivHarness private h;

    // representative non-zero header
    bytes32 constant SOLVER = bytes32(uint256(type(uint256).max) / 0xff * 0x11);
    bytes32 constant ORDERID = bytes32(uint256(type(uint256).max) / 0xff * 0x22);
    bytes32 constant TOKEN = bytes32(uint256(type(uint256).max) / 0xff * 0x33);
    bytes32 constant RECIPIENT = bytes32(uint256(type(uint256).max) / 0xff * 0x44);
    bytes32 constant ORACLE = bytes32(uint256(type(uint256).max) / 0xff * 0x55);
    bytes32 constant SETTLER = bytes32(uint256(type(uint256).max) / 0xff * 0x66);
    uint32 constant TS = 0x01020304;
    uint32 constant DEADLINE = 0xfffefdfc;
    uint256 constant AMOUNT = type(uint256).max;

    function setUp() public {
        h = new HashEquivHarness();
    }

    // --- boundary matrix around every word / field transition ---

    function test_equiv_boundary_matrix() external view {
        uint256[13] memory lens = [uint256(0), 1, 2, 3, 31, 32, 33, 63, 64, 65, 255, 256, 300];
        for (uint256 i; i < lens.length; ++i) {
            for (uint256 j; j < lens.length; ++j) {
                _assertAllEquiv(_output(lens[i], lens[j]));
            }
        }
    }

    function test_equiv_zero_header() external view {
        MandateOutput memory o = MandateOutput(bytes32(0), bytes32(0), 0, bytes32(0), 0, bytes32(0), hex"", hex"");
        _assertAllEquiv(o);
    }

    function test_equiv_u16_max_tails() external view {
        // Independently varied max-length tails (not a single repeating pattern).
        _assertAllEquiv(_output(type(uint16).max, type(uint16).max - 1));
        _assertAllEquiv(_output(type(uint16).max - 1, type(uint16).max));
    }

    function test_fuzz_equiv(
        bytes32 solver,
        bytes32 orderId,
        uint32 t,
        uint32 deadline,
        bytes32 oracle,
        bytes32 settler,
        bytes32 token,
        uint256 amount,
        bytes32 recipient,
        bytes memory callbackData,
        bytes memory context
    ) external view {
        if (callbackData.length > 2048) assembly ("memory-safe") { mstore(callbackData, 2048) }
        if (context.length > 2048) assembly ("memory-safe") { mstore(context, 2048) }
        MandateOutput memory o =
            MandateOutput(oracle, settler, uint256(t) ^ amount, token, amount, recipient, callbackData, context);
        // Delegate to shallow per-encoding helpers so no single frame holds enough live locals to hit
        // stack-too-deep under the legacy (no-via-IR / no-optimizer) pipeline used by `forge coverage`.
        _eqMo(o);
        _eqFill(solver, orderId, t, o);
        _eqNotFilled(orderId, deadline, o);
    }

    // --- revert ordering parity: CallOutOfRange before ContextOutOfRange ---

    function test_revert_ordering_matches_encoder() external {
        MandateOutput memory over =
            MandateOutput(ORACLE, SETTLER, 1, TOKEN, AMOUNT, RECIPIENT, new bytes(65_536), new bytes(65_536));
        // memory paths (callable with the in-memory struct)
        vm.expectRevert(MandateOutputEncodingLib.CallOutOfRange.selector);
        h.moMem(over);
        vm.expectRevert(MandateOutputEncodingLib.CallOutOfRange.selector);
        h.fillMem(SOLVER, ORDERID, TS, over);
        vm.expectRevert(MandateOutputEncodingLib.CallOutOfRange.selector);
        h.notFilledMem(ORDERID, DEADLINE, over);

        over.callbackData = new bytes(0);
        vm.expectRevert(MandateOutputEncodingLib.ContextOutOfRange.selector);
        h.moMem(over);
        vm.expectRevert(MandateOutputEncodingLib.ContextOutOfRange.selector);
        h.fillMem(SOLVER, ORDERID, TS, over);
        vm.expectRevert(MandateOutputEncodingLib.ContextOutOfRange.selector);
        h.notFilledMem(ORDERID, DEADLINE, over);
    }

    // --- common-payload reconstruction identity (receive-side path) ---

    function test_commonPayload_identity() external view {
        MandateOutput memory o = _output(40, 71);
        bytes memory fillBytes = RefEncodingLib.encodeFillDescriptionMemory(SOLVER, ORDERID, TS, o);
        bytes memory notFilledBytes = RefEncodingLib.encodeNotFilledDescriptionMemory(ORDERID, DEADLINE, o);

        bytes memory fromFill = _slice(fillBytes, MandateOutputEncodingLib.FILL_COMMON_PAYLOAD_OFFSET);
        bytes memory fromNotFilled = _slice(notFilledBytes, MandateOutputEncodingLib.NOT_FILLED_COMMON_PAYLOAD_OFFSET);
        assertEq(fromFill, fromNotFilled, "common payload identical across domains");

        bytes32 viaCommon = this.commonHash(o.oracle, o.settler, o.chainId, fromFill);
        bytes32 direct = MandateOutputEncodingLib.getMandateOutputHashMemory(o);
        assertEq(viaCommon, direct, "common-payload reconstruction == MandateOutput hash");
    }

    function commonHash(bytes32 oracle, bytes32 settler, uint256 chainId, bytes calldata common)
        external
        pure
        returns (bytes32)
    {
        return MandateOutputEncodingLib.getMandateOutputHashFromCommonPayload(oracle, settler, chainId, common);
    }

    // --- memory-safety canary: hashing must not corrupt subsequently-allocated memory ---

    function test_memory_safety_canary() external view {
        MandateOutput memory o = _output(200, 133);
        (bytes32 expected,) = h.fillMem(SOLVER, ORDERID, TS, o);
        // Allocate fresh memory AFTER the hasher ran (it packed scratch above the free pointer without bumping it).
        bytes memory canary = new bytes(512);
        for (uint256 i; i < canary.length; ++i) canary[i] = bytes1(uint8(i));
        // Re-hash: must still match, proving the scratch write did not corrupt live state or the input.
        (bytes32 again,) = h.fillMem(SOLVER, ORDERID, TS, o);
        assertEq(again, expected, "hash stable across interleaved allocation");
        for (uint256 i; i < canary.length; ++i) assertEq(uint8(canary[i]), uint8(i), "canary intact");
    }

    // --- micro-benchmark (report-only; run with -vv) ---

    function test_bench_report() external {
        MandateOutput memory small = _output(0, 0);
        MandateOutput memory mid = _output(128, 128);
        MandateOutput memory big = _output(1024, 1024);
        _bench("fill/empty", small);
        _bench("fill/128+128", mid);
        _bench("fill/1024+1024", big);
        _benchMo("mo/empty", small);
        _benchMo("mo/1024+1024", big);
    }

    /// @dev Report-only (indicative). Each path is WARMED once before measuring so the delta is not polluted by
    /// cold-account/first-call costs; the constant external-call overhead then cancels in the asm-vs-encode delta.
    /// These are rough figures — the authoritative per-op comparison is the snapshot-based measurement in the plan.
    function _bench(string memory label, MandateOutput memory o) private view {
        h.fillAsm(SOLVER, ORDERID, TS, o); // warm
        h.fillEnc(SOLVER, ORDERID, TS, o); // warm
        uint256 g = gasleft();
        h.fillAsm(SOLVER, ORDERID, TS, o);
        uint256 gAsm = g - gasleft();
        g = gasleft();
        h.fillEnc(SOLVER, ORDERID, TS, o);
        uint256 gEnc = g - gasleft();
        _report("FillDescription", label, gEnc, gAsm);
    }

    function _benchMo(string memory label, MandateOutput memory o) private view {
        h.moAsm(o); // warm
        h.moEnc(o); // warm
        uint256 g = gasleft();
        h.moAsm(o);
        uint256 gAsm = g - gasleft();
        g = gasleft();
        h.moEnc(o);
        uint256 gEnc = g - gasleft();
        _report("MandateOutput", label, gEnc, gAsm);
    }

    function _report(string memory kind, string memory label, uint256 gEnc, uint256 gAsm) private pure {
        console2.log(string.concat("--- ", kind, " ", label));
        console2.log("  encode+keccak gas", gEnc);
        console2.log("  assembly hash gas", gAsm);
        if (gEnc >= gAsm) console2.log("  saved", gEnc - gAsm);
        else console2.log("  REGRESSED by", gAsm - gEnc);
    }

    // --- helpers ---

    function _assertAllEquiv(
        MandateOutput memory o
    ) private view {
        _eqMo(o);
        _eqFill(SOLVER, ORDERID, TS, o);
        _eqNotFilled(ORDERID, DEADLINE, o);
    }

    // Shallow per-encoding helpers (≤4 live locals each) — keep every frame under the legacy-pipeline stack limit.
    function _eqMo(
        MandateOutput memory o
    ) private view {
        (bytes32 a, bytes32 e) = h.mo(o);
        assertEq(a, e, "mo");
        (bytes32 am, bytes32 em) = h.moMem(o);
        assertEq(am, em, "moMem");
        assertEq(a, am, "mo cd==mem");
    }

    function _eqFill(bytes32 s, bytes32 id, uint32 t, MandateOutput memory o) private view {
        (bytes32 a, bytes32 e) = h.fill(s, id, t, o);
        assertEq(a, e, "fill");
        (bytes32 am, bytes32 em) = h.fillMem(s, id, t, o);
        assertEq(am, em, "fillMem");
        assertEq(a, am, "fill cd==mem");
    }

    function _eqNotFilled(bytes32 id, uint32 d, MandateOutput memory o) private view {
        (bytes32 a, bytes32 e) = h.notFilled(id, d, o);
        assertEq(a, e, "notFilled");
        (bytes32 am, bytes32 em) = h.notFilledMem(id, d, o);
        assertEq(am, em, "notFilledMem");
        assertEq(a, am, "notFilled cd==mem");
    }

    function _output(uint256 cbLen, uint256 ctxLen) private pure returns (MandateOutput memory) {
        return MandateOutput(ORACLE, SETTLER, uint256(0xC0FFEE), TOKEN, AMOUNT, RECIPIENT, _pat(cbLen, 17), _pat(ctxLen, 29));
    }

    function _pat(uint256 n, uint256 seed) private pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; ++i) out[i] = bytes1(uint8(i * seed + 7));
    }

    function _slice(bytes memory data, uint256 from) private pure returns (bytes memory out) {
        out = new bytes(data.length - from);
        for (uint256 i; i < out.length; ++i) out[i] = data[from + i];
    }
}
