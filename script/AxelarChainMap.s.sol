// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";

import { AxelarOracle } from "../src/integrations/oracles/axelar/AxelarOracle.sol";

/// @notice Configures one permanent Axelar route; broadcast with the oracle's owner.
/// Names must be lowercase Axelar chain names; the oracle rejects anything else.
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
        vm.broadcast();
        AxelarOracle(oracle).setChainMap(uint256(bytes32(bytes(name))), chainId);
    }
}
