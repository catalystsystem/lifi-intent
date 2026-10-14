// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { LayerZeroOracle, Origin } from "../../../src/integrations/oracles/layerzero/LayerZeroOracle.sol";
import { MessageEncodingLib } from "../../../src/libs/MessageEncodingLib.sol";
import { BaseInputOracle } from "../../../src/oracles/BaseInputOracle.sol";
import { ChainMap } from "../../../src/oracles/ChainMap.sol";
import { BoundAttester } from "../axelar/BoundAttester.sol";
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
    uint32 constant EID = 30600;

    function setUp() public {
        endpoint = new EndpointFixture();
        source = new BoundAttester();
        lz = new LayerZeroOracle(address(this), address(endpoint));
        lz.setChainMap(EID, CHAIN, security(1, 1));
    }

    function security(
        uint64 send,
        uint64 recv
    ) internal pure returns (LayerZeroOracle.Security memory s) {
        address[] memory dvns = new address[](1);
        dvns[0] = address(0x1234);
        s = LayerZeroOracle.Security(address(1), address(2), address(3), 2778, send, recv, dvns, dvns);
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

    function testConstructorRequiresEndpointCode() public {
        vm.expectRevert(LayerZeroOracle.InvalidConfiguration.selector);
        new LayerZeroOracle(address(this), address(0xE11D));
    }

    function testLayerZeroExportReceiveReplayAndFees() public {
        source.setOracle(address(lz));
        uint256 beforeBalance = address(this).balance;
        lz.submit{ value: 20 }(EID, SENDER, address(source), payloads(), options());
        assertEq(address(this).balance, beforeBalance - 10);
        assertEq(endpoint.lastRecipient(), SENDER);
        assertEq(endpoint.lastSender(), address(lz));
        assertEq(endpoint.lastMessage(), this.encode(bytes32(uint256(uint160(address(source)))), payloads()));

        bytes memory m = this.encode(APP, payloads());
        Origin memory o = Origin(EID, SENDER, 1);
        vm.expectRevert(LayerZeroOracle.OnlyEndpoint.selector);
        lz.lzReceive(o, bytes32(0), m, address(this), "");
        endpoint.approve(address(lz), o, bytes32(0), m);
        for (uint256 i; i < 2; ++i) {
            vm.expectEmit(address(lz));
            emit BaseInputOracle.OutputProven(CHAIN, SENDER, APP, keccak256(payloads()[i]));
        }
        endpoint.deliver(address(lz), o, bytes32(0), m);
        assertTrue(lz.isProven(CHAIN, SENDER, APP, keccak256(payloads()[0])));
        assertTrue(lz.isProven(CHAIN, SENDER, APP, keccak256(payloads()[1])));
        assertFalse(lz.isProven(CHAIN, keccak256("other"), APP, keccak256(payloads()[1])));
        vm.expectRevert("unverified");
        endpoint.deliver(address(lz), o, bytes32(0), m);
    }

    function testSubmitRejectsUnattestedUnmappedAndBadOptions() public {
        vm.expectRevert(LayerZeroOracle.NotAllPayloadsValid.selector);
        lz.submit{ value: 10 }(EID, SENDER, address(source), payloads(), options());
        source.setOracle(address(lz));
        vm.expectRevert(ChainMap.ZeroValue.selector);
        lz.submit{ value: 10 }(999, SENDER, address(source), payloads(), options());
        vm.expectRevert(LayerZeroOracle.InvalidOptions.selector);
        lz.submit{ value: 10 }(EID, SENDER, address(source), payloads(), hex"");
    }

    function testQuoteRejectsBadOptionsAndUnmappedChain() public {
        assertEq(lz.quote(EID, SENDER, address(source), payloads(), options()).nativeFee, 10);
        vm.expectRevert(LayerZeroOracle.InvalidOptions.selector);
        lz.quote(EID, SENDER, address(source), payloads(), hex"");
        vm.expectRevert(LayerZeroOracle.InvalidOptions.selector);
        lz.quote(EID, SENDER, address(source), payloads(), abi.encodePacked(hex"000301001101", uint128(0)));
        vm.expectRevert(ChainMap.ZeroValue.selector);
        lz.quote(999, SENDER, address(source), payloads(), options());
    }

    function testReceiveRejectsValueAndUnmappedOrigin() public {
        bytes memory m = this.encode(APP, payloads());
        vm.deal(address(endpoint), 1);
        vm.prank(address(endpoint));
        vm.expectRevert(LayerZeroOracle.UnexpectedValue.selector);
        lz.lzReceive{ value: 1 }(Origin(EID, SENDER, 1), bytes32(0), m, address(this), "");
        vm.prank(address(endpoint));
        vm.expectRevert(ChainMap.ZeroValue.selector);
        lz.lzReceive(Origin(999, SENDER, 1), bytes32(0), m, address(this), "");
        assertFalse(lz.allowInitializePath(Origin(999, SENDER, 1)));
        assertTrue(lz.allowInitializePath(Origin(EID, SENDER, 1)));
    }

    function testLayerZeroRejectsInvalidSecurity() public {
        LayerZeroOracle o = new LayerZeroOracle(address(this), address(endpoint));
        vm.expectRevert(LayerZeroOracle.InvalidConfiguration.selector);
        o.setChainMap(30601, 7, security(type(uint64).max, 1));
        vm.expectRevert(LayerZeroOracle.InvalidConfiguration.selector);
        o.setChainMap(30601, 7, security(1, type(uint64).max));
        vm.expectRevert(LayerZeroOracle.InvalidConfiguration.selector);
        o.setChainMap(30601, 7, security(0, 1));

        LayerZeroOracle.Security memory s = security(1, 1);
        s.maxMessageSize = 0;
        vm.expectRevert(LayerZeroOracle.InvalidConfiguration.selector);
        o.setChainMap(30601, 7, s);
        s = security(1, 1);
        s.executor = address(0);
        vm.expectRevert(LayerZeroOracle.InvalidConfiguration.selector);
        o.setChainMap(30601, 7, s);

        s = security(1, 1);
        address[] memory unsorted = new address[](2);
        unsorted[0] = address(0x2);
        unsorted[1] = address(0x1);
        s.receiveDvns = unsorted;
        vm.expectRevert(LayerZeroOracle.InvalidConfiguration.selector);
        o.setChainMap(30601, 7, s);
        s.receiveDvns = new address[](0);
        vm.expectRevert(LayerZeroOracle.InvalidConfiguration.selector);
        o.setChainMap(30601, 7, s);

        // A failed setter leaves the route unmapped.
        assertEq(o.chainIdMap(30601), 0);
        assertFalse(o.allowInitializePath(Origin(30601, SENDER, 1)));
    }

    function testPlainChainMapSetterDisabled() public {
        vm.expectRevert(LayerZeroOracle.SecurityRequired.selector);
        lz.setChainMap(30601, 1);
        vm.prank(address(0xBEEF));
        vm.expectRevert(LayerZeroOracle.SecurityRequired.selector);
        lz.setChainMap(30601, 1);
        assertEq(lz.chainIdMap(30601), 0);
    }

    function testEidMustFitUint32() public {
        vm.expectRevert(LayerZeroOracle.InvalidConfiguration.selector);
        lz.setChainMap(uint256(type(uint32).max) + 1, 1, security(1, 1));
        lz.setChainMap(type(uint32).max, 1, security(1, 1));
        assertEq(lz.chainIdMap(type(uint32).max), 1);
    }

    function testLayerZeroChainMapOwnerSetOnce() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBEEF)));
        lz.setChainMap(30601, 1, security(1, 1));
        vm.expectRevert(ChainMap.ZeroValue.selector);
        lz.setChainMap(0, 1, security(1, 1));
        vm.expectRevert(ChainMap.ZeroValue.selector);
        lz.setChainMap(30601, 0, security(1, 1));
        vm.expectRevert(ChainMap.AlreadySet.selector);
        lz.setChainMap(EID, 1, security(1, 1));
        vm.expectRevert(ChainMap.AlreadySet.selector);
        lz.setChainMap(30601, CHAIN, security(1, 1));

        assertFalse(lz.allowInitializePath(Origin(30601, SENDER, 1)));
        vm.expectEmit(address(lz));
        emit ChainMap.ChainMapConfigured(30601, 1);
        lz.setChainMap(30601, 1, security(1, 1));
        assertTrue(lz.allowInitializePath(Origin(30601, SENDER, 1)));
        assertEq(endpoint.configs(keccak256(abi.encode(address(lz), uint32(30601), "send"))), abi.encode(address(1)));
        assertEq(endpoint.configs(keccak256(abi.encode(address(lz), uint32(30601), "receive"))), abi.encode(address(2)));
        assertEq(
            endpoint.configs(keccak256(abi.encode(address(lz), address(1), uint32(30601), uint32(1)))),
            abi.encode(LayerZeroOracle.ExecutorConfig(2778, address(3)))
        );
        assertEq(lz.chainIdMap(30601), 1);
        assertEq(lz.reverseChainIdMap(1), 30601);

        for (uint32 i; i < 17; ++i) {
            lz.setChainMap(30700 + i, 2000 + i, security(1, 1));
        }
        assertEq(lz.chainIdMap(30716), 2016);

        lz.renounceOwnership();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        lz.setChainMap(30800, 3000, security(1, 1));
    }

    /// Receipt records batches beyond Stellar's limits; destinations enforce their own.
    function testLargeBatchAndTupleChecks() public {
        bytes[] memory p = new bytes[](5);
        for (uint256 i; i < 5; ++i) {
            p[i] = new bytes(700);
            p[i][0] = bytes1(uint8(i));
        }
        bytes memory m = this.encode(APP, p);
        Origin memory o = Origin(EID, SENDER, 1);
        endpoint.approve(address(lz), o, bytes32(0), m);
        endpoint.deliver(address(lz), o, bytes32(0), m);
        bytes memory proofs;
        for (uint256 i; i < 5; ++i) {
            proofs = bytes.concat(proofs, abi.encodePacked(CHAIN, SENDER, APP, keccak256(p[i])));
        }
        lz.efficientRequireProven(proofs);
        lz.efficientRequireProven("");
        vm.expectRevert();
        lz.efficientRequireProven(bytes.concat(proofs, hex"00"));
    }

    function testMalformedMessageReverts() public {
        bytes memory m = bytes.concat(this.encode(APP, payloads()), hex"00");
        Origin memory o = Origin(EID, SENDER, 1);
        endpoint.approve(address(lz), o, bytes32(0), m);
        vm.expectRevert();
        endpoint.deliver(address(lz), o, bytes32(0), m);
        assertTrue(endpoint.approvals(keccak256(abi.encode(address(lz), o, bytes32(0), m))));
    }
}
