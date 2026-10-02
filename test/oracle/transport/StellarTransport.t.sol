// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import { AxelarOracle } from "../../../src/integrations/oracles/axelar/AxelarOracle.sol";
import { BoundedOracle } from "../../../src/integrations/oracles/common/BoundedOracle.sol";
import { OracleAddress } from "../../../src/integrations/oracles/common/OracleAddress.sol";
import { LayerZeroOracle, Origin } from "../../../src/integrations/oracles/layerzero/LayerZeroOracle.sol";
import { MessageEncodingLib } from "../../../src/libs/MessageEncodingLib.sol";
import { EndpointFixture, GatewayFixture } from "./TransportFixtures.sol";
import { Test } from "forge-std/Test.sol";

contract BoundAttester {
    address public oracle;

    function setOracle(
        address o
    ) external {
        oracle = o;
    }

    function hasAttested(
        bytes[] calldata
    ) external view returns (bool) {
        return msg.sender == oracle;
    }
}

contract StellarTransportTest is Test {
    GatewayFixture gateway;
    EndpointFixture endpoint;
    AxelarOracle axelar;
    LayerZeroOracle lz;
    BoundAttester source;
    bytes32 constant SENDER = keccak256("stellar oracle");
    bytes32 constant APP = keccak256("stellar settler");
    uint256 constant CHAIN = 0x53544c;

    function setUp() public {
        gateway = new GatewayFixture();
        endpoint = new EndpointFixture();
        source = new BoundAttester();
        AxelarOracle.Chain[] memory a = new AxelarOracle.Chain[](1);
        a[0] = AxelarOracle.Chain("stellar", CHAIN, OracleAddress.Kind.Stellar);
        axelar = new AxelarOracle(address(gateway), address(gateway), a);
        LayerZeroOracle.Chain[] memory c = new LayerZeroOracle.Chain[](1);
        address[] memory dvns = new address[](1);
        dvns[0] = address(0x1234);
        c[0] = LayerZeroOracle.Chain(30600, CHAIN, address(1), address(2), address(3), 1, 1, dvns, dvns);
        lz = new LayerZeroOracle(address(endpoint), c);
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

    function decodeAddress(
        string calldata value,
        OracleAddress.Kind kind
    ) external pure returns (bytes32) {
        return OracleAddress.decode(value, kind);
    }

    function decode(
        bytes calldata b
    ) external pure returns (bytes32, bytes32[] memory) {
        return MessageEncodingLib.getHashesOfEncodedPayloads(b);
    }

    function options() internal pure returns (bytes memory) {
        return abi.encodePacked(hex"000301001101", uint128(200_000));
    }

    function testFuzzStellarAddressRoundtrip(
        bytes32 id
    ) public {
        assertEq(
            this.decodeAddress(OracleAddress.encode(id, OracleAddress.Kind.Stellar), OracleAddress.Kind.Stellar), id
        );
    }

    function testFuzzSolanaAddressRoundtrip(
        bytes32 id
    ) public {
        assertEq(this.decodeAddress(OracleAddress.encode(id, OracleAddress.Kind.Solana), OracleAddress.Kind.Solana), id);
    }

    function testSolanaEnvelopeAndExplicitSelfRelay() public {
        AxelarOracle.Chain[] memory routes = new AxelarOracle.Chain[](1);
        routes[0] = AxelarOracle.Chain("solana", 9, OracleAddress.Kind.Solana);
        AxelarOracle oracle = new AxelarOracle(address(gateway), address(gateway), routes);
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
        vm.expectRevert();
        this.decodeAddress("111111111111111111111111111111111", OracleAddress.Kind.Solana);
        vm.expectRevert();
        this.decodeAddress("01111111111111111111111111111111", OracleAddress.Kind.Solana);
    }

    function testPublishedStrKeyAndBadChecksum() public {
        string memory zero = "CAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABSC4";
        assertEq(OracleAddress.encode(bytes32(0), OracleAddress.Kind.Stellar), zero);
        assertEq(this.decodeAddress(zero, OracleAddress.Kind.Stellar), bytes32(0));
        vm.expectRevert();
        this.decodeAddress("CAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABSC5", OracleAddress.Kind.Stellar);
        vm.expectRevert();
        this.decodeAddress("GAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAWHF", OracleAddress.Kind.Stellar);
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

    function testSolanaSenderCacheIsPermissionlessAndCheapensExecute() public {
        AxelarOracle.Chain[] memory routes = new AxelarOracle.Chain[](1);
        routes[0] = AxelarOracle.Chain("solana", 9, OracleAddress.Kind.Solana);
        AxelarOracle oracle = new AxelarOracle(address(gateway), address(gateway), routes);
        bytes[] memory p = new bytes[](1);
        p[0] = hex"d1252dff012345";
        bytes memory m = this.encode(APP, p);
        string memory sender = OracleAddress.encode(SENDER, OracleAddress.Kind.Solana);

        gateway.approve(bytes32(0), "solana", sender, address(oracle), m);
        uint256 g = gasleft();
        oracle.execute(bytes32(0), "solana", sender, m);
        uint256 uncached = g - gasleft();

        // Non-canonical spellings are rejected, so they can never be cached.
        vm.expectRevert(OracleAddress.InvalidOracleAddress.selector);
        oracle.cacheSolanaAddress(string.concat("1", sender));
        vm.prank(address(0xBEEF));
        assertEq(oracle.cacheSolanaAddress(sender), SENDER);
        assertEq(oracle.solanaAddresses(keccak256(bytes(sender))), SENDER);

        // A fresh proof, so both measured calls write a new tuple.
        p[0] = hex"830c1e1c987654";
        m = this.encode(APP, p);
        gateway.approve(bytes32(uint256(1)), "solana", sender, address(oracle), m);
        g = gasleft();
        oracle.execute(bytes32(uint256(1)), "solana", sender, m);
        uint256 cached = g - gasleft();
        assertTrue(oracle.isProven(9, SENDER, APP, keccak256(p[0])));
        assertLt(cached * 5, uncached);
    }

    function testLayerZeroExportReceiveReplayAndFees() public {
        source.setOracle(address(lz));
        uint256 beforeBalance = address(this).balance;
        lz.submit{ value: 20 }(30600, SENDER, address(source), payloads(), options());
        assertEq(address(this).balance, beforeBalance - 10);
        assertEq(endpoint.lastRecipient(), SENDER);
        bytes memory m = this.encode(APP, payloads());
        Origin memory o = Origin(30600, SENDER, 1);
        vm.expectRevert();
        lz.lzReceive(o, bytes32(0), m, address(this), "");
        endpoint.approve(address(lz), o, bytes32(0), m);
        endpoint.deliver(address(lz), o, bytes32(0), m);
        assertTrue(lz.isProven(CHAIN, SENDER, APP, keccak256(payloads()[1])));
        vm.expectRevert();
        endpoint.deliver(address(lz), o, bytes32(0), m);
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
        this.decode(m);
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
        vm.expectRevert();
        lz.quote(30600, SENDER, address(source), payloads(), hex"");
        vm.expectRevert();
        lz.quote(999, SENDER, address(source), payloads(), options());
    }

    function testLayerZeroRejectsNilConfirmations() public {
        address[] memory dvns = new address[](1);
        dvns[0] = address(0x1234);
        LayerZeroOracle.Chain[] memory c = new LayerZeroOracle.Chain[](1);
        c[0] = LayerZeroOracle.Chain(30600, CHAIN, address(1), address(2), address(3), type(uint64).max, 1, dvns, dvns);
        vm.expectRevert(BoundedOracle.InvalidConfiguration.selector);
        new LayerZeroOracle(address(endpoint), c);
        c[0].sendConfirmations = 1;
        c[0].receiveConfirmations = type(uint64).max;
        vm.expectRevert(BoundedOracle.InvalidConfiguration.selector);
        new LayerZeroOracle(address(endpoint), c);
    }

    function testMaximumBatchAndTupleChecks() public {
        bytes[] memory p = new bytes[](4);
        for (uint256 i; i < 4; ++i) {
            p[i] = new bytes(684);
            p[i][0] = bytes1(uint8(i));
        }
        bytes memory m = this.encode(APP, p);
        assertEq(m.length, 2778);
        Origin memory o = Origin(30600, SENDER, 1);
        endpoint.approve(address(lz), o, bytes32(0), m);
        endpoint.deliver(address(lz), o, bytes32(0), m);
        bytes memory proofs;
        for (uint256 i; i < 4; ++i) {
            proofs = bytes.concat(proofs, abi.encodePacked(CHAIN, SENDER, APP, keccak256(p[i])));
        }
        lz.efficientRequireProven(proofs);
        lz.efficientRequireProven("");
        vm.expectRevert();
        lz.efficientRequireProven(bytes.concat(proofs, hex"00"));
    }
}
