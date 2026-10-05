// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Ownable } from "openzeppelin/access/Ownable.sol";

import { BoundedOracle } from "./BoundedOracle.sol";

/// Bounded transport oracle with owner-added, set-once, bijective route-key -> OIF chain maps.
abstract contract MappedOracle is BoundedOracle, Ownable {
    error AlreadySet();
    error ZeroValue();

    mapping(bytes32 routeKey => uint256 chainId) internal _chainIds;
    mapping(uint256 chainId => bytes32 routeKey) public reverseChainIdMap;

    constructor(
        address owner_
    ) Ownable(owner_) { }

    /// Map a nonzero route key to a nonzero OIF chain. Each key and chain ID is set once.
    function _setRoute(
        bytes32 key,
        uint256 chainId
    ) internal {
        if (chainId == 0) revert ZeroValue();
        if (_chainIds[key] != 0 || reverseChainIdMap[chainId] != 0) revert AlreadySet();
        _chainIds[key] = chainId;
        reverseChainIdMap[chainId] = key;
    }

    function _chainId(
        bytes32 key
    ) internal view returns (uint256 chainId) {
        chainId = _chainIds[key];
        if (chainId == 0) revert UnknownChain();
    }
}
