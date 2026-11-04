// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.26;

import { ChainlinkCCIPOracle } from "OIF/src/integrations/oracles/chainlink/ChainlinkCCIPOracle.sol";
import { console } from "forge-std/console.sol";

import { multichain } from "./multichain.s.sol";

/// @notice Deploys ChainlinkCCIPOracle with CREATE2 salt 0 on every listed chain from `script/ccip.json`.
/// Sets no chain maps: mainnet oracles are owned by intents-oracle-owner, which sets every map.
/// Re-running is safe: chains where the oracle already exists are skipped.
contract deployCCIP is multichain {
    error WrongChain(string chain, uint256 expected, uint256 actual);
    error NoCode(string chain, address target);

    string private constant CCIP_CONFIG = "/script/ccip.json";

    function run(
        string[] calldata chains,
        address initialOwner
    ) public iter_chains(chains) broadcast returns (ChainlinkCCIPOracle oracle) {
        string memory activeChain = getChain();
        string memory config = vm.readFile(string.concat(vm.projectRoot(), CCIP_CONFIG));
        string memory prefix = string.concat(".implementation.", activeChain);

        uint256 expectedChainId = vm.parseJsonUint(config, string.concat(prefix, ".chainId"));
        if (block.chainid != expectedChainId) revert WrongChain(activeChain, expectedChainId, block.chainid);
        address router = vm.parseJsonAddress(config, string.concat(prefix, ".router"));
        if (router.code.length == 0) revert NoCode(activeChain, router);

        address expected =
            getExpectedCreate2Address(0, type(ChainlinkCCIPOracle).creationCode, abi.encode(initialOwner, router));
        if (expected.code.length != 0) {
            console.log("%s: ChainlinkCCIPOracle already deployed at %s", activeChain, expected);
            return ChainlinkCCIPOracle(expected);
        }
        oracle = new ChainlinkCCIPOracle{ salt: 0 }(initialOwner, router);
        console.log("%s: ChainlinkCCIPOracle deployed at %s", activeChain, address(oracle));
    }
}
