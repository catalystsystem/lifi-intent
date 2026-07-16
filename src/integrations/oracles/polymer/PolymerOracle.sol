// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { LibAddress } from "../../../libs/LibAddress.sol";
import { Base64 } from "openzeppelin/utils/Base64.sol";
import { Bytes } from "openzeppelin/utils/Bytes.sol";

import { Base58 } from "./Base58.sol";

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
    error SolanaProgramIdMismatch();

    uint256 internal constant SOLANA_POLYMER_CHAIN_ID = 2;

    // On-wire Solana blob layout: `application(32) || payload(dynamic)`.
    // The application identifier is at offset 0; the payload follows at offset 32.
    uint256 internal constant SOLANA_APPLICATION_OFFSET = 0;
    uint256 internal constant SOLANA_PAYLOAD_OFFSET = 32;

    ICrossL2ProverV2 internal immutable CROSS_L2_PROVER;

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
     * ENFORCED program-id binding: each Solana log embeds the program id in its own human-readable prefix. Per
     * Polymer's Solana-proving integration guidance, the program id returned by the prover MUST match the program id
     * named in each proven log. We enforce this on-chain: every log is required to begin with exactly
     * `"program: " + base58(returnedProgramId) + ", "` (see {_extractSolanaLogBlob}), reverting with
     * {SolanaProgramIdMismatch} otherwise. This closes the gap where a mismatching (returnedProgramId, in-log id) pair
     * could be accepted while the in-log id was silently discarded. The attestation is still keyed on the
     * authenticated `returnedProgramId`, never on log content.
     *
     * Because the binding is enforced, attestations self-namespace: an attacker's Solana program can only produce logs
     * that name (and are authenticated as) the attacker's own program id, so a forged proof can only ever write under
     * `_attestations[chain][attackerProgramId][...]`. Honest orders reference the real program id as `output.oracle`,
     * so a forged proof lands in a slot no honest order reads. No allowlist is required.
     *
     * Log format: `validateSolLogs` returns each log as a human-readable string of the form
     * `"program: <base58 program id>, <base64 blob>"` (the on-chain `"Prove: "` prefix is already stripped by
     * Polymer). After the authenticated prefix is matched, the trailing base64 blob is decoded.
     *
     * On-wire blob layout `application(32) || payload(dynamic)`:
     * - bytes[0:32]   = `application` (bytes32)  // application/settler identifier (source)
     * - bytes[32:]    = `payload` (bytes)        // raw payload bytes (dynamic length; must be non-empty)
     *
     * The Solana emitter `oracle_polymer::submit` emits `base64(source || payload)`: `source` is the
     * 32-byte `application` at offset 0 and `payload` follows at offset 32.
     */
    function _processSolanaMessage(
        bytes calldata proof
    ) internal {
        (uint32 chainId, bytes32 returnedProgramId, string[] memory logMessages) =
            CROSS_L2_PROVER.validateSolLogs(proof);

        if (chainId != SOLANA_POLYMER_CHAIN_ID) revert NotSolanaMessage();

        uint256 remoteChainId = _getChainId(uint256(chainId));

        // `Base58.encode(returnedProgramId)` is invariant across all logs in this proof and expensive to compute, so
        // build the expected authenticated prefix once and reuse it for every log.
        bytes memory expectedPrefix = abi.encodePacked("program: ", Base58.encode(returnedProgramId), ", ");

        for (uint256 i = 0; i < logMessages.length; ++i) {
            // The in-log program id is bound to the Polymer-authenticated `returnedProgramId`: the log must begin with
            // exactly `"program: " + base58(returnedProgramId) + ", "`, otherwise this reverts.
            bytes memory logBytes = Base64.decode(_extractSolanaLogBlob(logMessages[i], expectedPrefix));

            // Require a NON-empty payload: length must be strictly greater than the application field (offset 32), so
            // a bare 32-byte blob (empty payload hashing to keccak256("")) is rejected.
            if (logBytes.length <= SOLANA_PAYLOAD_OFFSET) revert InvalidSolanaMessage();

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
     * `"program: <base58 program id>, <base64 blob>"`, binding the in-log program id to the Polymer-authenticated
     * `returnedProgramId`. The log MUST begin with exactly the precomputed `expectedPrefix`
     * (`"program: " + base58(returnedProgramId) + ", "`); the returned blob is the remainder after that prefix. The
     * caller precomputes `expectedPrefix` once per proof because `Base58.encode` is expensive. Reverts with
     * {SolanaProgramIdMismatch} if the log does not carry the expected authenticated prefix (this also covers a
     * missing/malformed `"program: ..., "` wrapper).
     */
    function _extractSolanaLogBlob(
        string memory logMessage,
        bytes memory expectedPrefix
    ) internal pure returns (string memory) {
        bytes memory logBytes = bytes(logMessage);
        uint256 prefixLen = expectedPrefix.length;

        if (logBytes.length < prefixLen) revert SolanaProgramIdMismatch();
        for (uint256 i = 0; i < prefixLen; ++i) {
            if (logBytes[i] != expectedPrefix[i]) revert SolanaProgramIdMismatch();
        }

        bytes memory blob = new bytes(logBytes.length - prefixLen);
        for (uint256 j = 0; j < blob.length; ++j) {
            blob[j] = logBytes[prefixLen + j];
        }
        return string(blob);
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
