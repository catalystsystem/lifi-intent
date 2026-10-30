// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";

import { AxelarOracle } from "../src/integrations/oracles/axelar/AxelarOracle.sol";
import { AxelarStrings } from "../src/integrations/oracles/axelar/AxelarStrings.sol";

/// @notice Configures one permanent Axelar route; broadcast with the oracle's owner.
/// Register the exact canonical Axelar chain name, including case: 1–20 ASCII bytes without NUL or `_`.
/// The owner must verify the spelling; no case conversion is performed. The oracle enforces the length and
/// character rules, and Forge simulates that call before broadcasting.
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
        // Pack the exact name, checking the 1–32-byte bound and NUL bytes.
        // The setter adds Axelar's 20-byte, ASCII-only, no-`_` rule.
        uint256 packed = AxelarStrings.chainKey(name);

        vm.broadcast();
        AxelarOracle(oracle).setChainMap(packed, chainId);
    }
}
