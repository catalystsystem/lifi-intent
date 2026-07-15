// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { LibAddress } from "../../../libs/LibAddress.sol";
import { Base64 } from "openzeppelin/utils/Base64.sol";
import { Bytes } from "openzeppelin/utils/Bytes.sol";

import { MandateOutput, MandateOutputEncodingLib } from "../../../libs/MandateOutputEncodingLib.sol";

import { OutputVerificationLib } from "../../../libs/OutputVerificationLib.sol";
import { BaseInputOracle } from "../../../oracles/BaseInputOracle.sol";
import { OutputSettlerBase } from "../../../output/OutputSettlerBase.sol";
import { ICrossL2ProverV2 } from "./external/interfaces/ICrossL2ProverV2.sol";

/**
 * @notice Polymer Oracle.
 * Polymer uses the fill event to reconstruct the payload for verification instead of sending messages cross-chain.
 */
contract PolymerOracle is BaseInputOracle {
    using LibAddress for address;

    error WrongEventSignature();
    error NotSolanaMessage();
    error InvalidSolanaMessage();
    error MalformedSolanaLog();

    uint256 constant SOLANA_POLYMER_CHAIN_ID = 2;

    // On-wire Solana blob layout offsets. Layout (a): `application(32) || payload(dynamic)`.
    // To switch to layout (b) `program_id(32) || emitter(32) || application(32) || payload`, set these to 64 and 96.
    uint256 constant SOLANA_APPLICATION_OFFSET = 0;
    uint256 constant SOLANA_PAYLOAD_OFFSET = 32;

    ICrossL2ProverV2 CROSS_L2_PROVER;

    constructor(
        address crossL2Prover
    ) {
        CROSS_L2_PROVER = ICrossL2ProverV2(crossL2Prover);
    }

    function _getChainId(
        uint256 protocolId
    ) internal view virtual returns (uint256 chainId) {
        return protocolId;
    }

    /// ************** EVM Processing ************** ///

    function _proofPayloadHash(
        bytes32 orderId,
        bytes32 solver,
        uint32 timestamp,
        MandateOutput memory mandateOutput
    ) internal pure returns (bytes32 outputHash) {
        return outputHash =
            keccak256(MandateOutputEncodingLib.encodeFillDescriptionMemory(solver, orderId, timestamp, mandateOutput));
    }

    function _processEvmMessage(
        bytes calldata proof
    ) internal {
        (uint32 chainId, address emittingContract, bytes memory topics, bytes memory unindexedData) =
            CROSS_L2_PROVER.validateEvent(proof);

        // Validate the event has 2 topics.
        if (topics.length != 64) revert WrongEventSignature();
        // While it is unlikely an event matching the data pattern we have, validate the event signature.
        bytes32 eventSignature = bytes32(Bytes.slice(topics, 0, 32));
        // OrderId is topic[1] which is byte 32 to 64.
        bytes32 orderId = bytes32(Bytes.slice(topics, 32, 64));

        // Convert the Polymer ChainID into the canonical chainId.
        uint256 remoteChainId = _getChainId(uint256(chainId));

        bytes32 payloadHash;
        if (eventSignature == OutputSettlerBase.OutputFilled.selector) {
            (bytes32 solver, uint32 timestamp, MandateOutput memory output,) =
                abi.decode(unindexedData, (bytes32, uint32, MandateOutput, uint256));
            OutputVerificationLib._isThisOutputOracle(output.oracle);

            payloadHash = _proofPayloadHash(orderId, solver, timestamp, output);
        } else if (eventSignature == OutputSettlerBase.OutputNotFilled.selector) {
            (MandateOutput memory output, uint32 fillDeadline) = abi.decode(unindexedData, (MandateOutput, uint32));
            OutputVerificationLib._isThisOutputOracle(output.oracle);

            payloadHash =
                keccak256(MandateOutputEncodingLib.encodeNotFilledDescriptionMemory(orderId, fillDeadline, output));
        } else {
            revert WrongEventSignature();
        }

        bytes32 application = emittingContract.toIdentifier();
        _attestations[remoteChainId][address(this).toIdentifier()][application][payloadHash] = true;

        emit OutputProven(remoteChainId, address(this).toIdentifier(), application, payloadHash);
    }

    /// ************** Solana Processing ************** ///

    /**
     * @dev Processes a Solana proof.
     *
     * Trust model: the only value Polymer authenticates for a Solana proof is `returnedProgramId` (the program id
     * returned by `validateSolLogs`, taken from the proven receipt). The remote-oracle/sender identity is therefore
     * taken from `returnedProgramId` and NEVER from the log content (which is attacker-controllable). This mirrors the
     * EVM path, which keys the sender identity on `address(this)` rather than on log data.
     *
     * This self-namespaces attestations: an attacker deploying their own Solana program `P` can only ever write
     * attestations under `_attestations[chain][P][...]`. Honest orders reference the real program id as
     * `output.oracle`, so a forged proof lands in a slot no honest order reads. No allowlist is required.
     *
     * Log format: `validateSolLogs` returns each log as a human-readable string of the form
     * `"program: <base58 program id>, <base64 blob>"` (the on-chain `"Prove: "` prefix is already stripped by
     * Polymer). Only the trailing base64 blob is decoded; it is extracted as the substring after the first `", "`
     * delimiter (the base58 program id contains no comma).
     *
     * On-wire blob layout (a) `application(32) || payload(dynamic)`:
     * - bytes[0:32]   = `application` (bytes32)  // application/settler identifier (source)
     * - bytes[32:]    = `payload` (bytes)        // raw payload bytes (dynamic length)
     *
     * TODO(SVM): the Solana emitter `oracle_polymer::submit` currently emits
     * `base64(program_id || oracle_polymer_pubkey || source || payload)` (4 fields). For layout (a) the SVM emit must
     * be trimmed to `base64(source || payload)`. Do not touch the SVM here; if the identity is instead a PDA, switch
     * to layout (b) by setting SOLANA_APPLICATION_OFFSET/SOLANA_PAYLOAD_OFFSET to 64/96.
     */
    function _processSolanaMessage(
        bytes calldata proof
    ) internal {
        (uint32 chainId, bytes32 returnedProgramId, string[] memory logMessages) =
            CROSS_L2_PROVER.validateSolLogs(proof);

        require(chainId == SOLANA_POLYMER_CHAIN_ID, NotSolanaMessage());

        uint256 remoteChainId = _getChainId(uint256(chainId));

        for (uint256 i = 0; i < logMessages.length; i++) {
            bytes memory logBytes = Base64.decode(_extractSolanaLogBlob(logMessages[i]));

            if (logBytes.length < SOLANA_PAYLOAD_OFFSET) revert InvalidSolanaMessage();

            bytes32 application =
                bytes32(Bytes.slice(logBytes, SOLANA_APPLICATION_OFFSET, SOLANA_APPLICATION_OFFSET + 32));
            bytes32 payloadHash = keccak256(Bytes.slice(logBytes, SOLANA_PAYLOAD_OFFSET, logBytes.length));

            // Sender identity is the Polymer-authenticated program id, never log content.
            _attestations[remoteChainId][returnedProgramId][application][payloadHash] = true;

            emit OutputProven(remoteChainId, returnedProgramId, application, payloadHash);
        }
    }

    /**
     * @dev Extracts the trailing base64 blob from a Solana log string of the form
     * `"program: <base58 program id>, <base64 blob>"`. Returns the substring after the first `", "` delimiter.
     * Reverts with {MalformedSolanaLog} if the delimiter is missing.
     */
    function _extractSolanaLogBlob(
        string memory logMessage
    ) internal pure returns (string memory) {
        bytes memory logBytes = bytes(logMessage);
        for (uint256 i = 0; i + 1 < logBytes.length; ++i) {
            // Find the first ", " (0x2c 0x20) delimiter.
            if (logBytes[i] == 0x2c && logBytes[i + 1] == 0x20) {
                uint256 start = i + 2;
                bytes memory blob = new bytes(logBytes.length - start);
                for (uint256 j = 0; j < blob.length; ++j) {
                    blob[j] = logBytes[start + j];
                }
                return string(blob);
            }
        }
        revert MalformedSolanaLog();
    }

    function receiveMessage(
        bytes calldata proof
    ) external {
        _processEvmMessage(proof);
    }

    function receiveMessage(
        bytes[] calldata proofs
    ) external {
        uint256 numProofs = proofs.length;
        for (uint256 i; i < numProofs; ++i) {
            _processEvmMessage(proofs[i]);
        }
    }

    /**
     * @notice Processes a single Solana proof and updates the attestation state.
     * @param proof The proof data from Solana to be processed.
     */
    function receiveSolanaMessage(
        bytes calldata proof
    ) external {
        _processSolanaMessage(proof);
    }

    /**
     * @notice Processes multiple Solana proofs and updates the attestation state for each.
     * @param proofs An array of proof data from Solana to be processed.
     */
    function receiveSolanaMessage(
        bytes[] calldata proofs
    ) external {
        uint256 numProofs = proofs.length;
        for (uint256 i; i < numProofs; ++i) {
            _processSolanaMessage(proofs[i]);
        }
    }
}
