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
            MandateOutputEncodingLib.hashFillDescriptionMemory(solver, orderId, timestamp, mandateOutput);
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

            payloadHash = MandateOutputEncodingLib.hashNotFilledDescriptionMemory(orderId, fillDeadline, output);
        } else {
            revert WrongEventSignature();
        }

        bytes32 application = emittingContract.toIdentifier();
        _attestations[remoteChainId][address(this).toIdentifier()][application][payloadHash] = true;

        emit OutputProven(remoteChainId, address(this).toIdentifier(), application, payloadHash);
    }

    /// ************** Solana Processing ************** ///

    /**
     * @dev Processes a Solana proof from `validateSolLogs`.
     *
     * Identity is the Polymer-authenticated `returnedProgramId`, never log content. Polymer binds each returned log to
     * that program id (its membership proof commits `keccak256(programID || logs)`), so attestations self-namespace: a
     * forged proof can only write under the attacker's own program id, which no honest order reads. Mirrors the EVM
     * path keying on `emittingContract`; attribution ultimately trusts Polymer's ingestion.
     *
     * Each returned log is the raw base64 blob `application(32) || payload` (Polymer strips the emitter's
     * `"Prove: program: <id>, "` template). A non-base64 or <=32-byte log reverts the whole proof (fail closed).
     */
    function _processSolanaMessage(
        bytes calldata proof
    ) internal {
        (uint32 chainId, bytes32 returnedProgramId, string[] memory logMessages) =
            CROSS_L2_PROVER.validateSolLogs(proof);

        if (chainId != SOLANA_POLYMER_CHAIN_ID) revert NotSolanaMessage();

        uint256 remoteChainId = _getChainId(uint256(chainId));

        for (uint256 i = 0; i < logMessages.length; ++i) {
            // Whole log is base64(application(32) || payload); decode reverts on non-base64 (fail closed).
            bytes memory logBytes = Base64.decode(logMessages[i]);

            // Reject an empty payload (a bare 32-byte blob would hash keccak256("")).
            if (logBytes.length <= SOLANA_PAYLOAD_OFFSET) revert InvalidSolanaMessage();

            bytes32 application =
                bytes32(Bytes.slice(logBytes, SOLANA_APPLICATION_OFFSET, SOLANA_APPLICATION_OFFSET + 32));
            bytes32 payloadHash = keccak256(Bytes.slice(logBytes, SOLANA_PAYLOAD_OFFSET, logBytes.length));

            _attestations[remoteChainId][returnedProgramId][application][payloadHash] = true;
            emit OutputProven(remoteChainId, returnedProgramId, application, payloadHash);
        }
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
