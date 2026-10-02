// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.22;

import { WormholeOracle } from "OIF/src/integrations/oracles/wormhole/WormholeOracle.sol";
import { ChainMap } from "OIF/src/oracles/ChainMap.sol";
import { console } from "forge-std/console.sol";

import { multichain } from "./multichain.s.sol";

contract deployWormhole is multichain {
    error NotExpectedAddress(string name, address expected, address actual);

    string private constant WORMHOLE_CONFIG = "/script/wormhole.json";

    function run(
        string[] calldata chains
    ) public returns (WormholeOracle oracle) {
        return run(chains, getSender());
    }

    function run(
        string[] calldata chains,
        address initialOwner
    ) public iter_chains(chains) broadcast returns (WormholeOracle oracle) {
        string memory activeChain = getChain();
        // Load wormhole config.
        string memory pathRoot = vm.projectRoot();
        string memory pathToWormholeConfig = string(abi.encodePacked(pathRoot, WORMHOLE_CONFIG));
        string memory wormholeConfig = vm.readFile(pathToWormholeConfig);

        address wormholeImplementation =
            vm.parseJsonAddress(wormholeConfig, string.concat(".implementation.", activeChain, ".wormhole"));

        // Deploy the Wormhole Oracle.
        oracle = deployWormholeOracle(initialOwner, wormholeImplementation);
        vm.writeJson(
            vm.toString(address(oracle)),
            pathToWormholeConfig,
            string.concat(".implementation.", activeChain, ".oracle")
        );

        // Mainnet oracles are owned by intents-oracle-owner, which sets every chain map. Only the deployer-owned
        // (testnet) oracles get their maps from `.chainids`. Read the wallet directly: `getSender()` would nest
        // `startBroadcast` inside this `broadcast` block.
        address oracleOwner = oracle.owner();
        if (oracleOwner != vm.getWallets()[0]) {
            console.log("chain maps skipped: owner %s is managed by intents-oracle-owner", oracleOwner);
            return oracle;
        }

        bytes memory chainIdData = vm.parseJson(wormholeConfig, ".chainids");
        uint256[][] memory chainIdArray = abi.decode(chainIdData, (uint256[][]));
        for (uint256 i = 0; i < chainIdArray.length; i++) {
            assert(chainIdArray[i].length == 2);
            uint256 chainId = chainIdArray[i][0];
            uint16 messagingProtocolChainIdentifier = uint16(chainIdArray[i][1]);
            // Set the chain map for the Wormhole Oracle.
            setWormholeConfig(oracle, messagingProtocolChainIdentifier, chainId);
        }
    }

    function deployWormholeOracle(
        address initialOwner,
        address wormholeImplementation
    ) internal returns (WormholeOracle oracle) {
        address expectedAddress = getExpectedCreate2Address(
            0, // salt
            type(WormholeOracle).creationCode,
            abi.encode(initialOwner, wormholeImplementation)
        );
        bool isOracleDeployed = address(expectedAddress).code.length != 0;

        if (!isOracleDeployed) return new WormholeOracle{ salt: 0 }(initialOwner, wormholeImplementation);
        return WormholeOracle(expectedAddress);
    }

    function setWormholeConfig(
        WormholeOracle oracle,
        uint16 messagingProtocolChainIdentifier,
        uint256 chainId
    ) internal {
        // Check if map has already been set.
        uint256 storedBlockChainid = oracle.chainIdMap(messagingProtocolChainIdentifier);
        uint256 storedChainIdentifier = oracle.reverseChainIdMap(chainId);
        if (storedBlockChainid != 0 || storedChainIdentifier != 0) {
            // Check whether the maps has been set to the expected values:
            if (storedBlockChainid == chainId && storedChainIdentifier == messagingProtocolChainIdentifier) {
                // Then skip.
                return;
            }
            revert ChainMap.AlreadySet();
        }
        // Set the map.
        oracle.setChainMap(messagingProtocolChainIdentifier, chainId);
    }
}
