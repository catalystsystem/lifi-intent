// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import { AxelarOracle } from "../../../src/integrations/oracles/axelar/AxelarOracle.sol";
import {
    LayerZeroOracle,
    MessagingFee,
    MessagingParams,
    MessagingReceipt,
    Origin,
    SetConfigParam
} from "../../../src/integrations/oracles/layerzero/LayerZeroOracle.sol";

/// Test-only verification boundary. Approvals bind every provider-authenticated field and are consumed atomically.
contract GatewayFixture {
    mapping(bytes32 => bool) public approvals;
    bytes public lastMessage;
    string public lastDestination;
    string public lastChain;
    string public lastGasChain;
    address public lastSender;
    address public lastRefund;
    uint256 public paid;

    function approve(
        bytes32 command,
        string memory chain,
        string memory sender,
        address receiver,
        bytes memory payload
    ) external {
        approvals[keccak256(abi.encode(command, chain, sender, receiver, keccak256(payload)))] = true;
    }

    function validateContractCall(
        bytes32 command,
        string calldata chain,
        string calldata sender,
        bytes32 hash
    ) external returns (bool) {
        bytes32 k = keccak256(abi.encode(command, chain, sender, msg.sender, hash));
        bool valid = approvals[k];
        delete approvals[k];
        return valid;
    }

    function callContract(
        string calldata chain,
        string calldata destination,
        bytes calldata payload
    ) external {
        lastMessage = payload;
        lastChain = chain;
        lastDestination = destination;
        lastSender = msg.sender;
    }

    function payNativeGasForContractCall(
        address,
        string calldata chain,
        string calldata,
        bytes calldata,
        address refund
    ) external payable {
        paid += msg.value;
        lastGasChain = chain;
        lastRefund = refund;
    }
}

contract EndpointFixture {
    mapping(bytes32 => bool) public approvals;
    mapping(bytes32 => bytes) public configs;
    bytes public lastMessage;
    bytes32 public lastRecipient;
    address public lastSender;
    uint64 public nonce;

    function setSendLibrary(
        address oapp,
        uint32 eid,
        address lib
    ) external {
        require(msg.sender == oapp);
        configs[keccak256(abi.encode(oapp, eid, "send"))] = abi.encode(lib);
    }

    function setReceiveLibrary(
        address oapp,
        uint32 eid,
        address lib,
        uint256 grace
    ) external {
        require(msg.sender == oapp && grace == 0);
        configs[keccak256(abi.encode(oapp, eid, "receive"))] = abi.encode(lib);
    }

    function setConfig(
        address oapp,
        address lib,
        SetConfigParam[] calldata params
    ) external {
        require(msg.sender == oapp);
        for (uint256 i; i < params.length; ++i) {
            configs[keccak256(abi.encode(oapp, lib, params[i].eid, params[i].configType))] = params[i].config;
        }
    }

    function quote(
        MessagingParams calldata,
        address
    ) external pure returns (MessagingFee memory) {
        return MessagingFee(10, 0);
    }

    function send(
        MessagingParams calldata p,
        address refund
    ) external payable returns (MessagingReceipt memory) {
        require(msg.value >= 10 && !p.payInLzToken);
        lastMessage = p.message;
        lastRecipient = p.receiver;
        lastSender = msg.sender;
        if (msg.value > 10) {
            (bool ok,) = refund.call{ value: msg.value - 10 }("");
            require(ok);
        }
        return MessagingReceipt(keccak256(abi.encode(msg.sender, ++nonce, p)), nonce, MessagingFee(10, 0));
    }

    function approve(
        address receiver,
        Origin memory origin,
        bytes32 guid,
        bytes memory message
    ) external {
        require(LayerZeroOracle(receiver).allowInitializePath(origin));
        approvals[keccak256(abi.encode(receiver, origin, guid, message))] = true;
    }

    function deliver(
        address receiver,
        Origin memory origin,
        bytes32 guid,
        bytes memory message
    ) external {
        bytes32 key = keccak256(abi.encode(receiver, origin, guid, message));
        require(approvals[key], "unverified");
        delete approvals[key];
        LayerZeroOracle(receiver).lzReceive(origin, guid, message, msg.sender, "");
    }
}
