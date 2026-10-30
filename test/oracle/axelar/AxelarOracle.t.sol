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

    /// A rejected name leaves both maps empty and does not consume `chainId`: `valid` can still take it.
    function assertRejectedThenFree(
        uint256 key,
        uint256 chainId,
        string memory valid
    ) internal {
        vm.expectRevert(AxelarStrings.InvalidChainName.selector);
        axelar.setChainMap(key, chainId);
        assertEq(axelar.chainIdMap(key), 0);
        assertEq(axelar.reverseChainIdMap(chainId), 0);
        axelar.setChainMap(pack(valid), chainId);
        assertEq(axelar.reverseChainIdMap(chainId), pack(valid));
    }

    function testSetChainMapRejectsUnderscore() public {
        assertRejectedThenFree(pack("_evm"), 2, "evm-a");
        assertRejectedThenFree(pack("e_vm"), 3, "evm-b");
        assertRejectedThenFree(pack("evm_"), 4, "evm-c");
        assertRejectedThenFree(pack("aaaaaaaaaaaaaaaaaaa_"), 5, "evm-d"); // byte 19 of a 20-byte name
    }

    function testFuzzSetChainMapRejectsUnderscore(
        uint256 length,
        uint256 at,
        uint256 chainId
    ) public {
        length = bound(length, 1, 20);
        at = bound(at, 0, length - 1);
        vm.assume(chainId != 0 && chainId != CHAIN);
        bytes memory name = bytes("aaaaaaaaaaaaaaaaaaaa");
        name[at] = "_";
        assertRejectedThenFree(pack(string(name)) & ~(type(uint256).max >> (8 * length)), chainId, "evm");
    }

    function testSetChainMapLengthBound() public {
        axelar.setChainMap(pack("a"), 2);
        axelar.setChainMap(pack("aaaaaaaaaaaaaaaaaaaa"), 3); // 20 bytes
        assertEq(axelar.chainIdMap(pack("a")), 2);
        assertEq(axelar.reverseChainIdMap(3), pack("aaaaaaaaaaaaaaaaaaaa"));
        assertRejectedThenFree(pack("aaaaaaaaaaaaaaaaaaaaa"), 4, "evm-a"); // 21 bytes
        assertRejectedThenFree(type(uint256).max / 0xff * 0x61, 5, "evm-b"); // 32 bytes
    }

    function testFuzzSetChainMapRejectsLongNames(
        uint256 length,
        uint256 chainId
    ) public {
        length = bound(length, 21, 32);
        vm.assume(chainId != 0 && chainId != CHAIN);
        uint256 key = type(uint256).max / 0xff * 0x61 & ~(type(uint256).max >> (8 * length));
        assertRejectedThenFree(key, chainId, "evm");
    }

    function testSetChainMapAsciiBound() public {
        axelar.setChainMap(uint256(bytes32(hex"617f")), 2); // DEL, the highest ASCII byte, is accepted
        assertEq(axelar.chainIdMap(uint256(bytes32(hex"617f"))), 2);
        assertRejectedThenFree(uint256(bytes32(hex"6180")), 3, "evm-a");
        assertRejectedThenFree(uint256(bytes32(hex"c3a9")), 4, "evm-b"); // UTF-8 "é"
    }

    function testFuzzSetChainMapRejectsNonAscii(
        uint256 b,
        uint256 at,
        uint256 chainId
    ) public {
        b = bound(b, 0x80, 0xff);
        at = bound(at, 0, 19);
        vm.assume(chainId != 0 && chainId != CHAIN);
        bytes memory name = bytes("aaaaaaaaaaaaaaaaaaaa");
        name[at] = bytes1(uint8(b));
        assertRejectedThenFree(pack(string(name)), chainId, "evm");
    }

    function testSubmitForwardsMaxLengthName() public {
        string memory name = "abcdefghijklmnop-012";
        axelar.setChainMap(pack(name), 20);
        source.setOracle(address(axelar));
        axelar.submit(name, "r", address(source), payloads(), bytes32(0), AxelarOracle.DeliveryMode.SelfRelay);
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
            "stellar", recipient, address(source), payloads(), bytes32(0), AxelarOracle.DeliveryMode.Relayed
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
            "stellar", recipient, address(source), payloads(), bytes32(0), AxelarOracle.DeliveryMode.Relayed
        );
        source.setOracle(address(axelar));
        vm.expectRevert(ChainMap.ZeroValue.selector);
        axelar.submit{ value: 10 }(
            "unknown", recipient, address(source), payloads(), bytes32(0), AxelarOracle.DeliveryMode.Relayed
        );
        vm.expectRevert(AxelarOracle.InvalidFee.selector);
        axelar.submit("stellar", recipient, address(source), payloads(), bytes32(0), AxelarOracle.DeliveryMode.Relayed);
        vm.expectRevert(AxelarOracle.InvalidFee.selector);
        axelar.submit{ value: 1 }(
            "stellar", recipient, address(source), payloads(), bytes32(0), AxelarOracle.DeliveryMode.SelfRelay
        );
    }

    function testSubmitMixedCaseUsesConfiguredMapping() public {
        axelar.setChainMap(pack("ethereum"), 1);
        vm.expectRevert(AxelarOracle.NotAllPayloadsValid.selector);
        axelar.submit("Ethereum", "r", address(source), payloads(), bytes32(0), AxelarOracle.DeliveryMode.SelfRelay);

        source.setOracle(address(axelar));
        axelar.submit("Ethereum", "r", address(source), payloads(), bytes32(0), AxelarOracle.DeliveryMode.SelfRelay);
        assertEq(gateway.lastChain(), "Ethereum");
        assertEq(gateway.paid(), 0);
        axelar.submit{ value: 10 }(
            "Ethereum", "r", address(source), payloads(), bytes32(0), AxelarOracle.DeliveryMode.Relayed
        );
        assertEq(gateway.lastChain(), "Ethereum");
        assertEq(gateway.lastGasChain(), "Ethereum");
        assertEq(gateway.paid(), 10);
        assertEq(address(axelar).balance, 0);
        assertEq(axelar.chainIdMap(pack("ethereum")), 1);
        assertEq(axelar.chainIdMap(pack("Ethereum")), 0);
        assertEq(axelar.reverseChainIdMap(1), pack("ethereum"));
    }

    function assertDestinationRejectedBeforeFees(
        string memory destination,
        bytes4 expectedError
    ) internal {
        uint256 balanceBefore = address(this).balance;
        for (uint256 mode; mode < 2; ++mode) {
            for (uint256 fee; fee < 2; ++fee) {
                vm.expectRevert(expectedError);
                axelar.submit{ value: fee }(
                    destination, "r", address(source), payloads(), bytes32(0), AxelarOracle.DeliveryMode(mode)
                );
                assertEq(gateway.paid(), 0);
                assertEq(address(gateway).balance, 0);
                assertEq(address(axelar).balance, 0);
                assertEq(address(this).balance, balanceBefore);
            }
        }
    }

    function testSubmitRejectsUnknownAndMalformedDestinationsBeforeFees() public {
        source.setOracle(address(axelar));
        assertDestinationRejectedBeforeFees("unknown", ChainMap.ZeroValue.selector);
        assertDestinationRejectedBeforeFees("", AxelarStrings.InvalidChainName.selector);
        assertDestinationRejectedBeforeFees(string(hex"7374656c6c617200"), AxelarStrings.InvalidChainName.selector);
        // Names longer than the setter's 20-byte limit cannot have a configured mapping.
        assertDestinationRejectedBeforeFees("aaaaaaaaaaaaaaaaaaaaa", ChainMap.ZeroValue.selector);
        assertDestinationRejectedBeforeFees(
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", AxelarStrings.InvalidChainName.selector
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

        axelar.submit("solana", recipient, address(source), p, config, AxelarOracle.DeliveryMode.SelfRelay);
        assertEq(gateway.lastChain(), "solana");
        assertEq(gateway.paid(), 0);
        assertEq(gateway.lastMessage(), bytes.concat(hex"0064010000", raw, hex"01000000", config, hex"00"));

        axelar.submit("solana", recipient, address(source), p, bytes32(0), AxelarOracle.DeliveryMode.SelfRelay);
        assertEq(gateway.lastMessage(), raw);

        p[0] = new bytes(321);
        vm.expectRevert(SolanaEnvelope.InvalidSolanaEnvelope.selector);
        axelar.submit("solana", recipient, address(source), p, config, AxelarOracle.DeliveryMode.SelfRelay);
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
