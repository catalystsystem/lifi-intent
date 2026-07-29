// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";

import { Base58 } from "test/util/Base58.sol";
import { PolymerOracle } from "src/integrations/oracles/polymer/PolymerOracle.sol";
import { ICrossL2ProverV2 } from "src/integrations/oracles/polymer/external/interfaces/ICrossL2ProverV2.sol";

/**
 * @notice Live fork test of the Solana -> EVM proving path against the REAL Polymer prover
 *         (not MockCrossL2ProverV2). This exercises the parts the unit tests cannot:
 *         the real sequencer-signature + IAVL membership verification inside
 *         `validateSolLogs`, and the exact log-string format Polymer returns.
 *
 * How to run (see test/oracle/polymer/fetch_solana_proof.sh to obtain a proof):
 *
 *   export RPC_URL_BASESEPOLIA=<base sepolia rpc>
 *   PROOF=$(test/oracle/polymer/fetch_solana_proof.sh <solanaTxSig> <programIdBase58>)
 *   POLYMER_SOLANA_PROOF_HEX=$PROOF \
 *     forge test --match-contract PolymerOracleForkSolana --ffi -vvv
 *
 * If POLYMER_SOLANA_PROOF_HEX is unset the tests no-op (so the default suite stays green).
 */
contract PolymerOracleForkSolanaTest is Test {
    // Polymer CrossL2ProverV2, per docs "Key Network Information":
    //   testnet (indexes Solana devnet): 0x85e9506fd24F9B588dcf2A5AaEF7069e34D99fCE
    //   mainnet:                         0x95ccEAE71605c5d97A0AC0EA13013b058729d075
    // Override with POLYMER_PROVER if these move.
    address internal constant POLYMER_TESTNET_PROVER = 0x85e9506fd24F9B588dcf2A5AaEF7069e34D99fCE;
    uint32 internal constant SOLANA_SRC_CHAIN_ID = 2;

    address internal prover;
    PolymerOracle internal oracle;
    bytes internal proof;
    bool internal enabled;

    function setUp() public {
        proof = vm.envOr("POLYMER_SOLANA_PROOF_HEX", bytes(""));
        if (proof.length == 0) return;
        enabled = true;

        prover = vm.envOr("POLYMER_PROVER", POLYMER_TESTNET_PROVER);

        string memory rpc = vm.envOr("RPC_URL_BASESEPOLIA", string(""));
        require(bytes(rpc).length != 0, "set RPC_URL_BASESEPOLIA to fork the real prover");
        vm.createSelectFork(rpc);

        oracle = new PolymerOracle(prover);
    }

    /// @dev Documents the ACTUAL behavior of Polymer's live testnet prover, verified against two
    ///      independent real Solana devnet transactions (program 5d9Z6bsf…, the Polymer `mars` example).
    ///
    ///      FINDING: Polymer strips the ENTIRE `"Prove: program: <base58>, "` template from the log and
    ///      returns only the trailing content. The authenticated program id comes back separately as the
    ///      `programID` return value (bytes32). Example:
    ///        on-chain:  "Program log: Prove: program: 5d9Z6bsf…, data: 2026-07-20 15:06:20.279571"
    ///        returned:  logMessages[0] == "data: 2026-07-20 15:06:20.279571"
    ///
    ///      This CONTRADICTS Polymer's own docs, which claim the returned log still starts with
    ///      `"program: <base58>, "`. `PolymerOracle` therefore treats the WHOLE returned log as the base64 blob
    ///      (`base64(application(32) || payload)`) and keys attestations on the authenticated `programID`; it no
    ///      longer looks for a `"program: <base58>, "` prefix. (An earlier revision reverted
    ///      `SolanaProgramIdMismatch()` on every real proof; that binding was removed once this was verified.)
    function test_real_validateSolLogs_format() public {
        if (!enabled) {
            emit log("SKIP: set POLYMER_SOLANA_PROOF_HEX to run the live fork test");
            return;
        }

        (uint32 chainId, bytes32 programID, string[] memory logs) =
            ICrossL2ProverV2(prover).validateSolLogs(proof);

        emit log_named_uint("chainId", chainId);
        emit log_named_bytes32("programID", programID);
        // Cross-checks our on-chain Base58 encoder against Polymer's authenticated program id.
        emit log_named_string("base58(programID)", Base58.encode(programID));
        emit log_named_uint("num logs", logs.length);

        assertEq(chainId, SOLANA_SRC_CHAIN_ID, "chainId must be 2 (Solana)");
        assertGt(logs.length, 0, "expected at least one proven log");

        bytes memory strippedPrefix = abi.encodePacked("program: ", Base58.encode(programID), ", ");
        for (uint256 i; i < logs.length; ++i) {
            emit log_named_string(string.concat("log[", vm.toString(i), "]"), logs[i]);
            // Real behavior: the whole "Prove: program: <base58>, " template is already stripped.
            assertFalse(_startsWith(bytes(logs[i]), "Prove:"), "'Prove:' must be stripped");
            assertFalse(_startsWith(bytes(logs[i]), "Program log:"), "'Program log:' must be stripped");
            assertFalse(
                _startsWith(bytes(logs[i]), strippedPrefix),
                "'program: <base58>, ' is stripped by Polymer (oracle wrongly expects it)"
            );
        }
    }

    /// @dev Full round-trip through the oracle. Succeeds when the whole returned log is
    ///      `base64(application(32) || payload)` — i.e. a log emitted by our `oracle_polymer::submit`.
    ///      For an arbitrary (non-OIF) Solana log the returned content is not valid base64 of that layout, so the
    ///      oracle reverts `Base64.InvalidBase64Char` (garbage chars, e.g. the `mars` `"data: <timestamp>"` log) or
    ///      `InvalidSolanaMessage` (decodes to <= 32 bytes) — NOT `SolanaProgramIdMismatch` (that error was removed).
    ///      We log the outcome rather than fail, so this test is informative for any proven tx.
    function test_real_receiveSolanaMessage_roundtrip() public {
        if (!enabled) {
            emit log("SKIP: set POLYMER_SOLANA_PROOF_HEX to run the live fork test");
            return;
        }
        try oracle.receiveSolanaMessage(proof) {
            emit log("receiveSolanaMessage: SUCCEEDED end-to-end against the real Polymer prover");
        } catch (bytes memory err) {
            emit log("receiveSolanaMessage: reverted (expected unless this is an OIF submit tx)");
            emit log_named_bytes("revert", err);
        }
    }

    event OutputProven(uint256 chainid, bytes32 remoteIdentifier, bytes32 application, bytes32 payloadHash);

    /// @dev The decisive end-to-end assertion: a REAL `oracle_polymer::submit` proof, fetched from Polymer's live
    ///      prover, must decode and attest under the expected (chainId=2, programID, application, payloadHash). The
    ///      expected values are passed via env so the test is a reusable harness; when unset it no-ops.
    ///      For the recorded devnet run these are:
    ///        POLYMER_EXPECTED_PROGRAM_ID   = base58-decode(81qeg9…) = 0x6838d114…65c3
    ///        POLYMER_EXPECTED_APPLICATION  = OutputSettlerSimple PDA = 0x57e93c23…a8bf
    ///        POLYMER_EXPECTED_PAYLOADHASH  = keccak256(FILL_MAGIC||solver||orderId||tsBE4||token||amount||recipient||0000||0000)
    ///                                      = 0x61d56e60…da5f (independently reconstructed from the order params).
    function test_real_oif_submit_attestation() public {
        if (!enabled) {
            emit log("SKIP: set POLYMER_SOLANA_PROOF_HEX to run the live fork test");
            return;
        }
        bytes32 expectedProgramId = vm.envOr("POLYMER_EXPECTED_PROGRAM_ID", bytes32(0));
        bytes32 expectedApplication = vm.envOr("POLYMER_EXPECTED_APPLICATION", bytes32(0));
        bytes32 expectedPayloadHash = vm.envOr("POLYMER_EXPECTED_PAYLOADHASH", bytes32(0));
        if (expectedProgramId == bytes32(0)) {
            emit log("SKIP: set POLYMER_EXPECTED_{PROGRAM_ID,APPLICATION,PAYLOADHASH} to assert the OIF submit");
            return;
        }

        vm.expectEmit(true, true, true, true);
        emit OutputProven(uint256(SOLANA_SRC_CHAIN_ID), expectedProgramId, expectedApplication, expectedPayloadHash);
        oracle.receiveSolanaMessage(proof);

        assertTrue(
            oracle.isProven(uint256(SOLANA_SRC_CHAIN_ID), expectedProgramId, expectedApplication, expectedPayloadHash),
            "real OIF submit proof must attest under (2, programID, application, payloadHash)"
        );
    }

    function _startsWith(bytes memory data, bytes memory prefix) internal pure returns (bool) {
        if (data.length < prefix.length) return false;
        for (uint256 i; i < prefix.length; ++i) {
            if (data[i] != prefix[i]) return false;
        }
        return true;
    }
}
