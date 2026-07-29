// SPDX-License-Identifier: Apache-2.0
/*
 * Copyright 2024, Polymer Labs
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

pragma solidity ^0.8.15;

import { Base64 } from "openzeppelin/utils/Base64.sol";

import { CrossL2ProverV2 } from "src/integrations/oracles/polymer/external/core/prove_api/CrossL2ProverV2.sol";

contract MockCrossL2ProverV2 is CrossL2ProverV2 {
    // Event for proof generation
    event ProofGenerated(bytes proof);

    // --- Mock-specific errors --- //
    error NoTopics();
    error InvalidValidatorContract();
    error ValidationCallFailed();
    error EventEndExceedsProofLength();
    error TopicsLengthMismatch();
    error NoLogMessages();
    error TooManyLogMessages();
    error LogMessageEndExceedsProofLength();
    error LogMessageEndExceedsUint16();

    // --- Shared proof layout offsets (used by both the validators and the mock proof builders) --- //
    /// @dev Source chain id occupies proof[CHAIN_ID_OFFSET:CHAIN_ID_OFFSET + 4].
    uint256 internal constant CHAIN_ID_OFFSET = 97;
    /// @dev Number of Solana log messages is a single byte at proof[SOL_NUM_LOGS_OFFSET].
    uint256 internal constant SOL_NUM_LOGS_OFFSET = 117;
    /// @dev Solana program id occupies proof[SOL_PROGRAM_ID_OFFSET:SOL_PROGRAM_ID_OFFSET + 32].
    uint256 internal constant SOL_PROGRAM_ID_OFFSET = 182;
    /// @dev First Solana log entry begins at proof[SOL_LOG_DATA_OFFSET] (right after the fixed header).
    uint256 internal constant SOL_LOG_DATA_OFFSET = 214;

    constructor(
        string memory clientType_,
        address sequencer_,
        bytes32 chainId_
    ) CrossL2ProverV2(clientType_, sequencer_, chainId_) { }

    /**
     * @dev Generates a mock proof and emits it for local testing.
     * @param chainId_ Source chain ID.
     * @param emitter Address of the emitting contract.
     * @param topics Array of topic hashes (32 bytes each).
     * @param data Unindexed event data.
     * @return Mock proof bytes.
     */
    function generateAndEmitProof(
        uint32 chainId_,
        address emitter,
        bytes32[] memory topics,
        bytes memory data
    ) external returns (bytes memory) {
        if (topics.length == 0) revert NoTopics();

        bytes memory proof = generateMockProof(chainId_, uint8(topics.length), emitter, topics, data);

        emit ProofGenerated(proof);
        return proof;
    }

    /**
     * @dev Generates a mock proof and sends it to a validator contract.
     * @param chainId_ Source chain ID.
     * @param emitter Address of the emitting contract.
     * @param topics Array of topic hashes (32 bytes each).
     * @param data Unindexed event data.
     * @param validatorContract Address of the contract to validate the proof.
     * @return Mock proof bytes.
     */
    function generateAndSendProof(
        uint32 chainId_,
        address emitter,
        bytes32[] memory topics,
        bytes memory data,
        address validatorContract
    ) external returns (bytes memory) {
        if (topics.length == 0) revert NoTopics();
        if (validatorContract == address(0)) revert InvalidValidatorContract();

        bytes memory proof = generateMockProof(chainId_, uint8(topics.length), emitter, topics, data);

        // Call the validator contract's validateEvent function
        (bool success,) = validatorContract.call(abi.encodeWithSignature("validateEvent(bytes)", proof));
        if (!success) revert ValidationCallFailed();

        return proof;
    }

    /**
     * @dev Modified validateEvent for testing. Skips signature and membership verification
     * to focus on proof structure and event parsing.
     */
    function validateEvent(
        bytes calldata proof
    )
        external
        view
        override
        returns (uint32 chainId, address emittingContract, bytes memory topics, bytes memory unindexedData)
    {
        // Extract chainId from proof[CHAIN_ID_OFFSET:CHAIN_ID_OFFSET + 4]
        chainId = uint32(bytes4(proof[CHAIN_ID_OFFSET:CHAIN_ID_OFFSET + 4]));

        // Skip sequencer signature verification (normally done with _verifySequencerSignature)
        // In production, this ensures the proof is signed by the sequencer, but for testing,
        // we assume a valid signature.

        // Calculate event end from proof[121:123]
        uint256 eventEnd = uint256(uint16(bytes2(proof[121:123])));
        if (eventEnd > proof.length) revert EventEndExceedsProofLength();
        bytes memory rawEvent = proof[123:eventEnd];

        // Skip IAVL proof verification (normally done with verifyMembership)
        // In production, this checks the event's inclusion in the state root, but for testing,
        // we assume membership is valid.

        // Parse the event data
        (emittingContract, topics, unindexedData) = this.parseEvent(rawEvent, uint8(proof[120]));
    }

    /**
     * @dev Modified validateSolLogs for testing. Skips signature and membership verification
     * to focus on proof structure and log message parsing.
     */
    function validateSolLogs(
        bytes calldata proof
    ) external pure override returns (uint32 chainId, bytes32 programID, string[] memory logMessages) {
        // Extract chainId from proof[CHAIN_ID_OFFSET:CHAIN_ID_OFFSET + 4]
        chainId = uint32(bytes4(proof[CHAIN_ID_OFFSET:CHAIN_ID_OFFSET + 4]));

        // Skip sequencer signature verification (normally done with _verifySequencerSignature)
        // In production, this ensures the proof is signed by the sequencer, but for testing,
        // we assume a valid signature.

        // Extract programID from proof[SOL_PROGRAM_ID_OFFSET:SOL_PROGRAM_ID_OFFSET + 32]
        programID = bytes32(proof[SOL_PROGRAM_ID_OFFSET:SOL_PROGRAM_ID_OFFSET + 32]);

        // Extract number of log messages from proof[SOL_NUM_LOGS_OFFSET]
        uint8 numLogMessages = uint8(proof[SOL_NUM_LOGS_OFFSET]);
        logMessages = new string[](numLogMessages);

        // Parse log messages
        //
        // Layout in `proof` starting at byte 214 (after header, signature, chainId, heights, txSignature, programID):
        //   For each log i:
        //     - 2 bytes: big-endian end offset of this log within the proof buffer (absolute index, not length)
        //     - N bytes: UTF-8 bytes of the log string itself
        //
        // So the first log looks like:
        //   [ log0_end (2 bytes) ][ log0_bytes ... up to log0_end-1 ]
        // The second log immediately follows, starting at log0_end, with its own 2-byte end offset, etc.
        uint256 currLogMessageStart = SOL_LOG_DATA_OFFSET;
        uint256 currentLogMessageEnd = SOL_LOG_DATA_OFFSET; // Initialised for the 0-log edge case

        for (uint256 i = 0; i < logMessages.length; ++i) {
            // Read the absolute end offset of this log's bytes
            currentLogMessageEnd = uint16(bytes2(proof[currLogMessageStart:currLogMessageStart + 2]));
            if (currentLogMessageEnd > proof.length) revert LogMessageEndExceedsProofLength();

            // Slice out the log string bytes (skip the 2-byte end offset)
            logMessages[i] = string(proof[currLogMessageStart + 2:currentLogMessageEnd]);

            // Next log starts where this one ends
            currLogMessageStart = currentLogMessageEnd;
        }

        // Skip IAVL proof verification (normally done with verifyMembership)
        // In production, this checks the log's inclusion in the state root, but for testing,
        // we assume membership is valid.
    }

    /**
     * @dev Helper function to generate a mock proof for testing.
     * @param chainId_ Source chain ID.
     * @param numTopics Number of topics in the event.
     * @param emitter Address of the emitting contract.
     * @param topics_ Array of topic hashes (32 bytes each).
     * @param unindexedData_ Unindexed event data.
     * @return Mock proof bytes.
     */
    function generateMockProof(
        uint32 chainId_,
        uint8 numTopics,
        address emitter,
        bytes32[] memory topics_,
        bytes memory unindexedData_
    ) public pure returns (bytes memory) {
        if (topics_.length != numTopics) revert TopicsLengthMismatch();

        // Calculate lengths
        uint256 topicsLength = numTopics * 32;
        uint256 eventLength = 20 + topicsLength + unindexedData_.length; // emitter + topics + data
        uint256 eventEnd = 123 + eventLength; // Offset after fixed fields

        // Assemble proof
        bytes memory proof = new bytes(eventEnd + 32); // Add 32 bytes for dummy iavlProof

        // Leave fixed fields with dummy or specified values
        // - stateRoot (32 bytes): dummy
        // - signature (65 bytes): dummy
        // Values are 0 so we don't have to set them here

        // populate given chainId (4 bytes)
        bytes4 chainIdBytes = bytes4(chainId_);
        for (uint256 i = 0; i < 4; i++) {
            proof[CHAIN_ID_OFFSET + i] = chainIdBytes[i];
        }
        // peptideHeight (proof[101:109]) dummy value of 100
        proof[108] = bytes1(uint8(100));

        // blockHeight (proof[109:117]) dummy value of 200
        proof[116] = bytes1(uint8(200));

        // - receiptIndex proof[117-118] dummy avlue of 1
        proof[118] = bytes1(uint8(1));
        // eventIndex proof[119]: dummy  value of 0
        proof[119] = bytes1(0);
        // numTopics proof[120]  dummy value of num topics
        proof[120] = bytes1(numTopics);

        // eventDataEnd (2 bytes)
        bytes2 eventEndBytes = bytes2(uint16(eventEnd));
        proof[121] = eventEndBytes[0];
        proof[122] = eventEndBytes[1];

        // Event data: emitter (20 bytes) + topics + unindexedData
        bytes20 emitterBytes = bytes20(emitter);
        for (uint256 i = 0; i < 20; i++) {
            proof[123 + i] = emitterBytes[i];
        }
        for (uint256 i = 0; i < numTopics; i++) {
            bytes32 topic = topics_[i];
            for (uint256 j = 0; j < 32; j++) {
                proof[143 + i * 32 + j] = topic[j];
            }
        }
        for (uint256 i = 0; i < unindexedData_.length; i++) {
            proof[143 + topicsLength + i] = unindexedData_[i];
        }

        // iavlProof (dummy, 32 bytes)
        for (uint256 i = eventEnd; i < proof.length; i++) {
            proof[i] = bytes1(0);
        }

        return proof;
    }

    /**
     * @dev Formats a Solana log line in the shape `validateSolLogs` actually returns: just the base64 blob.
     *
     *      Polymer strips both the runtime `"Program log: "` prefix and the emitter's `"Prove: program: <id>, "`
     *      template off-chain, so the returned log carries no program id in its text. The authenticated program id is
     *      delivered out-of-band via the `programID` return value of `validateSolLogs` (see {generateMockSolProof}).
     *      This mirrors real Polymer output verified against the live prover; keeping the mock faithful is why the
     *      program id is NOT part of the log string.
     * @param blob Raw bytes to be base64-encoded as the log payload.
     * @return The formatted log string.
     */
    function formatSolLogMessage(
        bytes memory blob
    ) public pure returns (string memory) {
        return Base64.encode(blob);
    }

    /**
     * @dev Generates a mock Solana proof and emits it for local testing.
     * @param chainId_ Source chain ID (should be 2 for Solana).
     * @param programID Solana program ID that emitted the logs.
     * @param logMessages Array of log message strings.
     * @return Mock proof bytes.
     */
    function generateAndEmitSolProof(
        uint32 chainId_,
        bytes32 programID,
        string[] memory logMessages
    ) external returns (bytes memory) {
        if (logMessages.length == 0) revert NoLogMessages();

        bytes memory proof = generateMockSolProof(chainId_, programID, logMessages);

        emit ProofGenerated(proof);
        return proof;
    }

    /**
     * @dev Helper function to generate a mock Solana proof for testing.
     * @param chainId_ Source chain ID (should be 2 for Solana).
     * @param programID Solana program ID that emitted the logs.
     * @param logMessages_ Array of log message strings.
     * @return Mock proof bytes.
     */
    function generateMockSolProof(
        uint32 chainId_,
        bytes32 programID,
        string[] memory logMessages_
    ) public pure returns (bytes memory) {
        if (logMessages_.length == 0) revert NoLogMessages();
        if (logMessages_.length > 255) revert TooManyLogMessages();

        // Calculate total length of all log messages
        uint256 totalLogLength = 0;
        for (uint256 i = 0; i < logMessages_.length; i++) {
            totalLogLength += bytes(logMessages_[i]).length + 2; // +2 for the 2-byte length prefix
        }

        // Calculate proof length:
        // - Fixed header: SOL_LOG_DATA_OFFSET bytes (state root + signature + chainId + heights + numLogs + txSig +
        //   programID)
        // - Log messages: totalLogLength bytes
        // - IAVL proof: 32 bytes (dummy)
        uint256 proofLength = SOL_LOG_DATA_OFFSET + totalLogLength + 32;

        bytes memory proof = new bytes(proofLength);

        // Leave fixed fields with dummy values (already 0)
        // - stateRoot (32 bytes): dummy
        // - signature (65 bytes): dummy

        // Populate chainId (4 bytes) at proof[CHAIN_ID_OFFSET:CHAIN_ID_OFFSET + 4]
        bytes4 chainIdBytes = bytes4(chainId_);
        for (uint256 i = 0; i < 4; i++) {
            proof[CHAIN_ID_OFFSET + i] = chainIdBytes[i];
        }

        // peptideHeight (proof[101:109]) - dummy value of 100
        proof[108] = bytes1(uint8(100));

        // blockHeight (proof[109:117]) - dummy value of 200
        proof[116] = bytes1(uint8(200));

        // number of log messages (proof[SOL_NUM_LOGS_OFFSET])
        proof[SOL_NUM_LOGS_OFFSET] = bytes1(uint8(logMessages_.length));

        // txSignature high (proof[118:150]) - dummy value
        // txSignature low (proof[150:182]) - dummy value
        // (already 0)

        // programID (proof[SOL_PROGRAM_ID_OFFSET:SOL_PROGRAM_ID_OFFSET + 32])
        for (uint256 i = 0; i < 32; i++) {
            proof[SOL_PROGRAM_ID_OFFSET + i] = programID[i];
        }

        // Encode log messages starting at proof[SOL_LOG_DATA_OFFSET]
        uint256 offset = SOL_LOG_DATA_OFFSET;
        for (uint256 i = 0; i < logMessages_.length; i++) {
            bytes memory logBytes = bytes(logMessages_[i]);
            uint256 logEnd = offset + 2 + logBytes.length;
            if (logEnd > type(uint16).max) revert LogMessageEndExceedsUint16();

            // Write 2-byte length prefix (big endian)
            bytes2 logEndBytes = bytes2(uint16(logEnd));
            proof[offset] = logEndBytes[0];
            proof[offset + 1] = logEndBytes[1];

            // Write log message content
            for (uint256 j = 0; j < logBytes.length; j++) {
                proof[offset + 2 + j] = logBytes[j];
            }

            offset = logEnd;
        }

        // IAVL proof (dummy, 32 bytes)
        for (uint256 i = offset; i < proof.length; i++) {
            proof[i] = bytes1(0);
        }

        return proof;
    }
}
