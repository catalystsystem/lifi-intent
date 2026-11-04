// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.26;

import { AxelarOracle } from "OIF/src/integrations/oracles/axelar/AxelarOracle.sol";
import { console } from "forge-std/console.sol";

import { multichain } from "./multichain.s.sol";

/// @notice Deploys AxelarOracle with CREATE2 salt 0 on every listed chain from `script/axelar.json`.
/// Sets no chain maps: mainnet oracles are owned by intents-oracle-owner, which sets every map.
/// Re-running is safe: chains where the oracle already exists are skipped.
contract deployAxelar is multichain {
    error WrongChain(string chain, uint256 expected, uint256 actual);
    error NoCode(string chain, address target);

    string private constant AXELAR_CONFIG = "/script/axelar.json";

    function run(
        string[] calldata chains,
        address initialOwner
    ) public iter_chains(chains) broadcast returns (AxelarOracle oracle) {
        string memory activeChain = getChain();
        string memory config = vm.readFile(string.concat(vm.projectRoot(), AXELAR_CONFIG));
        string memory prefix = string.concat(".implementation.", activeChain);

        uint256 expectedChainId = vm.parseJsonUint(config, string.concat(prefix, ".chainId"));
        if (block.chainid != expectedChainId) revert WrongChain(activeChain, expectedChainId, block.chainid);
        address gateway = vm.parseJsonAddress(config, string.concat(prefix, ".gateway"));
        address gasService = vm.parseJsonAddress(config, string.concat(prefix, ".gasService"));
        if (gateway.code.length == 0) revert NoCode(activeChain, gateway);
        if (gasService.code.length == 0) revert NoCode(activeChain, gasService);

        address expected = getExpectedCreate2Address(
            0, type(AxelarOracle).creationCode, abi.encode(initialOwner, gateway, gasService)
        );
        if (expected.code.length != 0) {
            console.log("%s: AxelarOracle already deployed at %s", activeChain, expected);
            return AxelarOracle(expected);
        }
        oracle = new AxelarOracle{ salt: 0 }(initialOwner, gateway, gasService);
        console.log("%s: AxelarOracle deployed at %s", activeChain, address(oracle));
    }
}
