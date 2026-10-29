// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";

import { ChainlinkCCIPOracle } from "../src/integrations/oracles/chainlink/ChainlinkCCIPOracle.sol";

/// @notice Deploys a ChainlinkCCIPOracle without configuring chain maps.
/// Uses CREATE2 with salt zero, matching the other oracle deployment scripts.
/// The owner need not be the broadcasting account.
///
/// Usage (omit --broadcast for a dry run):
///   forge script script/ChainlinkCCIPOracle.s.sol:DeployChainlinkCCIPOracle \
///     --sig 'deploy(address,address)' <OWNER> <ROUTER> \
///     --rpc-url <RPC> --account deployer --broadcast
contract DeployChainlinkCCIPOracle is Script {
    function deploy(
        address owner,
        address router
    ) external returns (ChainlinkCCIPOracle oracle) {
        require(router.code.length != 0, "router has no code");

        vm.broadcast();
        oracle = new ChainlinkCCIPOracle{ salt: bytes32(0) }(owner, router);
    }
}
