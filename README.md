# LI.FI Intent based cross-chain swaps

LI.FI Intent is a cross-chain swap protocol built with the Open Intents Framework, OIF. It allows users to sign intents: What asset they want, how they want etc, etc. which is claimed and then delivered by solvers.

## Deployments

Deployed addresses:
- Compact Address: `0x00000000000000171ede64904551eeDF3C6C9788`
- Input Settler Compact Address: `0x0000000000cd5f7fDEc90a03a31F79E5Fbc6A9Cf`
- Input Settler Escrow Address: `0x000025c3226C00B2Cdc200005a1600509f4e00C0`
- Output Settler Address: `0x0000000000eC36B683C2E6AC89e9A75989C22a2e`
- Polymer Oracle Testnet: `0x00d5b500ECa100F7cdeDC800eC631Aca00BaAC00`
- Polymer Oracle Mainnet: `0x0000006ea400569c0040d6e5ba651c00848409be`

### Open Intents Framework

The OIF is a reference implementation of a modular and composable intent system. LI.FI intent is built as an implementation of it, meaning it is compatible and compliments any other OIF deployment.

For more documentation about the OIF: https://github.com/openintentsframework/oif-contracts

## Integration

By integrating LI.FI intents, either as a solver or as an intent issuer, you will also be integrating with the OIF: https://docs.li.fi/lifi-intents/introduction. 

## Usage

### Build

```shell
forge build [--sizes]
```

### Test

```shell
forge test [--fuzz-runs 10000] [--gas-report --fuzz-seed 10]
```

#### Gas report
```shell
forge test --gas-report
```

### Coverage

```shell
forge coverage --no-match-coverage "(script|test|wormhole/external/wormhole|wormhole/external/callworm/GettersGetter)" [--report lcov]
```

### Deploy

```shell
forge script deploy --sig "run(string[])" "[<chains>]" --account <account> --slow --multi --isolate --always-use-create-2-factory --verify --broadcast [-vvvv]
```

### Chainlink CCIP deployment

`script/ChainlinkCCIPOracle.s.sol:DeployChainlinkCCIPOracle` deploys with CREATE2 (`salt = 0`).
Pass the mapping owner and the target chain's CCIP router from the
[CCIP directory](https://docs.chain.link/ccip/directory). The script rejects routers without code;
code presence alone does not establish that the address is the official router.
The deployer may differ from the owner. No chain maps are configured during deployment.

```shell
# Dry-run first; append --broadcast to deploy.
forge script script/ChainlinkCCIPOracle.s.sol:DeployChainlinkCCIPOracle \
  --sig 'deploy(address,address)' "$OWNER" "$ROUTER" \
  --rpc-url "$RPC" --account deployer

# Set ORACLE to the returned address after broadcasting.
cast call "$ORACLE" 'owner()(address)' --rpc-url "$RPC"
cast call "$ORACLE" 'getRouter()(address)' --rpc-url "$RPC"
```

CREATE2 predictions depend on the factory, salt, bytecode, owner, and router, not the deployer's nonce.
The owner must configure CCIP selector → canonical chain-ID mappings separately before receiving
proofs from those chains. Entries are set-once and cannot be corrected after signing.
The sibling `intents-oracle-owner` reconciler supports this oracle's existing
`setChainMap(uint256,uint256)` interface; deploy directly to the target chain's reviewed
`expectedOwner` when using that automation, then register the deployment separately.
Deployment checks do not prove live CCIP delivery.

## License Notice

This project is licensed under the **[GNU Lesser General Public License v3.0 only (LGPL-3.0-only)](/LICENSE)**.

It also uses the following third-party libraries:

- **[OIF](https://github.com/openintentsframework/oif-contracts)** – vendored in-tree, licensed under the [MIT License](/LICENSE-MIT) (Copyright (c) 2025 openintentsframework)
- **[Solady](https://github.com/Vectorized/solady)** – Licensed under the [MIT License](https://opensource.org/licenses/MIT)

Each library is included under the terms of its respective license. Copies of the license texts can be found in their source files or original repositories.

When distributing this project, please ensure that all relevant license notices are preserved in accordance with their terms.
