// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";

import { MandateOutput } from "../../src/input/types/MandateOutputType.sol";
import { LibAddress } from "../../src/libs/LibAddress.sol";
import { MandateOutputEncodingLib } from "../../src/libs/MandateOutputEncodingLib.sol";
import { OutputVerificationLib } from "../../src/libs/OutputVerificationLib.sol";
import { OutputSettlerBase } from "../../src/output/OutputSettlerBase.sol";
import { FillerDataLib } from "../../src/output/simple/FillerDataLib.sol";

import { MockERC20 } from "../mocks/MockERC20.sol";

contract OutputSettlerMock is OutputSettlerBase {
    using FillerDataLib for bytes;

    function _resolveOutput(
        MandateOutput calldata output,
        bytes calldata fillerData
    ) internal pure override returns (bytes32 solver, uint256 amount) {
        amount = output.amount;
        solver = fillerData.solver();
    }
}

contract OutputSettlerBaseNotFilledTest is Test {
    using LibAddress for address;

    OutputSettlerMock outputSettler;
    MockERC20 outputToken;

    address oracle;
    address swapper;
    address sender;
    bytes32 filler;

    function setUp() public {
        outputSettler = new OutputSettlerMock();
        outputToken = new MockERC20("TEST", "TEST", 18);

        oracle = makeAddr("oracle");
        swapper = makeAddr("swapper");
        sender = makeAddr("sender");
        filler = keccak256(bytes("filler"));

        // Move away from timestamp 0 so pre-deadline scenarios exist.
        vm.warp(1_000_000);
    }

    function _output() internal view returns (MandateOutput memory) {
        return MandateOutput({
            oracle: oracle.toIdentifier(),
            settler: address(outputSettler).toIdentifier(),
            chainId: block.chainid,
            token: address(outputToken).toIdentifier(),
            amount: 10 ** 18,
            recipient: swapper.toIdentifier(),
            callbackData: bytes(""),
            context: bytes("")
        });
    }

    function _fill(bytes32 orderId, MandateOutput memory output, uint48 fillDeadline) internal {
        outputToken.mint(sender, output.amount);
        vm.prank(sender);
        outputToken.approve(address(outputSettler), output.amount);
        vm.prank(sender);
        outputSettler.fill(orderId, output, fillDeadline, abi.encodePacked(filler));
    }

    function _notFilledPayload(
        bytes32 orderId,
        uint32 fillDeadline,
        MandateOutput memory output
    ) internal pure returns (bytes memory) {
        return MandateOutputEncodingLib.encodeNotFilledDescriptionMemory(orderId, fillDeadline, output);
    }

    function _hasAttested(
        bytes memory payload
    ) internal returns (bool) {
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = payload;
        vm.prank(oracle); // hasAttested reconstructs the output hash with msg.sender as oracle
        return outputSettler.hasAttested(payloads);
    }

    // --- emitNotFilled guards --- //

    function test_emitNotFilled_emits_after_deadline() public {
        bytes32 orderId = keccak256(bytes("orderId"));
        MandateOutput memory output = _output();
        uint32 fillDeadline = uint32(block.timestamp);

        vm.warp(uint256(fillDeadline) + 1);

        vm.expectEmit();
        emit OutputSettlerBase.OutputNotFilled(orderId, output, fillDeadline);
        outputSettler.emitNotFilled(orderId, output, fillDeadline);
        vm.snapshotGasLastCall("outputSettler", "emitNotFilled");

        // Emitting is idempotent: duplicates are harmless.
        outputSettler.emitNotFilled(orderId, output, fillDeadline);
    }

    function test_revert_emitNotFilled_before_deadline() public {
        bytes32 orderId = keccak256(bytes("orderId"));
        MandateOutput memory output = _output();
        uint32 fillDeadline = uint32(block.timestamp + 1000);

        // Boundary: exactly the fill deadline is still too early (strict inequality).
        vm.warp(fillDeadline);
        vm.expectRevert(OutputSettlerBase.FillDeadlineNotPassed.selector);
        outputSettler.emitNotFilled(orderId, output, fillDeadline);
    }

    function test_revert_emitNotFilled_wrong_chain() public {
        MandateOutput memory output = _output();
        output.chainId = block.chainid + 1;

        vm.expectRevert(
            abi.encodeWithSelector(OutputVerificationLib.WrongChain.selector, block.chainid + 1, block.chainid)
        );
        outputSettler.emitNotFilled(keccak256(bytes("orderId")), output, 0);
    }

    function test_revert_emitNotFilled_wrong_settler() public {
        MandateOutput memory output = _output();
        output.settler = makeAddr("otherSettler").toIdentifier();

        vm.expectRevert(
            abi.encodeWithSelector(
                OutputVerificationLib.WrongOutputSettler.selector,
                address(outputSettler).toIdentifier(),
                output.settler
            )
        );
        outputSettler.emitNotFilled(keccak256(bytes("orderId")), output, 0);
    }

    function test_revert_emitNotFilled_dirty_oracle() public {
        MandateOutput memory output = _output();
        output.oracle = bytes32(uint256(1) << 160 | uint256(uint160(oracle)));

        vm.expectRevert(LibAddress.HasDirtyBits.selector);
        outputSettler.emitNotFilled(keccak256(bytes("orderId")), output, 0);
    }

    function test_revert_emitNotFilled_on_filled_output() public {
        bytes32 orderId = keccak256(bytes("orderId"));
        MandateOutput memory output = _output();
        uint32 fillDeadline = uint32(block.timestamp + 1000);

        _fill(orderId, output, fillDeadline);

        vm.warp(uint256(fillDeadline) + 1);
        vm.expectRevert(OutputSettlerBase.AlreadyFilled.selector);
        outputSettler.emitNotFilled(orderId, output, fillDeadline);
    }

    /// @dev The fill-DoS guard: emitNotFilled never writes state, so a prior (even fabricated-deadline) emit leaves
    /// fill() completely unaffected.
    function test_emitNotFilled_does_not_block_fill() public {
        bytes32 orderId = keccak256(bytes("orderId"));
        MandateOutput memory output = _output();
        uint32 realFillDeadline = uint32(block.timestamp + 1000);

        // Attacker emits with a fabricated past deadline the moment the order opens.
        outputSettler.emitNotFilled(orderId, output, 1);

        // The legitimate solver's fill succeeds regardless.
        _fill(orderId, output, realFillDeadline);
        assertEq(outputToken.balanceOf(swapper), output.amount);
        assertTrue(outputSettler.getFillRecord(orderId, output) != bytes32(0));
    }

    // --- hasAttested: non-fill branch (live validation) --- //

    function test_hasAttested_notFilled_only_after_deadline() public {
        bytes32 orderId = keccak256(bytes("orderId"));
        MandateOutput memory output = _output();
        uint32 fillDeadline = uint32(block.timestamp + 1000);
        bytes memory payload = _notFilledPayload(orderId, fillDeadline, output);

        // Before the deadline: not attestable.
        assertFalse(_hasAttested(payload));

        // Exactly at the deadline: still not attestable (strict inequality).
        vm.warp(fillDeadline);
        assertFalse(_hasAttested(payload));

        // One second past: attestable.
        vm.warp(uint256(fillDeadline) + 1);
        assertTrue(_hasAttested(payload));
    }

    function test_hasAttested_notFilled_false_for_filled_output() public {
        bytes32 orderId = keccak256(bytes("orderId"));
        MandateOutput memory output = _output();
        uint32 fillDeadline = uint32(block.timestamp + 1000);

        _fill(orderId, output, fillDeadline);

        vm.warp(uint256(fillDeadline) + 1);
        assertFalse(_hasAttested(_notFilledPayload(orderId, fillDeadline, output)));
    }

    /// @dev The output hash binds msg.sender as the oracle: a non-fill probed through a different caller than
    /// output.oracle describes a different output, whose (vacuous) non-fill is also attestable. The oracle binding
    /// happens through the attestation key on the input side, exactly as for fills.
    function test_hasAttested_notFilled_validates_for_calling_oracle() public {
        bytes32 orderId = keccak256(bytes("orderId"));
        MandateOutput memory output = _output();
        uint32 fillDeadline = uint32(block.timestamp + 1000);

        _fill(orderId, output, fillDeadline);
        vm.warp(uint256(fillDeadline) + 1);

        bytes memory payload = _notFilledPayload(orderId, fillDeadline, output);

        // Called by the real oracle the payload reconstructs the filled output: false.
        assertFalse(_hasAttested(payload));

        // Called by another oracle it reconstructs an unfilled output variant: true, but the resulting attestation
        // lands under that oracle's key and can never validate against the signed order's output.oracle.
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = payload;
        vm.prank(makeAddr("otherOracle"));
        assertTrue(outputSettler.hasAttested(payloads));
    }

    // --- hasAttested: dispatch --- //

    function test_revert_hasAttested_unknown_magic() public {
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodePacked(bytes4(0xdeadbeef), new bytes(200));

        vm.expectRevert(
            abi.encodeWithSelector(OutputSettlerBase.InvalidPayloadMagic.selector, bytes4(0xdeadbeef))
        );
        vm.prank(oracle);
        outputSettler.hasAttested(payloads);
    }

    /// forge-config: default.fuzz.runs = 1024
    function test_fuzz_hasAttested_unknown_magic_reverts(
        bytes4 magic,
        bytes memory tail
    ) public {
        vm.assume(
            magic != MandateOutputEncodingLib.FILL_MAGIC && magic != MandateOutputEncodingLib.NOT_FILLED_MAGIC
        );

        bytes[] memory payloads = new bytes[](1);
        payloads[0] = abi.encodePacked(magic, tail);

        vm.expectRevert(abi.encodeWithSelector(OutputSettlerBase.InvalidPayloadMagic.selector, magic));
        vm.prank(oracle);
        outputSettler.hasAttested(payloads);
    }

    function test_revert_hasAttested_payload_too_small() public {
        bytes[] memory payloads = new bytes[](1);

        // Shorter than the magic itself.
        payloads[0] = hex"d4f8ba";
        vm.expectRevert(OutputSettlerBase.PayloadTooSmall.selector);
        vm.prank(oracle);
        outputSettler.hasAttested(payloads);

        // Tagged fill below its 172-byte minimum.
        payloads[0] = abi.encodePacked(MandateOutputEncodingLib.FILL_MAGIC, new bytes(167));
        vm.expectRevert(OutputSettlerBase.PayloadTooSmall.selector);
        vm.prank(oracle);
        outputSettler.hasAttested(payloads);

        // Tagged non-fill below its 140-byte minimum.
        payloads[0] = abi.encodePacked(MandateOutputEncodingLib.NOT_FILLED_MAGIC, new bytes(135));
        vm.expectRevert(OutputSettlerBase.PayloadTooSmall.selector);
        vm.prank(oracle);
        outputSettler.hasAttested(payloads);
    }

    /// @dev Cross-domain: a fill payload for a filled output validates; rewriting its magic to the non-fill domain
    /// must not (and vice versa the non-fill of an unfilled output validates only in its own domain).
    function test_hasAttested_domains_do_not_cross_validate() public {
        bytes32 orderId = keccak256(bytes("orderId"));
        MandateOutput memory output = _output();
        uint32 fillDeadline = uint32(block.timestamp + 1000);

        _fill(orderId, output, fillDeadline);
        uint32 fillTimestamp = uint32(block.timestamp);

        bytes memory fillPayload = MandateOutputEncodingLib.encodeFillDescriptionMemory(
            filler, orderId, fillTimestamp, output
        );
        assertTrue(_hasAttested(fillPayload));

        // A fill payload with the non-fill magic spliced in front of the fill headers parses as a (nonsense)
        // non-fill for a different output identity — it must not validate as anything.
        bytes memory spliced = fillPayload;
        bytes4 notFilledMagic = MandateOutputEncodingLib.NOT_FILLED_MAGIC;
        spliced[0] = notFilledMagic[0];
        spliced[1] = notFilledMagic[1];
        spliced[2] = notFilledMagic[2];
        spliced[3] = notFilledMagic[3];
        assertFalse(_hasAttested(spliced));
    }

}
