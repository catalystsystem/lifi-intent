// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import { OracleAddress } from "../../../src/integrations/oracles/axelar/OracleAddress.sol";
import { MessageEncodingLib } from "../../../src/libs/MessageEncodingLib.sol";
import { AddressStrings } from "./AddressStrings.sol";
import { Test } from "forge-std/Test.sol";

contract OracleAddressTest is Test {
    bytes32 constant APP = keccak256("stellar settler");

    function encode(
        bytes32 application,
        bytes[] calldata p
    ) external pure returns (bytes memory) {
        return MessageEncodingLib.encodeMessage(application, p);
    }

    function decodeAddress(
        string calldata value
    ) external pure returns (bytes32) {
        return OracleAddress.decode(value);
    }

    function decode(
        bytes calldata b
    ) external pure returns (bytes32, bytes32[] memory) {
        return MessageEncodingLib.getHashesOfEncodedPayloads(b);
    }

    function testFuzzStellarAddressRoundtrip(
        bytes32 id
    ) public view {
        assertEq(this.decodeAddress(AddressStrings.stellar(id)), id);
    }

    function testFuzzSolanaAddressRoundtrip(
        bytes32 id
    ) public view {
        assertEq(this.decodeAddress(AddressStrings.solana(id)), id);
    }

    function testFuzzEvmAddress(
        address a
    ) public view {
        bytes32 id = bytes32(uint256(uint160(a)));
        assertEq(this.decodeAddress(vm.toString(a)), id);
        assertEq(this.decodeAddress(AddressStrings.evm(id)), id);
    }

    // Vectors generated with @solana/web3.js PublicKey.toBase58().
    function testSolanaAddressVectors() public {
        bytes32[6] memory ids = [
            bytes32(0),
            bytes32(uint256(1)),
            bytes32(0x00ababababababababababababababababababababababababababababababab),
            bytes32(type(uint256).max),
            bytes32(hex"0306466fe5211732ffecadba72c39be7bc8ce5bbc5f7126b2c439b3a40000000"),
            bytes32(hex"037d46d67c93fbbe12f9428f838d40ff0570744927f48a64fcca704480000000")
        ];
        string[6] memory strings = [
            "11111111111111111111111111111111",
            "11111111111111111111111111111112",
            "13cpvoZKJ28f1CDBboEmfEXMVVMcSQzBhTEMtecGWQ6v",
            "JEKNVnkbo3jma5nREBBJCDoXFVeKkD56V3xKrvRmWxFG",
            "ComputeBudget111111111111111111111111111111",
            "Ed25519SigVerify111111111111111111111111111"
        ];
        for (uint256 i; i < ids.length; ++i) {
            assertEq(AddressStrings.solana(ids[i]), strings[i]);
            assertEq(this.decodeAddress(strings[i]), ids[i]);
        }
        // 31 decoded bytes, 33 decoded bytes, a character outside the alphabet, and 45 characters.
        string[4] memory bad = [
            "4uQeVj5tqViQh7yWWGStvkEG1Zmhx6uasJtWCJziofL",
            "111111111111111111111111111111111",
            "0EKNVnkbo3jma5nREBBJCDoXFVeKkD56V3xKrvRmWxFG",
            "1JEKNVnkbo3jma5nREBBJCDoXFVeKkD56V3xKrvRmWxFG"
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert();
            this.decodeAddress(bad[i]);
        }
    }

    function testPublishedStrKeyAndBadChecksum() public {
        string memory zero = "CAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABSC4";
        assertEq(AddressStrings.stellar(bytes32(0)), zero);
        assertEq(this.decodeAddress(zero), bytes32(0));
        vm.expectRevert(OracleAddress.InvalidOracleAddress.selector);
        this.decodeAddress("CAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABSC5");
        vm.expectRevert(OracleAddress.InvalidOracleAddress.selector);
        this.decodeAddress("GAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAWHF");
    }

    function testMalformedShapesRejected() public {
        string[4] memory bad = [
            "",
            "0x000000000000000000000000000000000000000",
            "0x000000000000000000000000000000000000000g",
            "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        ];
        assertEq(bytes(bad[1]).length, 41);
        assertEq(bytes(bad[2]).length, 42);
        assertEq(bytes(bad[3]).length, 56);
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(OracleAddress.InvalidOracleAddress.selector);
            this.decodeAddress(bad[i]);
        }
    }

    function testTrailingMessageBytesRejected() public {
        bytes[] memory p = new bytes[](1);
        p[0] = hex"d1252dff012345";
        bytes memory m = bytes.concat(this.encode(APP, p), hex"00");
        vm.expectRevert();
        this.decode(m);
    }
}
