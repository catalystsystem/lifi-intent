// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import { BoundedOracle } from "../../../src/integrations/oracles/common/BoundedOracle.sol";
import { MappedOracle } from "../../../src/integrations/oracles/common/MappedOracle.sol";
import { LayerZeroOracle, Origin } from "../../../src/integrations/oracles/layerzero/LayerZeroOracle.sol";
import { MessageEncodingLib } from "../../../src/libs/MessageEncodingLib.sol";
import { BoundAttester } from "./BoundAttester.sol";
import { EndpointFixture } from "./EndpointFixture.sol";
import { Test } from "forge-std/Test.sol";
import { Ownable } from "openzeppelin/access/Ownable.sol";

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
        lz = new LayerZeroOracle(address(this), address(endpoint));
        lz.setChainMap(30600, CHAIN, security(1, 1));
    }

    function security(
        uint64 send,
        uint64 recv
    ) internal pure returns (LayerZeroOracle.Security memory s) {
        address[] memory dvns = new address[](1);
        dvns[0] = address(0x1234);
        s = LayerZeroOracle.Security(address(1), address(2), address(3), send, recv, dvns, dvns);
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
        LayerZeroOracle o = new LayerZeroOracle(address(this), address(endpoint));
        vm.expectRevert(BoundedOracle.InvalidConfiguration.selector);
        o.setChainMap(30601, 7, security(type(uint64).max, 1));
        vm.expectRevert(BoundedOracle.InvalidConfiguration.selector);
        o.setChainMap(30601, 7, security(1, type(uint64).max));
    }

    function testLayerZeroChainMapOwnerSetOnce() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBEEF)));
        lz.setChainMap(30601, 1, security(1, 1));
        vm.expectRevert(MappedOracle.ZeroValue.selector);
        lz.setChainMap(0, 1, security(1, 1));
        vm.expectRevert(MappedOracle.ZeroValue.selector);
        lz.setChainMap(30601, 0, security(1, 1));
        vm.expectRevert(MappedOracle.AlreadySet.selector);
        lz.setChainMap(30600, 1, security(1, 1));
        vm.expectRevert(MappedOracle.AlreadySet.selector);
        lz.setChainMap(30601, CHAIN, security(1, 1));

        assertFalse(lz.allowInitializePath(Origin(30601, SENDER, 1)));
        vm.expectEmit(address(lz));
        emit LayerZeroOracle.ChainMapConfigured(30601, 1);
        lz.setChainMap(30601, 1, security(1, 1));
        assertTrue(lz.allowInitializePath(Origin(30601, SENDER, 1)));
        assertEq(endpoint.configs(keccak256(abi.encode(address(lz), uint32(30601), "send"))), abi.encode(address(1)));
        assertEq(lz.reverseChainIdMap(1), bytes32(uint256(30601)));

        for (uint32 i; i < 17; ++i) {
            lz.setChainMap(30700 + i, 2000 + i, security(1, 1));
        }
        assertEq(lz.route(30716), 2016);

        lz.renounceOwnership();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        lz.setChainMap(30800, 3000, security(1, 1));
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
