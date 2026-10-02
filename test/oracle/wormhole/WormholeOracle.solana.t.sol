// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.22;

import { Test } from "forge-std/Test.sol";

import { WormholeOracle } from "../../../src/integrations/oracles/wormhole/WormholeOracle.sol";
import "../../../src/integrations/oracles/wormhole/external/wormhole/Structs.sol";
import { MessageEncodingLib } from "../../../src/libs/MessageEncodingLib.sol";
import { ExportedMessages } from "./WormholeVerifier.t.sol";

/// @notice Receiving VAAs emitted by the Solana `oracle_wormhole` program. Solana emitters are full 32-byte
/// accounts (the oracle state PDA), so the upper 12 bytes are non-zero, unlike EVM emitters.
contract WormholeOracleSolanaTest is Test {
    uint16 constant SOLANA_WORMHOLE_CHAIN_ID = 1;
    uint256 constant SOLANA_MAINNET_CHAIN_ID = 1151111081099710;
    bytes32 constant SOLANA_EMITTER = keccak256("oracle_wormhole state PDA");

    bytes prevalidVM = hex"01" hex"00000000" hex"01";

    uint256 testGuardian;
    ExportedMessages messages;
    WormholeOracle oracle;

    function setUp() public {
        (, testGuardian) = makeAddrAndKey("signer");

        messages = new ExportedMessages();

        // Initialise the guardian set with one guardian.
        address[] memory keys = new address[](1);
        keys[0] = vm.addr(testGuardian);
        messages.storeGuardianSetPub(Structs.GuardianSet(keys, 0), uint32(0));

        oracle = new WormholeOracle(address(this), address(messages));
    }

    function encodeMessageCalldata(
        bytes32 identifier,
        bytes[] calldata payloads
    ) external pure returns (bytes memory) {
        return MessageEncodingLib.encodeMessage(identifier, payloads);
    }

    /// @dev Same layout as `WormholeVerifierTest.buildPreMessage`, with the emitter chain and address as inputs.
    function buildPreMessage(
        uint16 emitterChainId,
        bytes32 emitterAddress
    ) internal pure returns (bytes memory preMessage) {
        return
            abi.encodePacked(hex"000003e8" hex"00000001", emitterChainId, emitterAddress, hex"0000000000000539" hex"0f");
    }

    /// @dev Same signing scheme as `WormholeVerifierTest.makeValidVM`, with the emitter chain and address as inputs.
    function makeValidVM(
        uint16 emitterChainId,
        bytes32 emitterAddress,
        bytes memory message
    ) internal view returns (bytes memory validVM) {
        bytes memory postvalidVM = abi.encodePacked(buildPreMessage(emitterChainId, emitterAddress), message);
        bytes32 vmHash = keccak256(abi.encodePacked(keccak256(postvalidVM)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(testGuardian, vmHash);

        validVM = abi.encodePacked(prevalidVM, uint8(0), r, s, v - 27, postvalidVM);
    }

    function _solanaVaa(
        bytes32 application,
        bytes memory payload
    ) internal view returns (bytes memory) {
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = payload;
        bytes memory message = this.encodeMessageCalldata(application, payloads);
        return makeValidVM(SOLANA_WORMHOLE_CHAIN_ID, SOLANA_EMITTER, message);
    }

    function test_receiveMessage_solana_emitter() external {
        assertTrue(uint256(SOLANA_EMITTER) >> 160 != 0, "upper 12 bytes must be non-zero");

        bytes32 application = keccak256("solana output settler PDA");
        bytes memory payload = hex"0102030405";
        bytes32 payloadHash = keccak256(payload);

        oracle.setChainMap(SOLANA_WORMHOLE_CHAIN_ID, SOLANA_MAINNET_CHAIN_ID);
        assertFalse(oracle.isProven(SOLANA_MAINNET_CHAIN_ID, SOLANA_EMITTER, application, payloadHash));

        oracle.receiveMessage(_solanaVaa(application, payload));

        assertTrue(oracle.isProven(SOLANA_MAINNET_CHAIN_ID, SOLANA_EMITTER, application, payloadHash));
        // The full 32-byte emitter is the identity; its truncated EVM form is not proven.
        assertFalse(
            oracle.isProven(
                SOLANA_MAINNET_CHAIN_ID, bytes32(uint256(uint160(uint256(SOLANA_EMITTER)))), application, payloadHash
            )
        );
    }

    function test_revert_receiveMessage_solana_emitter_without_chain_map() external {
        bytes memory vaa = _solanaVaa(keccak256("solana output settler PDA"), hex"0102030405");

        vm.expectRevert(abi.encodeWithSignature("ZeroValue()"));
        oracle.receiveMessage(vaa);
    }
}
