// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

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
