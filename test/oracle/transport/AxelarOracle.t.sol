// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import { AxelarOracle } from "../../../src/integrations/oracles/axelar/AxelarOracle.sol";
import { BoundedOracle } from "../../../src/integrations/oracles/common/BoundedOracle.sol";
import { MappedOracle } from "../../../src/integrations/oracles/common/MappedOracle.sol";
import { OracleAddress } from "../../../src/integrations/oracles/common/OracleAddress.sol";
import { MessageEncodingLib } from "../../../src/libs/MessageEncodingLib.sol";
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
        axelar.setChainMap("stellar", CHAIN, OracleAddress.Kind.Stellar);
    }

    receive() external payable { }

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

    function testSolanaEnvelopeAndExplicitSelfRelay() public {
        AxelarOracle oracle = new AxelarOracle(address(this), address(gateway), address(gateway));
        oracle.setChainMap("solana", 9, OracleAddress.Kind.Solana);
        source.setOracle(address(oracle));
        bytes[] memory p = new bytes[](1);
        p[0] = new bytes(320);
        bytes32 config = keccak256("config");
        oracle.submit("solana", SENDER, address(source), p, config, AxelarOracle.DeliveryMode.SelfRelay);
        assertEq(gateway.paid(), 0);
        assertEq(gateway.lastSender(), address(oracle));
        assertEq(
            gateway.lastMessage(),
            bytes.concat(
                hex"0064010000",
                this.encode(bytes32(uint256(uint160(address(source)))), p),
                hex"01000000",
                config,
                hex"00"
            )
        );
        assertEq(gateway.lastDestination(), OracleAddress.encode(SENDER, OracleAddress.Kind.Solana));
        vm.expectRevert();
        oracle.submit{ value: 1 }("solana", SENDER, address(source), p, config, AxelarOracle.DeliveryMode.SelfRelay);
        vm.expectRevert();
        oracle.submit("solana", SENDER, address(source), p, config, AxelarOracle.DeliveryMode.Relayed);
        oracle.submit{ value: 10 }("solana", SENDER, address(source), p, config, AxelarOracle.DeliveryMode.Relayed);
        assertEq(gateway.paid(), 10);
        vm.expectRevert();
        oracle.submit("solana", SENDER, address(source), p, bytes32(0), AxelarOracle.DeliveryMode.SelfRelay);
        p[0] = new bytes(321);
        vm.expectRevert();
        oracle.submit("solana", SENDER, address(source), p, config, AxelarOracle.DeliveryMode.SelfRelay);
    }

    function testAxelarExportAndAuthenticatedNamespace() public {
        source.setOracle(address(axelar));
        axelar.submit{ value: 10 }(
            "stellar", SENDER, address(source), payloads(), bytes32(0), AxelarOracle.DeliveryMode.Relayed
        );
        assertEq(gateway.lastSender(), address(axelar));
        assertEq(gateway.lastRefund(), address(this));
        assertEq(gateway.lastDestination(), OracleAddress.encode(SENDER, OracleAddress.Kind.Stellar));
        bytes memory m = this.encode(APP, payloads());
        string memory sender = OracleAddress.encode(SENDER, OracleAddress.Kind.Stellar);
        vm.expectRevert();
        axelar.execute(bytes32(0), "stellar", sender, m);
        gateway.approve(bytes32(0), "stellar", sender, address(axelar), m);
        axelar.execute(bytes32(0), "stellar", sender, m);
        assertTrue(axelar.isProven(CHAIN, SENDER, APP, keccak256(payloads()[0])));
        assertFalse(axelar.isProven(CHAIN, bytes32(uint256(1)), APP, keccak256(payloads()[0])));
        vm.expectRevert();
        axelar.execute(bytes32(0), "stellar", sender, m);
        gateway.approve(bytes32(uint256(1)), "stellar", sender, address(axelar), m);
        axelar.execute(bytes32(uint256(1)), "stellar", sender, m);
    }

    function testAxelarChainMapOwnerSetOnce() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBEEF)));
        axelar.setChainMap("evm", 1, OracleAddress.Kind.Evm);
        vm.expectRevert(MappedOracle.ZeroValue.selector);
        axelar.setChainMap("evm", 0, OracleAddress.Kind.Evm);
        vm.expectRevert(MappedOracle.AlreadySet.selector);
        axelar.setChainMap("stellar", 2, OracleAddress.Kind.Evm);
        vm.expectRevert(MappedOracle.AlreadySet.selector);
        axelar.setChainMap("evm", CHAIN, OracleAddress.Kind.Evm);
        string[4] memory bad = ["Evm", "", "abcdefghijklmnopqrstu", "e_vm"];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(BoundedOracle.InvalidConfiguration.selector);
            axelar.setChainMap(bad[i], 2, OracleAddress.Kind.Evm);
        }
        vm.expectEmit(address(axelar));
        emit AxelarOracle.ChainMapConfigured("evm", 1, OracleAddress.Kind.Evm);
        axelar.setChainMap("evm", 1, OracleAddress.Kind.Evm);
        assertEq(axelar.reverseChainIdMap(1), keccak256("evm"));
        for (uint256 i; i < 17; ++i) {
            axelar.setChainMap(string.concat("c", vm.toString(i)), 1000 + i, OracleAddress.Kind.Evm);
        }
        assertEq(axelar.route("C16").chainId, 1016);
        vm.expectRevert(BoundedOracle.UnknownChain.selector);
        axelar.route("stellar ");
        axelar.renounceOwnership();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        axelar.setChainMap("late", 5, OracleAddress.Kind.Evm);
    }

    function testAxelarLowercaseLookupForwardsCanonicalName() public {
        source.setOracle(address(axelar));
        axelar.submit{ value: 10 }(
            "STELLAR", SENDER, address(source), payloads(), bytes32(0), AxelarOracle.DeliveryMode.Relayed
        );
        assertEq(gateway.lastChain(), "stellar");
        assertEq(gateway.lastGasChain(), "stellar");
        bytes memory m = this.encode(APP, payloads());
        string memory sender = OracleAddress.encode(SENDER, OracleAddress.Kind.Stellar);
        gateway.approve(bytes32(uint256(7)), "Stellar", sender, address(axelar), m);
        axelar.execute(bytes32(uint256(7)), "Stellar", sender, m);
        assertTrue(axelar.isProven(CHAIN, SENDER, APP, keccak256(payloads()[0])));
    }

    function testBoundsMalformedRollbackAndExportNamespace() public {
        bytes memory m = bytes.concat(this.encode(APP, payloads()), hex"00");
        string memory sender = OracleAddress.encode(SENDER, OracleAddress.Kind.Stellar);
        gateway.approve(bytes32(0), "stellar", sender, address(axelar), m);
        bytes32 key = keccak256(abi.encode(bytes32(0), "stellar", sender, address(axelar), keccak256(m)));
        vm.expectRevert();
        axelar.execute(bytes32(0), "stellar", sender, m);
        assertTrue(gateway.approvals(key));
        vm.expectRevert();
        axelar.submit{ value: 10 }(
            "stellar", SENDER, address(source), payloads(), bytes32(0), AxelarOracle.DeliveryMode.Relayed
        );
        source.setOracle(address(axelar));
        bytes[] memory big = new bytes[](1);
        big[0] = new bytes(685);
        vm.expectRevert();
        axelar.submit{ value: 10 }(
            "stellar", SENDER, address(source), big, bytes32(0), AxelarOracle.DeliveryMode.Relayed
        );
    }
}
