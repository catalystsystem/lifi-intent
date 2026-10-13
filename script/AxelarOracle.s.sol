// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";

import { AxelarOracle } from "../src/integrations/oracles/axelar/AxelarOracle.sol";

/// @notice Deploys an AxelarOracle without configuring chain maps.
/// Uses CREATE2 with salt zero, matching the other oracle deployment scripts.
/// The owner need not be the broadcasting account.
///
/// Usage (omit --broadcast for a dry run):
///   forge script script/AxelarOracle.s.sol:DeployAxelarOracle \
///     --sig 'deploy(address,address,address)' <OWNER> <GATEWAY> <GAS_SERVICE> \
///     --rpc-url <RPC> --account deployer --broadcast
contract DeployAxelarOracle is Script {
    function deploy(
        address owner,
        address gateway,
        address gasService
    ) external returns (AxelarOracle oracle) {
        vm.broadcast();
        oracle = new AxelarOracle{ salt: bytes32(0) }(owner, gateway, gasService);
    }
}
