// SPDX-License-Identifier: MIT

pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";

import { Base64 } from "openzeppelin/utils/Base64.sol";
import { MandateOutput } from "src/input/types/MandateOutputType.sol";
import { PolymerOracle } from "src/integrations/oracles/polymer/PolymerOracle.sol";
import { MockCrossL2ProverV2 } from "src/integrations/oracles/polymer/external/mocks/MockCrossL2ProverV2.sol";
import { LibAddress } from "src/libs/LibAddress.sol";

import { MockERC20 } from "../../mocks/MockERC20.sol";
import { InputSettlerBase } from "src/input/InputSettlerBase.sol";
import { InputSettlerEscrow } from "src/input/escrow/InputSettlerEscrow.sol";
import { StandardOrder } from "src/input/types/StandardOrderType.sol";
import { IInputSettlerEscrow } from "src/interfaces/IInputSettlerEscrow.sol";
import { MandateOutputEncodingLib } from "src/libs/MandateOutputEncodingLib.sol";
import { OutputSettlerBase } from "src/output/OutputSettlerBase.sol";
import { OutputSettlerSimple } from "src/output/simple/OutputSettlerSimple.sol";

contract PolymerOracleTest is Test {
    using LibAddress for address;

    event OutputProven(uint256 chainid, bytes32 remoteIdentifier, bytes32 application, bytes32 payloadHash);

    MockCrossL2ProverV2 mockCrossL2ProverV2;
    PolymerOracle polymerOracle;

    string clientType = "mock-proof";
    address sequencer = vm.addr(uint256(keccak256("sequencer")));
    bytes32 peptideChainId = keccak256("peptide");

    address inputSettlerEscrow;
    MockERC20 token;
    MockERC20 anotherToken;
    address swapper;
    address solver;
    OutputSettlerSimple outputSettler;

    function setUp() public {
        mockCrossL2ProverV2 = new MockCrossL2ProverV2(clientType, sequencer, peptideChainId);
        polymerOracle = new PolymerOracle(address(mockCrossL2ProverV2));

        inputSettlerEscrow = address(new InputSettlerEscrow());
        swapper = makeAddr("swapper");
        solver = makeAddr("solver");
        outputSettler = new OutputSettlerSimple();

        token = new MockERC20("Mock ERC20", "MOCK", 18);
        anotherToken = new MockERC20("Mock2 ERC20", "MOCK2", 18);
        token.mint(swapper, 1e18);
    }

    function test_mock_proof() public {
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = keccak256("event");
        topics[1] = keccak256("data");

        bytes memory data = abi.encode("some data");

        bytes memory mockProof =
            mockCrossL2ProverV2.generateAndEmitProof(1, vm.addr(uint256(keccak256("emitter"))), topics, data);

        (uint32 chainId, address emittingContract, bytes memory emittedTopics, bytes memory unindexedData) =
            mockCrossL2ProverV2.validateEvent(mockProof);

        assertEq(chainId, 1);
        assertEq(emittingContract, vm.addr(uint256(keccak256("emitter"))));
        assertEq(emittedTopics, abi.encodePacked(topics[0], topics[1]));
        assertEq(unindexedData, abi.encode("some data"));
    }

    function test_receiveMessage_with_proof() public {
        bytes32 orderId = keccak256("orderId");
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = OutputSettlerBase.OutputFilled.selector;
        topics[1] = orderId;

        MandateOutput memory mandateOutput = MandateOutput({
            oracle: address(polymerOracle).toIdentifier(),
            settler: makeAddr("settler").toIdentifier(),
            chainId: 1,
            token: makeAddr("token").toIdentifier(),
            amount: 1000000000000000000,
            recipient: makeAddr("recipient").toIdentifier(),
            callbackData: bytes(""),
            context: bytes("")
        });

        uint32 timestamp = uint32(block.timestamp);
        bytes memory unindexedData = abi.encode(solver.toIdentifier(), timestamp, mandateOutput);

        uint32 remoteChainId = 1;

        bytes memory mockProof =
            mockCrossL2ProverV2.generateAndEmitProof(remoteChainId, makeAddr("settler"), topics, unindexedData);

        bytes32 expectedPayloadHash = keccak256(
            MandateOutputEncodingLib.encodeFillDescriptionMemory(
                solver.toIdentifier(), orderId, timestamp, mandateOutput
            )
        );

        vm.expectEmit();
        emit OutputProven(
            remoteChainId,
            address(polymerOracle).toIdentifier(),
            makeAddr("settler").toIdentifier(),
            expectedPayloadHash
        );
        polymerOracle.receiveMessage(mockProof);
    }

    function test_receiveMessage_multiple_proofs() public {
        bytes32 orderId1 = keccak256("orderId1");
        bytes32 orderId2 = keccak256("orderId2");
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = OutputSettlerBase.OutputFilled.selector;
        topics[1] = orderId1;

        MandateOutput memory mandateOutput = MandateOutput({
            oracle: address(polymerOracle).toIdentifier(),
            settler: makeAddr("settler").toIdentifier(),
            chainId: 1,
            token: makeAddr("token").toIdentifier(),
            amount: 1000000000000000000,
            recipient: makeAddr("recipient").toIdentifier(),
            callbackData: bytes(""),
            context: bytes("")
        });

        uint32 timestamp = uint32(block.timestamp);
        bytes memory unindexedData = abi.encode(solver.toIdentifier(), timestamp, mandateOutput);

        uint32 remoteChainId1 = 1;
        uint32 remoteChainId2 = 2;

        bytes memory mockProof1 =
            mockCrossL2ProverV2.generateAndEmitProof(remoteChainId1, makeAddr("settler"), topics, unindexedData);

        bytes32 expectedPayloadHash1 = keccak256(
            MandateOutputEncodingLib.encodeFillDescriptionMemory(
                solver.toIdentifier(), orderId1, timestamp, mandateOutput
            )
        );

        topics[1] = orderId2;

        bytes memory mockProof2 =
            mockCrossL2ProverV2.generateAndEmitProof(remoteChainId2, makeAddr("settler"), topics, unindexedData);

        bytes32 expectedPayloadHash2 = keccak256(
            MandateOutputEncodingLib.encodeFillDescriptionMemory(
                solver.toIdentifier(), orderId2, timestamp, mandateOutput
            )
        );

        vm.expectEmit();
        emit OutputProven(
            remoteChainId1,
            address(polymerOracle).toIdentifier(),
            makeAddr("settler").toIdentifier(),
            expectedPayloadHash1
        );
        emit OutputProven(
            remoteChainId2,
            address(polymerOracle).toIdentifier(),
            makeAddr("settler").toIdentifier(),
            expectedPayloadHash2
        );
        bytes[] memory proofs = new bytes[](2);
        proofs[0] = mockProof1;
        proofs[1] = mockProof2;
        polymerOracle.receiveMessage(proofs);
    }

    // --- OutputNotFilled --- //

    function _notFilledOutput() internal returns (MandateOutput memory) {
        return MandateOutput({
            oracle: address(polymerOracle).toIdentifier(),
            settler: makeAddr("settler").toIdentifier(),
            chainId: 1,
            token: makeAddr("token").toIdentifier(),
            amount: 1000000000000000000,
            recipient: makeAddr("recipient").toIdentifier(),
            callbackData: bytes(""),
            context: bytes("")
        });
    }

    function test_receiveMessage_notFilled_proof() public {
        bytes32 orderId = keccak256("orderId");
        uint32 fillDeadline = uint32(block.timestamp);
        MandateOutput memory output = _notFilledOutput();

        bytes32[] memory topics = new bytes32[](2);
        topics[0] = OutputSettlerBase.OutputNotFilled.selector;
        topics[1] = orderId;

        bytes memory mockProof = mockCrossL2ProverV2.generateAndEmitProof(
            uint32(output.chainId), makeAddr("settler"), topics, abi.encode(output, fillDeadline)
        );

        bytes32 expectedPayloadHash =
            keccak256(MandateOutputEncodingLib.encodeNotFilledDescriptionMemory(orderId, fillDeadline, output));

        vm.expectEmit();
        emit OutputProven(
            output.chainId,
            address(polymerOracle).toIdentifier(),
            makeAddr("settler").toIdentifier(),
            expectedPayloadHash
        );
        polymerOracle.receiveMessage(mockProof);

        assertTrue(
            polymerOracle.isProven(
                output.chainId,
                address(polymerOracle).toIdentifier(),
                makeAddr("settler").toIdentifier(),
                expectedPayloadHash
            )
        );
    }

    /// @dev The oracle in the proven event must be this PolymerOracle (same address on all chains). Otherwise
    /// `emitNotFilled`'s fill-record check may have run under a different oracle key than the attestation is stored
    /// under, letting a filled output (oracle A) be replayed as not-filled with oracle B.
    function test_revert_receiveMessage_wrong_oracle() public {
        bytes32 orderId = keccak256("orderId");
        uint32 fillDeadline = uint32(block.timestamp);
        MandateOutput memory output = _notFilledOutput();
        output.oracle = makeAddr("otherOracle").toIdentifier();

        bytes32[] memory topics = new bytes32[](2);
        topics[0] = OutputSettlerBase.OutputNotFilled.selector;
        topics[1] = orderId;

        bytes memory mockProof = mockCrossL2ProverV2.generateAndEmitProof(
            uint32(output.chainId), makeAddr("settler"), topics, abi.encode(output, fillDeadline)
        );

        vm.expectRevert(
            abi.encodeWithSignature(
                "WrongOutputOracle(bytes32,bytes32)", address(polymerOracle).toIdentifier(), output.oracle
            )
        );
        polymerOracle.receiveMessage(mockProof);

        // Same guard on the fill branch.
        topics[0] = OutputSettlerBase.OutputFilled.selector;
        bytes memory fillProof = mockCrossL2ProverV2.generateAndEmitProof(
            uint32(output.chainId),
            makeAddr("settler"),
            topics,
            abi.encode(solver.toIdentifier(), uint32(block.timestamp), output)
        );

        vm.expectRevert(
            abi.encodeWithSignature(
                "WrongOutputOracle(bytes32,bytes32)", address(polymerOracle).toIdentifier(), output.oracle
            )
        );
        polymerOracle.receiveMessage(fillProof);
    }

    /// @dev End-to-end quick refund over the Polymer rail: open → deadline passes unfilled → emitNotFilled on the
    /// output settler → prove the event → refundOnNonFill releases the escrow before order.expires. Also asserts
    /// cross-consumption fails in both directions (NotProven).
    function test_receiveMessage_notFilled_and_refundOnNonFill() public {
        uint256 amount = 1e18 / 10;

        MandateOutput[] memory outputs = new MandateOutput[](1);
        outputs[0] = MandateOutput({
            settler: address(outputSettler).toIdentifier(),
            oracle: address(polymerOracle).toIdentifier(),
            chainId: block.chainid,
            token: address(anotherToken).toIdentifier(),
            amount: amount,
            recipient: swapper.toIdentifier(),
            callbackData: hex"",
            context: hex""
        });
        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [uint256(uint160(address(token))), amount];

        uint32 fillDeadline = uint32(block.timestamp + 10 minutes);
        StandardOrder memory order = StandardOrder({
            user: swapper,
            nonce: 0,
            originChainId: block.chainid,
            expires: uint32(block.timestamp + 5 hours),
            fillDeadline: fillDeadline,
            inputOracle: address(polymerOracle),
            inputs: inputs,
            outputs: outputs
        });

        // Deposit into the escrow.
        vm.prank(swapper);
        token.approve(inputSettlerEscrow, amount);
        vm.prank(swapper);
        IInputSettlerEscrow(inputSettlerEscrow).open(order);
        assertEq(token.balanceOf(swapper), 1e18 - amount);

        bytes32 orderId = IInputSettlerEscrow(inputSettlerEscrow).orderIdentifier(order);

        // Nobody fills. The deadline passes.
        vm.warp(fillDeadline + 1);

        // Stage A: emit the attestable non-fill event on the output settler.
        vm.expectEmit();
        emit OutputSettlerBase.OutputNotFilled(orderId, outputs[0], fillDeadline);
        outputSettler.emitNotFilled(orderId, outputs[0], fillDeadline);

        // Stage B: prove the event through Polymer.
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = OutputSettlerBase.OutputNotFilled.selector;
        topics[1] = orderId;
        bytes memory mockProof = mockCrossL2ProverV2.generateAndEmitProof(
            uint32(block.chainid), address(outputSettler), topics, abi.encode(outputs[0], fillDeadline)
        );

        bytes32 payloadHash =
            keccak256(MandateOutputEncodingLib.encodeNotFilledDescriptionMemory(orderId, fillDeadline, outputs[0]));
        vm.expectEmit();
        emit OutputProven(
            block.chainid, address(polymerOracle).toIdentifier(), address(outputSettler).toIdentifier(), payloadHash
        );
        polymerOracle.receiveMessage(mockProof);

        // Cross-consumption: the proven non-fill must not be usable to finalise.
        InputSettlerBase.SolveParams[] memory solveParams = new InputSettlerBase.SolveParams[](1);
        solveParams[0] = InputSettlerBase.SolveParams({ solver: solver.toIdentifier(), timestamp: fillDeadline });
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSignature("NotProven()"));
        IInputSettlerEscrow(inputSettlerEscrow).finalise(order, solveParams, solver.toIdentifier(), hex"");

        // Stage C: the refund consumes the proof and releases the escrow, well before order.expires.
        vm.expectCall(
            address(polymerOracle),
            abi.encodeWithSignature(
                "efficientRequireProven(bytes)",
                abi.encodePacked(outputs[0].chainId, outputs[0].oracle, outputs[0].settler, payloadHash)
            )
        );
        IInputSettlerEscrow(inputSettlerEscrow).refundOnNonFill(order, 0);

        assertLt(block.timestamp, order.expires);
        assertEq(token.balanceOf(swapper), 1e18);
    }

    /// @dev Cross-consumption in the other direction: a proven FILL must not be usable by refundOnNonFill.
    function test_revert_refundOnNonFill_with_fill_proof() public {
        uint256 amount = 1e18 / 10;

        MandateOutput[] memory outputs = new MandateOutput[](1);
        outputs[0] = MandateOutput({
            settler: address(outputSettler).toIdentifier(),
            oracle: address(polymerOracle).toIdentifier(),
            chainId: block.chainid,
            token: address(anotherToken).toIdentifier(),
            amount: amount,
            recipient: swapper.toIdentifier(),
            callbackData: hex"",
            context: hex""
        });
        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [uint256(uint160(address(token))), amount];

        uint32 fillDeadline = uint32(block.timestamp + 10 minutes);
        StandardOrder memory order = StandardOrder({
            user: swapper,
            nonce: 0,
            originChainId: block.chainid,
            expires: uint32(block.timestamp + 5 hours),
            fillDeadline: fillDeadline,
            inputOracle: address(polymerOracle),
            inputs: inputs,
            outputs: outputs
        });

        vm.prank(swapper);
        token.approve(inputSettlerEscrow, amount);
        vm.prank(swapper);
        IInputSettlerEscrow(inputSettlerEscrow).open(order);

        bytes32 orderId = IInputSettlerEscrow(inputSettlerEscrow).orderIdentifier(order);

        // The output was filled before the deadline and the fill proven through Polymer.
        uint32 fillTimestamp = uint32(block.timestamp);
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = OutputSettlerBase.OutputFilled.selector;
        topics[1] = orderId;
        bytes memory mockProof = mockCrossL2ProverV2.generateAndEmitProof(
            uint32(block.chainid),
            address(outputSettler),
            topics,
            abi.encode(solver.toIdentifier(), fillTimestamp, outputs[0])
        );
        polymerOracle.receiveMessage(mockProof);

        // The fill proof cannot be consumed as a non-fill.
        vm.warp(fillDeadline + 1);
        vm.expectRevert(abi.encodeWithSignature("NotProven()"));
        IInputSettlerEscrow(inputSettlerEscrow).refundOnNonFill(order, 0);
    }

    function test_receiveMessage_wrong_event_signature() public {
        bytes32 orderId = keccak256("orderId");
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = keccak256("event");
        topics[1] = orderId;

        bytes memory mockProof = mockCrossL2ProverV2.generateAndEmitProof(
            1, vm.addr(uint256(keccak256("emitter"))), topics, abi.encode("some data")
        );

        vm.expectRevert(PolymerOracle.WrongEventSignature.selector);
        polymerOracle.receiveMessage(mockProof);
    }

    function test_receiveMessage_and_finalise() public {
        uint256 amount = 1e18 / 10;

        MandateOutput[] memory outputs = new MandateOutput[](1);
        outputs[0] = MandateOutput({
            settler: address(outputSettler).toIdentifier(),
            oracle: address(polymerOracle).toIdentifier(),
            chainId: block.chainid,
            token: address(anotherToken).toIdentifier(),
            amount: amount,
            recipient: swapper.toIdentifier(),
            callbackData: hex"",
            context: hex""
        });
        uint256[2][] memory inputs = new uint256[2][](1);
        inputs[0] = [uint256(uint160(address(token))), amount];

        StandardOrder memory order = StandardOrder({
            user: swapper,
            nonce: 0,
            originChainId: block.chainid,
            expires: type(uint32).max,
            fillDeadline: type(uint32).max,
            inputOracle: address(polymerOracle),
            inputs: inputs,
            outputs: outputs
        });

        // Deposit into the escrow
        vm.prank(swapper);
        token.approve(inputSettlerEscrow, amount);
        vm.prank(swapper);
        IInputSettlerEscrow(inputSettlerEscrow).open(order);

        InputSettlerBase.SolveParams[] memory solveParams = new InputSettlerBase.SolveParams[](1);
        solveParams[0] =
            InputSettlerBase.SolveParams({ solver: solver.toIdentifier(), timestamp: uint32(block.timestamp) });

        assertEq(token.balanceOf(solver), 0);

        bytes32 orderId = IInputSettlerEscrow(inputSettlerEscrow).orderIdentifier(order);
        bytes memory payload = MandateOutputEncodingLib.encodeFillDescriptionMemory(
            solver.toIdentifier(), orderId, uint32(block.timestamp), outputs[0]
        );
        bytes32 payloadHash = keccak256(payload);

        bytes32[] memory topics = new bytes32[](2);
        topics[0] = OutputSettlerBase.OutputFilled.selector;
        topics[1] = orderId;

        uint32 timestamp = uint32(block.timestamp);
        bytes memory unindexedData = abi.encode(solver.toIdentifier(), timestamp, outputs[0]);

        bytes memory mockProof = mockCrossL2ProverV2.generateAndEmitProof(
            uint32(block.chainid), address(outputSettler), topics, unindexedData
        );

        vm.expectEmit();
        emit OutputProven(
            block.chainid, address(polymerOracle).toIdentifier(), address(outputSettler).toIdentifier(), payloadHash
        );
        polymerOracle.receiveMessage(mockProof);

        vm.expectCall(
            address(polymerOracle),
            abi.encodeWithSignature(
                "efficientRequireProven(bytes)",
                abi.encodePacked(
                    order.outputs[0].chainId, order.outputs[0].oracle, order.outputs[0].settler, payloadHash
                )
            )
        );

        vm.prank(solver);
        IInputSettlerEscrow(inputSettlerEscrow).finalise(order, solveParams, solver.toIdentifier(), hex"");

        assertEq(token.balanceOf(solver), amount);
    }

    /// ************** Solana Processing ************** ///

    /// @dev Builds a Solana log in the real Polymer format: `"program: <base58>, <base64 blob>"`, where the decoded
    ///      blob is layout `application(32) || payload(dynamic)`.
    function _encodeSolanaLog(
        bytes32 programId,
        bytes32 application,
        bytes memory payload
    ) internal view returns (string memory) {
        return mockCrossL2ProverV2.formatSolLogMessage(programId, abi.encodePacked(application, payload));
    }

    function test_receiveSolanaMessage_with_proof() public {
        uint32 solanaChainId = 2; // base variant uses identity chain mapping.
        bytes32 programID = keccak256("solana-program");
        bytes32 application = makeAddr("settler").toIdentifier();
        bytes memory payload = bytes("test-payload");
        bytes32 payloadHash = keccak256(payload);

        string[] memory logMessages = new string[](1);
        logMessages[0] = _encodeSolanaLog(programID, application, payload);

        bytes memory mockProof = mockCrossL2ProverV2.generateAndEmitSolProof(solanaChainId, programID, logMessages);

        // Sender identity is the authenticated program id.
        vm.expectEmit();
        emit OutputProven(uint256(solanaChainId), programID, application, payloadHash);
        polymerOracle.receiveSolanaMessage(mockProof);

        assertTrue(polymerOracle.isProven(uint256(solanaChainId), programID, application, payloadHash));
    }

    /// @dev GOLDEN fixture. The log line, program id, application and payload hash below are immutable literals
    ///      computed OFFLINE from the documented wire format `"program: <base58 program id>, <base64(source(32) ||
    ///      payload)>"` — deliberately independent of the mock's `formatSolLogMessage` (which renders the program id
    ///      as hex). This pins the exact bytes the shipped oracle must accept and the attestation slot it must set for
    ///      the Polymer-authenticated program id.
    ///
    ///      Fixture (base58 program id "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"):
    ///      - programID (bytes32)   = 0x06ddf6e1d765a193d9cbe146ceeb79ac1cb485ed5f5b37913a8cf5857eff00a9
    ///      - application (bytes32) = 0x...deadbeef
    ///      - payload               = "golden-payload"
    ///      - base64(application(32) || payload) = "AAAA...N6tvu9nb2xkZW4tcGF5bG9hZA=="
    ///      - payloadHash = keccak256("golden-payload")
    function test_receiveSolanaMessage_golden_fixture() public {
        uint32 solanaChainId = 2;

        // Program id authenticated by Polymer (proof[182:214]); the base58 rendering in the log line below is
        // "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA", which base58-decodes to exactly these 32 bytes.
        bytes32 programID = 0x06ddf6e1d765a193d9cbe146ceeb79ac1cb485ed5f5b37913a8cf5857eff00a9;
        bytes32 application = 0x00000000000000000000000000000000000000000000000000000000deadbeef;
        // keccak256("golden-payload")
        bytes32 payloadHash = 0x11d41300e405124d7e79e9a507b5abe013e238cf350fbf90a46fcca903614473;

        // Hand-built log line in the exact form `validateSolLogs` returns. The trailing token is
        // base64(application(32) || "golden-payload"); everything before ", " is the (cosmetic) program-id prefix the
        // oracle never parses.
        string[] memory logMessages = new string[](1);
        logMessages[0] =
            "program: TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA, AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAN6tvu9nb2xkZW4tcGF5bG9hZA==";

        bytes memory mockProof = mockCrossL2ProverV2.generateAndEmitSolProof(solanaChainId, programID, logMessages);

        vm.expectEmit();
        emit OutputProven(uint256(solanaChainId), programID, application, payloadHash);
        polymerOracle.receiveSolanaMessage(mockProof);

        assertTrue(polymerOracle.isProven(uint256(solanaChainId), programID, application, payloadHash));
    }

    /// @dev CRITICAL regression on the base variant: an attacker program's forged log lands under the attacker's own
    ///      program id and cannot forge an attestation for a victim's trusted oracle identity.
    function test_receiveSolanaMessage_forged_program_self_namespaces() public {
        uint32 solanaChainId = 2;
        bytes32 victimProgramID = keccak256("victim-solana-program");
        bytes32 attackerProgramID = keccak256("attacker-solana-program");
        bytes32 application = makeAddr("settler").toIdentifier();
        bytes memory payload = bytes("release-funds");
        bytes32 payloadHash = keccak256(payload);

        string[] memory logMessages = new string[](1);
        logMessages[0] = _encodeSolanaLog(victimProgramID, application, payload);

        bytes memory mockProof =
            mockCrossL2ProverV2.generateAndEmitSolProof(solanaChainId, attackerProgramID, logMessages);

        vm.expectEmit();
        emit OutputProven(uint256(solanaChainId), attackerProgramID, application, payloadHash);
        polymerOracle.receiveSolanaMessage(mockProof);

        assertFalse(polymerOracle.isProven(uint256(solanaChainId), victimProgramID, application, payloadHash));
        assertTrue(polymerOracle.isProven(uint256(solanaChainId), attackerProgramID, application, payloadHash));
    }

    function test_receiveSolanaMessage_wrong_chain_id_reverts() public {
        uint32 wrongChainId = 1; // Not Solana (should be 2)
        bytes32 programID = keccak256("solana-program");
        bytes32 application = makeAddr("settler").toIdentifier();
        bytes memory payload = bytes("test-payload");

        string[] memory logMessages = new string[](1);
        logMessages[0] = _encodeSolanaLog(programID, application, payload);

        bytes memory mockProof = mockCrossL2ProverV2.generateAndEmitSolProof(wrongChainId, programID, logMessages);

        vm.expectRevert(PolymerOracle.NotSolanaMessage.selector);
        polymerOracle.receiveSolanaMessage(mockProof);
    }

    function test_receiveSolanaMessage_malformed_log_missing_delimiter_reverts() public {
        uint32 solanaChainId = 2;
        bytes32 programID = keccak256("solana-program");
        bytes32 application = makeAddr("settler").toIdentifier();
        bytes memory payload = bytes("test-payload");

        // Raw base64 blob with no `"program: ..., "` wrapper: no `", "` delimiter.
        string[] memory logMessages = new string[](1);
        logMessages[0] = Base64.encode(abi.encodePacked(application, payload));

        bytes memory mockProof = mockCrossL2ProverV2.generateAndEmitSolProof(solanaChainId, programID, logMessages);

        vm.expectRevert(PolymerOracle.MalformedSolanaLog.selector);
        polymerOracle.receiveSolanaMessage(mockProof);
    }

    function test_receiveSolanaMessage_invalid_solana_message_reverts() public {
        uint32 solanaChainId = 2;
        bytes32 programID = keccak256("solana-program");

        // Decoded blob shorter than the required application(32) field.
        string[] memory logMessages = new string[](1);
        logMessages[0] = mockCrossL2ProverV2.formatSolLogMessage(programID, abi.encodePacked(bytes4(0xdeadbeef)));

        bytes memory mockProof = mockCrossL2ProverV2.generateAndEmitSolProof(solanaChainId, programID, logMessages);

        vm.expectRevert(PolymerOracle.InvalidSolanaMessage.selector);
        polymerOracle.receiveSolanaMessage(mockProof);
    }
}
