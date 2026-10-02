// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import { BoundedOracle } from "../../../src/integrations/oracles/common/BoundedOracle.sol";
import { LayerZeroOracle, Origin } from "../../../src/integrations/oracles/layerzero/LayerZeroOracle.sol";
import { MessageEncodingLib } from "../../../src/libs/MessageEncodingLib.sol";
import { BoundAttester } from "./BoundAttester.sol";
import { EndpointFixture } from "./EndpointFixture.sol";
import { Test } from "forge-std/Test.sol";

contract LayerZeroOracleTest is Test {
    EndpointFixture endpoint;
    LayerZeroOracle lz;
    BoundAttester source;
    bytes32 constant SENDER = keccak256("stellar oracle");
    bytes32 constant APP = keccak256("stellar settler");
    uint256 constant CHAIN = 0x53544c;

    function setUp() public {
        endpoint = new EndpointFixture();
        source = new BoundAttester();
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

    function options() internal pure returns (bytes memory) {
        return abi.encodePacked(hex"000301001101", uint128(200_000));
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

    function testQuoteRejectsMissingOptionsAndUnknownChain() public {
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
