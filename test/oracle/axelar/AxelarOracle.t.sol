// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import { AxelarOracle } from "../../../src/integrations/oracles/axelar/AxelarOracle.sol";
import { AxelarStrings } from "../../../src/integrations/oracles/axelar/AxelarStrings.sol";
import { SolanaEnvelope } from "../../../src/integrations/oracles/axelar/SolanaEnvelope.sol";
import { MessageEncodingLib } from "../../../src/libs/MessageEncodingLib.sol";
import { ChainMap } from "../../../src/oracles/ChainMap.sol";
import { AddressStrings } from "./AddressStrings.sol";
import { BoundAttester } from "./BoundAttester.sol";
import { GatewayFixture } from "./GatewayFixture.sol";
import { Test } from "forge-std/Test.sol";
import { Ownable } from "openzeppelin/access/Ownable.sol";

contract AxelarOracleTest is Test {
    GatewayFixture gateway;
    AxelarOracle axelar;
    BoundAttester source;
    bytes32 constant SENDER = keccak256("stellar oracle");
    bytes32 constant APP = keccak256("stellar settler");
    uint256 constant CHAIN = 0x53544c;

    function setUp() public {
        gateway = new GatewayFixture();
        source = new BoundAttester();
        axelar = new AxelarOracle(address(this), address(gateway), address(gateway));
        axelar.setChainMap(pack("stellar"), CHAIN);
    }

    receive() external payable { }

    function pack(
        string memory s
    ) internal pure returns (uint256) {
        return uint256(bytes32(bytes(s)));
    }

    function payloads() internal pure returns (bytes[] memory p) {
        p = new bytes[](2);
        p[0] = hex"d1252dff012345";
        p[1] = hex"830c1e1c987654";
    }

    function encode(
        bytes32 application,
        bytes[] calldata p
    ) external pure returns (bytes memory) {
        return MessageEncodingLib.encodeMessage(application, p);
    }

    function approvalKey(
        bytes32 command,
        string memory chain,
        string memory sender,
        bytes memory message
    ) internal view returns (bytes32) {
        return keccak256(abi.encode(command, chain, sender, address(axelar), keccak256(message)));
    }

    // --- Setter --- //

    function testSetChainMapRejectsNonOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBEEF)));
        axelar.setChainMap(pack("evm"), 1);
    }

    function testSetChainMapRejectsNonCanonicalKeys() public {
        uint256[6] memory bad = [
            uint256(0),
            pack("Evm"),
            pack("evM"),
            pack("evm") >> 8,
            pack("evm") | 0xff,
            pack("ev") | (uint256(0x6d) << 224)
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(AxelarStrings.InvalidChainName.selector);
            axelar.setChainMap(bad[i], 2);
        }
    }

    function testSetChainMapAcceptsAnyCharsetAndFullWord() public {
        axelar.setChainMap(pack("a"), 2);
        axelar.setChainMap(pack("e_vm.2"), 3);
        axelar.setChainMap(pack("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), 4);
        axelar.setChainMap(uint256(bytes32(hex"c3a9")), 5); // UTF-8 "é": bytes >= 0x80 are kept
        assertEq(axelar.chainIdMap(pack("a")), 2);
        assertEq(axelar.chainIdMap(pack("e_vm.2")), 3);
        assertEq(axelar.chainIdMap(pack("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")), 4);
        assertEq(axelar.reverseChainIdMap(4), type(uint256).max / 0xff * 0x61);
    }

    function testSubmitForwardsFullWordName() public {
        string memory name = "abcdefghijklmnopqrstuvwxyz-01234";
        axelar.setChainMap(pack(name), 32);
        source.setOracle(address(axelar));
        axelar.submit(32, "r", address(source), payloads(), bytes32(0), AxelarOracle.DeliveryMode.SelfRelay);
        assertEq(gateway.lastChain(), name);
    }

    function testSetChainMapSetOnce() public {
        vm.expectRevert(ChainMap.ZeroValue.selector);
        axelar.setChainMap(pack("evm"), 0);
        vm.expectRevert(ChainMap.AlreadySet.selector);
        axelar.setChainMap(pack("stellar"), 2);
        vm.expectRevert(ChainMap.AlreadySet.selector);
        axelar.setChainMap(pack("evm"), CHAIN);

        vm.expectEmit(address(axelar));
        emit ChainMap.ChainMapConfigured(pack("evm"), 1);
        axelar.setChainMap(pack("evm"), 1);
        assertEq(axelar.reverseChainIdMap(1), pack("evm"));
        assertEq(axelar.chainIdMap(pack("evm")), 1);

        axelar.renounceOwnership();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        axelar.setChainMap(pack("late"), 5);
    }

    // --- Submit --- //

    function testSubmitRelayed() public {
        source.setOracle(address(axelar));
        string memory recipient = AddressStrings.stellar(SENDER);
        axelar.submit{ value: 10 }(
            CHAIN, recipient, address(source), payloads(), bytes32(0), AxelarOracle.DeliveryMode.Relayed
        );
        assertEq(gateway.lastChain(), "stellar");
        assertEq(gateway.lastGasChain(), "stellar");
        assertEq(gateway.lastDestination(), recipient);
        assertEq(gateway.lastMessage(), this.encode(bytes32(uint256(uint160(address(source)))), payloads()));
        assertEq(gateway.lastSender(), address(axelar));
        assertEq(gateway.lastRefund(), address(this));
        assertEq(gateway.paid(), 10);
    }

    function testSubmitRejects() public {
        string memory recipient = AddressStrings.stellar(SENDER);
        vm.expectRevert(AxelarOracle.NotAllPayloadsValid.selector);
        axelar.submit{ value: 10 }(
            CHAIN, recipient, address(source), payloads(), bytes32(0), AxelarOracle.DeliveryMode.Relayed
        );
        source.setOracle(address(axelar));
        vm.expectRevert(ChainMap.ZeroValue.selector);
        axelar.submit{ value: 10 }(
            999, recipient, address(source), payloads(), bytes32(0), AxelarOracle.DeliveryMode.Relayed
        );
        vm.expectRevert(AxelarOracle.InvalidFee.selector);
        axelar.submit(CHAIN, recipient, address(source), payloads(), bytes32(0), AxelarOracle.DeliveryMode.Relayed);
        vm.expectRevert(AxelarOracle.InvalidFee.selector);
        axelar.submit{ value: 1 }(
            CHAIN, recipient, address(source), payloads(), bytes32(0), AxelarOracle.DeliveryMode.SelfRelay
        );
    }

    function testSolanaEnvelope() public {
        axelar.setChainMap(pack("solana"), 9);
        source.setOracle(address(axelar));
        string memory recipient = AddressStrings.solana(SENDER);
        bytes[] memory p = new bytes[](1);
        p[0] = new bytes(320);
        bytes32 config = keccak256("config");
        bytes memory raw = this.encode(bytes32(uint256(uint160(address(source)))), p);

        axelar.submit(9, recipient, address(source), p, config, AxelarOracle.DeliveryMode.SelfRelay);
        assertEq(gateway.lastChain(), "solana");
        assertEq(gateway.paid(), 0);
        assertEq(gateway.lastMessage(), bytes.concat(hex"0064010000", raw, hex"01000000", config, hex"00"));

        axelar.submit(9, recipient, address(source), p, bytes32(0), AxelarOracle.DeliveryMode.SelfRelay);
        assertEq(gateway.lastMessage(), raw);

        p[0] = new bytes(321);
        vm.expectRevert(SolanaEnvelope.InvalidSolanaEnvelope.selector);
        axelar.submit(9, recipient, address(source), p, config, AxelarOracle.DeliveryMode.SelfRelay);
    }

    // --- Execute --- //

    function testExecuteInfersSenderFormat() public {
        bytes memory m = this.encode(APP, payloads());
        bytes32 h = keccak256(payloads()[0]);
        address evmAddr = makeAddr("evm oracle");
        bytes32 solanaId = keccak256("solana oracle");
        string[3] memory senders =
            [AddressStrings.stellar(SENDER), vm.toString(evmAddr), AddressStrings.solana(solanaId)];
        bytes32[3] memory ids = [SENDER, bytes32(uint256(uint160(evmAddr))), solanaId];
        for (uint256 i; i < 3; ++i) {
            bytes32 command = bytes32(i);
            gateway.approve(command, "stellar", senders[i], address(axelar), m);
            axelar.execute(command, "stellar", senders[i], m);
            assertTrue(axelar.isProven(CHAIN, ids[i], APP, h));
        }
        assertFalse(axelar.isProven(CHAIN, bytes32(uint256(1)), APP, h));

        vm.expectRevert(AxelarOracle.NotApproved.selector);
        axelar.execute(bytes32(0), "stellar", senders[0], m);
    }

    function testExecuteKeepsApprovedCase() public {
        bytes memory m = this.encode(APP, payloads());
        string memory sender = AddressStrings.stellar(SENDER);
        gateway.approve(bytes32(uint256(7)), "Stellar", sender, address(axelar), m);
        axelar.execute(bytes32(uint256(7)), "Stellar", sender, m);
        assertTrue(axelar.isProven(CHAIN, SENDER, APP, keccak256(payloads()[0])));
    }

    function testExecuteFailuresLeaveApproval() public {
        bytes memory m = this.encode(APP, payloads());
        string memory sender = AddressStrings.stellar(SENDER);

        gateway.approve(bytes32(0), "base", sender, address(axelar), m);
        vm.expectRevert(ChainMap.ZeroValue.selector);
        axelar.execute(bytes32(0), "base", sender, m);
        assertTrue(gateway.approvals(approvalKey(bytes32(0), "base", sender, m)));

        gateway.approve(bytes32(0), "stellar\x00", sender, address(axelar), m);
        vm.expectRevert(AxelarStrings.InvalidChainName.selector);
        axelar.execute(bytes32(0), "stellar\x00", sender, m);
        assertTrue(gateway.approvals(approvalKey(bytes32(0), "stellar\x00", sender, m)));

        string memory long = "abcdefghijklmnopqrstuvwxyz-012345";
        gateway.approve(bytes32(0), long, sender, address(axelar), m);
        vm.expectRevert(AxelarStrings.InvalidChainName.selector);
        axelar.execute(bytes32(0), long, sender, m);
        assertTrue(gateway.approvals(approvalKey(bytes32(0), long, sender, m)));

        gateway.approve(bytes32(0), "stellar", "hello", address(axelar), m);
        vm.expectRevert(AxelarStrings.InvalidOracleAddress.selector);
        axelar.execute(bytes32(0), "stellar", "hello", m);
        assertTrue(gateway.approvals(approvalKey(bytes32(0), "stellar", "hello", m)));

        bytes memory trailing = bytes.concat(m, hex"00");
        gateway.approve(bytes32(0), "stellar", sender, address(axelar), trailing);
        vm.expectRevert();
        axelar.execute(bytes32(0), "stellar", sender, trailing);
        assertTrue(gateway.approvals(approvalKey(bytes32(0), "stellar", sender, trailing)));
    }
}
