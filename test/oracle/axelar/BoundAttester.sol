// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

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
