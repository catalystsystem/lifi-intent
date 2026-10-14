// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";

import { AxelarOracle } from "../src/integrations/oracles/axelar/AxelarOracle.sol";
import { AxelarStrings } from "../src/integrations/oracles/axelar/AxelarStrings.sol";

/// @notice Configures one permanent Axelar route; broadcast with the oracle's owner.
/// Names must be canonical Axelar chain names: 1–32 bytes, no NUL, already lowercase. The script rejects anything
/// else before broadcasting, so a mis-cased or malformed name never reaches the permanent map.
///
/// Usage (omit --broadcast for a dry run):
///   forge script script/AxelarChainMap.s.sol:ConfigureAxelarChainMap \
///     --sig 'setChainMap(address,string,uint256)' <ORACLE> <NAME> <CHAIN_ID> \
///     --rpc-url <RPC> --account owner --broadcast
contract ConfigureAxelarChainMap is Script {
    function setChainMap(
        address oracle,
        string calldata name,
        uint256 chainId
    ) external {
        // key() checks the length (1–32 bytes) and NUL bytes; comparing with the raw packing additionally requires
        // the input to already be canonical lowercase, so the stored key reads back as exactly the name given.
        uint256 packed = AxelarStrings.chainKey(name);
        if (packed != uint256(bytes32(bytes(name)))) revert AxelarStrings.InvalidChainName();

        vm.broadcast();
        AxelarOracle(oracle).setChainMap(packed, chainId);
    }
}
