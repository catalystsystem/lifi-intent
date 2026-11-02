// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";

import { AxelarOracle } from "../src/integrations/oracles/axelar/AxelarOracle.sol";
import { AxelarStrings } from "../src/integrations/oracles/axelar/AxelarStrings.sol";

/// @notice Configures one permanent Axelar route; broadcast with the oracle's owner.
/// Mapping names are lowercase lookup keys: 1–20 ASCII bytes, no NUL or `_`. Register `ethereum` for `Ethereum`;
/// submit callers supply Axelar's exact outbound spelling separately. The script rejects uppercase and malformed
/// packing; the oracle's setter enforces the remaining format rules during Forge's pre-broadcast simulation.
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
        // chainKey() checks the packing bounds (1–32 bytes) and NUL bytes; comparing with the raw packing
        // additionally requires the input to already be canonical lowercase, so the stored key reads back as exactly
        // the name given. The setter adds Axelar's 20-byte, ASCII-only, no-`_` rule.
        uint256 packed = AxelarStrings.chainKey(name);
        if (packed != uint256(bytes32(bytes(name)))) revert AxelarStrings.InvalidChainName();

        vm.broadcast();
        AxelarOracle(oracle).setChainMap(packed, chainId);
    }
}
