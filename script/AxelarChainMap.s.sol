// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";

import { AxelarOracle } from "../src/integrations/oracles/axelar/AxelarOracle.sol";
import { OracleAddress } from "../src/integrations/oracles/common/OracleAddress.sol";

/// @notice Configures one permanent Axelar route; broadcast with the oracle's owner.
/// Kind: Evm = 0, Stellar = 1, Solana = 2. Names must be lowercase Axelar chain names.
///
/// Usage (omit --broadcast for a dry run):
///   forge script script/AxelarChainMap.s.sol:ConfigureAxelarChainMap \
///     --sig 'setChainMap(address,string,uint256,uint8)' <ORACLE> <NAME> <CHAIN_ID> <KIND> \
///     --rpc-url <RPC> --account owner --broadcast
contract ConfigureAxelarChainMap is Script {
    function setChainMap(
        address oracle,
        string calldata name,
        uint256 chainId,
        OracleAddress.Kind kind
    ) external {
        vm.broadcast();
        AxelarOracle(oracle).setChainMap(name, chainId, kind);
    }
}
