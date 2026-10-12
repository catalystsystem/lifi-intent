// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { AxelarOracle } from "../src/integrations/oracles/axelar/AxelarOracle.sol";
import { OracleAddress } from "../src/integrations/oracles/common/OracleAddress.sol";

/// @notice Deploys an AxelarOracle on Base and maps Axelar's `stellar` chain to LI.FI's Stellar chain ID.
/// The map is permanent and is set only when `owner` is the broadcasting account.
///
/// Usage:
///   forge script script/AxelarOracle.s.sol:DeployAxelarOracle --sig 'run(address)' <OWNER> \
///     --rpc-url https://mainnet.base.org --ledger --sender <OWNER> --broadcast
contract DeployAxelarOracle is Script {
    address constant GATEWAY = 0xe432150cce91c13a887f7D836923d5597adD8E31;
    address constant GAS_SERVICE = 0x2d5d7d31F671F86C782533cc367F14109a082712;
    uint256 constant STELLAR_CHAIN_ID = 1201081091099710;

    function run(
        address owner
    ) external returns (AxelarOracle oracle) {
        require(block.chainid == 8453, "not Base");

        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        oracle = new AxelarOracle(owner, GATEWAY, GAS_SERVICE);
        if (sender == owner) oracle.setChainMap("stellar", STELLAR_CHAIN_ID, OracleAddress.Kind.Stellar);
        vm.stopBroadcast();

        console.log("AxelarOracle", address(oracle));
        if (sender != owner) console.log("Owner must still call setChainMap(\"stellar\", 1201081091099710, 1)");
    }
}
