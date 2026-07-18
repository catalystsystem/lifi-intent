// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";

import { MandateOutput, MandateOutputEncodingLib } from "../../src/libs/MandateOutputEncodingLib.sol";
import { RefEncodingLib } from "../util/RefEncodingLib.sol";

/// @notice Golden-vector suite for the packed encodings. Production no longer exposes byte encoders; each absolute
/// hex vector is now pinned from BOTH sides:
///   1. `RefEncodingLib.encodeX(inputs) == hex"golden"` — the independent test builder reproduces the exact wire
///      layout (guards the format / off-chain relayer contract).
///   2. `keccak256(hex"golden") == MandateOutputEncodingLib.hashX(inputs)` — the production direct-hasher hashes
///      exactly that preimage (guards the assembly, calldata and memory).
contract MandateOutputEncodingLibTest is Test {
    // --- production direct-hash entrypoints (calldata + memory) ---
    function hashMoCd(
        MandateOutput calldata output
    ) external pure returns (bytes32) {
        return MandateOutputEncodingLib.getMandateOutputHash(output);
    }

    function hashMoMem(
        MandateOutput memory output
    ) external pure returns (bytes32) {
        return MandateOutputEncodingLib.getMandateOutputHashMemory(output);
    }

    function hashFillCd(bytes32 solver, bytes32 orderId, uint32 timestamp, MandateOutput calldata output)
        external
        pure
        returns (bytes32)
    {
        return MandateOutputEncodingLib.hashFillDescription(solver, orderId, timestamp, output);
    }

    function hashFillMem(bytes32 solver, bytes32 orderId, uint32 timestamp, MandateOutput memory output)
        external
        pure
        returns (bytes32)
    {
        return MandateOutputEncodingLib.hashFillDescriptionMemory(solver, orderId, timestamp, output);
    }

    function hashNotFilledCd(bytes32 orderId, uint32 fillDeadline, MandateOutput calldata output)
        external
        pure
        returns (bytes32)
    {
        return MandateOutputEncodingLib.hashNotFilledDescription(orderId, fillDeadline, output);
    }

    function hashNotFilledMem(bytes32 orderId, uint32 fillDeadline, MandateOutput memory output)
        external
        pure
        returns (bytes32)
    {
        return MandateOutputEncodingLib.hashNotFilledDescriptionMemory(orderId, fillDeadline, output);
    }

    function loadHarness(
        bytes calldata payload
    ) external pure returns (bytes32 solver, bytes32 orderId, uint32 timestamp) {
        solver = MandateOutputEncodingLib.loadSolverFromFillDescription(payload);
        orderId = MandateOutputEncodingLib.loadOrderIdFromFillDescription(payload);
        timestamp = MandateOutputEncodingLib.loadTimestampFromFillDescription(payload);
    }

    function loadNotFilledHarness(
        bytes calldata payload
    ) external pure returns (bytes32 orderId, uint32 fillDeadline) {
        orderId = MandateOutputEncodingLib.loadOrderIdFromNotFilledDescription(payload);
        fillDeadline = MandateOutputEncodingLib.loadFillDeadlineFromNotFilledDescription(payload);
    }

    // --- MandateOutput golden vectors ---

    function test_encodeMandateOutput() external view {
        // The goal of this output is to fill all bytes such that no bytes are left empty.
        // This allows for better comparison to other vm implementations incase something is wrong.
        MandateOutput memory output = MandateOutput({
            oracle: keccak256(bytes("outputOracle")),
            settler: keccak256(bytes("outputSettler")),
            chainId: uint256(keccak256(bytes("chainId"))),
            token: keccak256(bytes("token")),
            amount: uint256(keccak256(bytes("amount"))),
            recipient: keccak256(bytes("recipient")),
            callbackData: hex"",
            context: hex""
        });

        bytes memory golden =
            hex"4f9c60d16f18ede78fc0a6cfbe7ef0072cdda8cbb9b0b90c5d3578541cb3c1616aa1b29f675730a3d41062603d83a385b254be1e9338406698f9ea0702586f9e8ed9144e2f2122812934305f889c544efe55db33a5fd4b235aaab787c3f913d49b9b0454cadcb5884dd3faa6ba975da4d2459aa3f11d31291a25a8358f84946d89c4783cb6cc307f98e95f2d5d5d8647bdb3d4bdd087209374f187b38e098895811085f5b5d1b29598e73ca51de3d712f5d3103ad50e22dc1f4d3ff1559d511500000000";
        _pinMo(output, golden);

        output.callbackData = abi.encodePacked(keccak256(hex""), keccak256(hex"01"), bytes3(0x010203));
        output.context = abi.encodePacked(
            keccak256(hex"02"), keccak256(hex"03"), keccak256(hex"04"), keccak256(hex"05"), bytes4(0x01020304)
        );

        golden =
            hex"4f9c60d16f18ede78fc0a6cfbe7ef0072cdda8cbb9b0b90c5d3578541cb3c1616aa1b29f675730a3d41062603d83a385b254be1e9338406698f9ea0702586f9e8ed9144e2f2122812934305f889c544efe55db33a5fd4b235aaab787c3f913d49b9b0454cadcb5884dd3faa6ba975da4d2459aa3f11d31291a25a8358f84946d89c4783cb6cc307f98e95f2d5d5d8647bdb3d4bdd087209374f187b38e098895811085f5b5d1b29598e73ca51de3d712f5d3103ad50e22dc1f4d3ff1559d51150043c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a4705fe7f977e71dba2ea1a68e21057beebb9be2ac30c6410aa38d4f3fbe41dcffd20102030084f2ee15ea639b73fa3db9b34a245bdfa015c260c598b211bf05a1ecc4b3e3b4f269c322e3248a5dfc29d73c5b0553b0185a35cd5bb6386747517ef7e53b15e287f343681465b9efe82c933c3e8748c70cb8aa06539c361de20f72eac04e766393dbb8d0f4c497851a5043c6363657698cb1387682cac2f786c731f8936109d79501020304";
        _pinMo(output, golden);
    }

    function test_revert_encodeMandateOutput_CallOutOfRange() external {
        MandateOutput memory output = _named(new bytes(65535 - 1), new bytes(0));
        this.hashMoCd(output);
        this.hashMoMem(output);

        output.callbackData = new bytes(65536);
        vm.expectRevert(MandateOutputEncodingLib.CallOutOfRange.selector);
        this.hashMoCd(output);
        vm.expectRevert(MandateOutputEncodingLib.CallOutOfRange.selector);
        this.hashMoMem(output);
    }

    function test_revert_encodeMandateOutput_ContextCallOutOfRange() external {
        MandateOutput memory output = _named(new bytes(0), new bytes(65535 - 1));
        this.hashMoCd(output);
        this.hashMoMem(output);

        output.context = new bytes(65536);
        vm.expectRevert(MandateOutputEncodingLib.ContextOutOfRange.selector);
        this.hashMoCd(output);
        vm.expectRevert(MandateOutputEncodingLib.ContextOutOfRange.selector);
        this.hashMoMem(output);
    }

    // --- FillDescription golden vectors ---

    function test_encodeFillDescription() external view {
        bytes32 solver = keccak256(bytes("solver"));
        bytes32 orderId = keccak256(bytes("orderId"));
        uint32 timestamp = uint32(uint256(keccak256(bytes("timestamp"))));
        MandateOutput memory output = _named(hex"", hex"");

        bytes memory golden =
            hex"d1252dff1da5212527b611fa26a679f652ca82511b7def2f4c7af4d7bb6f175835f323dcaad60a3265e1c3c0dff4ef3474d6c608ca5f7ec61bd7dcbc5a992ad0576306911227958e9b9b0454cadcb5884dd3faa6ba975da4d2459aa3f11d31291a25a8358f84946d89c4783cb6cc307f98e95f2d5d5d8647bdb3d4bdd087209374f187b38e098895811085f5b5d1b29598e73ca51de3d712f5d3103ad50e22dc1f4d3ff1559d511500000000";
        _pinFill(solver, orderId, timestamp, output, golden);

        output.callbackData = abi.encodePacked(keccak256(hex""), keccak256(hex"01"), bytes3(0x010203));
        output.context = abi.encodePacked(
            keccak256(hex"02"), keccak256(hex"03"), keccak256(hex"04"), keccak256(hex"05"), bytes4(0x01020304)
        );

        golden =
            hex"d1252dff1da5212527b611fa26a679f652ca82511b7def2f4c7af4d7bb6f175835f323dcaad60a3265e1c3c0dff4ef3474d6c608ca5f7ec61bd7dcbc5a992ad0576306911227958e9b9b0454cadcb5884dd3faa6ba975da4d2459aa3f11d31291a25a8358f84946d89c4783cb6cc307f98e95f2d5d5d8647bdb3d4bdd087209374f187b38e098895811085f5b5d1b29598e73ca51de3d712f5d3103ad50e22dc1f4d3ff1559d51150043c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a4705fe7f977e71dba2ea1a68e21057beebb9be2ac30c6410aa38d4f3fbe41dcffd20102030084f2ee15ea639b73fa3db9b34a245bdfa015c260c598b211bf05a1ecc4b3e3b4f269c322e3248a5dfc29d73c5b0553b0185a35cd5bb6386747517ef7e53b15e287f343681465b9efe82c933c3e8748c70cb8aa06539c361de20f72eac04e766393dbb8d0f4c497851a5043c6363657698cb1387682cac2f786c731f8936109d79501020304";
        _pinFill(solver, orderId, timestamp, output, golden);
    }

    function test_revert_encodeFillDescription_CallOutOfRange() external {
        bytes32 solver = keccak256(bytes("solver"));
        bytes32 orderId = keccak256(bytes("orderId"));
        uint32 timestamp = uint32(uint256(keccak256(bytes("timestamp"))));
        MandateOutput memory output = _named(new bytes(65536 - 1), hex"");

        this.hashFillCd(solver, orderId, timestamp, output);
        this.hashFillMem(solver, orderId, timestamp, output);

        output.callbackData = new bytes(65536);
        vm.expectRevert(MandateOutputEncodingLib.CallOutOfRange.selector);
        this.hashFillCd(solver, orderId, timestamp, output);
        vm.expectRevert(MandateOutputEncodingLib.CallOutOfRange.selector);
        this.hashFillMem(solver, orderId, timestamp, output);
    }

    function test_revert_encodeFillDescription_ContextCallOutOfRange() external {
        bytes32 solver = keccak256(bytes("solver"));
        bytes32 orderId = keccak256(bytes("orderId"));
        uint32 timestamp = uint32(uint256(keccak256(bytes("timestamp"))));
        MandateOutput memory output = _named(hex"", new bytes(65536 - 1));

        this.hashFillCd(solver, orderId, timestamp, output);
        this.hashFillMem(solver, orderId, timestamp, output);

        output.context = new bytes(65536);
        vm.expectRevert(MandateOutputEncodingLib.ContextOutOfRange.selector);
        this.hashFillCd(solver, orderId, timestamp, output);
        vm.expectRevert(MandateOutputEncodingLib.ContextOutOfRange.selector);
        this.hashFillMem(solver, orderId, timestamp, output);
    }

    // --- NotFilledDescription --- //

    /// @dev The 4-byte magics are truncated keccak outputs; unlike the full 32-byte hashes their distinctness is not
    /// self-evident, so pin both values (and thereby their distinctness) explicitly. A future tag addition must not
    /// collide in the truncated space.
    function test_domain_magics() external pure {
        assertEq(MandateOutputEncodingLib.FILL_MAGIC, bytes4(0xd1252dff));
        assertEq(MandateOutputEncodingLib.NOT_FILLED_MAGIC, bytes4(0x830c1e1c));
        assertEq(MandateOutputEncodingLib.FILL_MAGIC, bytes4(keccak256("OIF.Fill")));
        assertEq(MandateOutputEncodingLib.NOT_FILLED_MAGIC, bytes4(keccak256("OIF.NotFilled")));
        assertTrue(MandateOutputEncodingLib.FILL_MAGIC != MandateOutputEncodingLib.NOT_FILLED_MAGIC);
    }

    function test_encodeNotFilledDescription() external view {
        bytes32 orderId = keccak256(bytes("orderId"));
        uint32 fillDeadline = uint32(uint256(keccak256(bytes("fillDeadline"))));
        MandateOutput memory output = _named(hex"", hex"");

        bytes memory golden =
            hex"830c1e1caad60a3265e1c3c0dff4ef3474d6c608ca5f7ec61bd7dcbc5a992ad057630691c9757d059b9b0454cadcb5884dd3faa6ba975da4d2459aa3f11d31291a25a8358f84946d89c4783cb6cc307f98e95f2d5d5d8647bdb3d4bdd087209374f187b38e098895811085f5b5d1b29598e73ca51de3d712f5d3103ad50e22dc1f4d3ff1559d511500000000";
        _pinNotFilled(orderId, fillDeadline, output, golden);

        output.callbackData = abi.encodePacked(keccak256(hex""), keccak256(hex"01"), bytes3(0x010203));
        output.context = abi.encodePacked(
            keccak256(hex"02"), keccak256(hex"03"), keccak256(hex"04"), keccak256(hex"05"), bytes4(0x01020304)
        );

        golden =
            hex"830c1e1caad60a3265e1c3c0dff4ef3474d6c608ca5f7ec61bd7dcbc5a992ad057630691c9757d059b9b0454cadcb5884dd3faa6ba975da4d2459aa3f11d31291a25a8358f84946d89c4783cb6cc307f98e95f2d5d5d8647bdb3d4bdd087209374f187b38e098895811085f5b5d1b29598e73ca51de3d712f5d3103ad50e22dc1f4d3ff1559d51150043c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a4705fe7f977e71dba2ea1a68e21057beebb9be2ac30c6410aa38d4f3fbe41dcffd20102030084f2ee15ea639b73fa3db9b34a245bdfa015c260c598b211bf05a1ecc4b3e3b4f269c322e3248a5dfc29d73c5b0553b0185a35cd5bb6386747517ef7e53b15e287f343681465b9efe82c933c3e8748c70cb8aa06539c361de20f72eac04e766393dbb8d0f4c497851a5043c6363657698cb1387682cac2f786c731f8936109d79501020304";
        _pinNotFilled(orderId, fillDeadline, output, golden);
    }

    function test_revert_encodeNotFilledDescription_OutOfRange() external {
        bytes32 orderId = keccak256(bytes("orderId"));
        uint32 fillDeadline = uint32(uint256(keccak256(bytes("fillDeadline"))));
        MandateOutput memory output = _named(new bytes(65536), new bytes(0));

        vm.expectRevert(MandateOutputEncodingLib.CallOutOfRange.selector);
        this.hashNotFilledCd(orderId, fillDeadline, output);
        vm.expectRevert(MandateOutputEncodingLib.CallOutOfRange.selector);
        this.hashNotFilledMem(orderId, fillDeadline, output);

        output.callbackData = new bytes(0);
        output.context = new bytes(65536);
        vm.expectRevert(MandateOutputEncodingLib.ContextOutOfRange.selector);
        this.hashNotFilledCd(orderId, fillDeadline, output);
        vm.expectRevert(MandateOutputEncodingLib.ContextOutOfRange.selector);
        this.hashNotFilledMem(orderId, fillDeadline, output);
    }

    /// forge-config: default.fuzz.runs = 1024
    function test_fuzz_fill_and_notFilled_domains_never_collide(
        bytes32 solver,
        bytes32 orderId,
        uint32 timestamp,
        uint32 fillDeadline,
        MandateOutput memory output
    ) external view {
        vm.assume(output.callbackData.length <= 1024 && output.context.length <= 1024);

        bytes memory fill = RefEncodingLib.encodeFillDescription(solver, orderId, timestamp, output);
        bytes memory notFilled = RefEncodingLib.encodeNotFilledDescription(orderId, fillDeadline, output);

        // Each domain leads with its own magic, so the encodings (and thus their hashes, short of a keccak
        // collision) can never be cross-consumed.
        assertEq(bytes4(fill), MandateOutputEncodingLib.FILL_MAGIC);
        assertEq(bytes4(notFilled), MandateOutputEncodingLib.NOT_FILLED_MAGIC);
        assertTrue(keccak256(fill) != keccak256(notFilled));

        assertEq(fill.length, 172 + output.callbackData.length + output.context.length);
        assertEq(notFilled.length, 140 + output.callbackData.length + output.context.length);
    }

    /// forge-config: default.fuzz.runs = 1024
    function test_fuzz_description_loaders_roundtrip(
        bytes32 solver,
        bytes32 orderId,
        uint32 timestamp,
        uint32 fillDeadline,
        MandateOutput memory output
    ) external view {
        vm.assume(output.callbackData.length <= 1024 && output.context.length <= 1024);

        bytes memory fill = RefEncodingLib.encodeFillDescription(solver, orderId, timestamp, output);
        (bytes32 loadedSolver, bytes32 loadedOrderId, uint32 loadedTimestamp) = this.loadHarness(fill);
        assertEq(loadedSolver, solver);
        assertEq(loadedOrderId, orderId);
        assertEq(loadedTimestamp, timestamp);

        bytes memory notFilled = RefEncodingLib.encodeNotFilledDescription(orderId, fillDeadline, output);
        (bytes32 loadedNotFilledOrderId, uint32 loadedFillDeadline) = this.loadNotFilledHarness(notFilled);
        assertEq(loadedNotFilledOrderId, orderId);
        assertEq(loadedFillDeadline, fillDeadline);
    }

    // --- pinning helpers (both directions) ---

    function _pinMo(MandateOutput memory output, bytes memory golden) private view {
        assertEq(RefEncodingLib.encodeMandateOutput(output), golden, "ref bytes != golden");
        assertEq(this.hashMoCd(output), keccak256(golden), "prod calldata hash != keccak(golden)");
        assertEq(this.hashMoMem(output), keccak256(golden), "prod memory hash != keccak(golden)");
    }

    function _pinFill(bytes32 solver, bytes32 orderId, uint32 timestamp, MandateOutput memory output, bytes memory golden)
        private
        view
    {
        assertEq(RefEncodingLib.encodeFillDescription(solver, orderId, timestamp, output), golden, "ref bytes != golden");
        assertEq(this.hashFillCd(solver, orderId, timestamp, output), keccak256(golden), "prod calldata hash");
        assertEq(this.hashFillMem(solver, orderId, timestamp, output), keccak256(golden), "prod memory hash");
    }

    function _pinNotFilled(bytes32 orderId, uint32 fillDeadline, MandateOutput memory output, bytes memory golden)
        private
        view
    {
        assertEq(
            RefEncodingLib.encodeNotFilledDescription(orderId, fillDeadline, output), golden, "ref bytes != golden"
        );
        assertEq(this.hashNotFilledCd(orderId, fillDeadline, output), keccak256(golden), "prod calldata hash");
        assertEq(this.hashNotFilledMem(orderId, fillDeadline, output), keccak256(golden), "prod memory hash");
    }

    function _named(bytes memory callbackData, bytes memory context) private pure returns (MandateOutput memory) {
        return MandateOutput({
            oracle: keccak256(bytes("outputOracle")),
            settler: keccak256(bytes("outputSettler")),
            chainId: uint256(keccak256(bytes("chainId"))),
            token: keccak256(bytes("token")),
            amount: uint256(keccak256(bytes("amount"))),
            recipient: keccak256(bytes("recipient")),
            callbackData: callbackData,
            context: context
        });
    }
}
