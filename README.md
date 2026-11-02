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

### Axelar deployment

`script/AxelarOracle.s.sol:DeployAxelarOracle` deploys with CREATE2 (`salt = 0`), matching the
other oracle deployment scripts. Pass the mapping owner, local gateway, and local gas service
explicitly. The deployer can differ from the owner. Deployment does **not** configure any chain maps
and is not restricted to Base or Arbitrum.

Use verified provider addresses for the target network from
[Axelar's mainnet contract reference](https://docs.axelar.dev/dev/reference/mainnet-contract-addresses/).
On Base (8453) and Arbitrum (42161), both providers currently use the addresses in this example:

```shell
OWNER=0x712E90032d8f44bE276A903E1769d64dD1C7F45a
GATEWAY=0xe432150cce91c13a887f7D836923d5597adD8E31
GAS_SERVICE=0x2d5d7d31F671F86C782533cc367F14109a082712
RPC=https://arb1.arbitrum.io/rpc

# Verify the target network and provider code before signing.
cast chain-id --rpc-url "$RPC"
cast code "$GATEWAY" --rpc-url "$RPC"
cast code "$GAS_SERVICE" --rpc-url "$RPC"

# Dry run; no transactions are sent.
forge script script/AxelarOracle.s.sol:DeployAxelarOracle \
  --sig 'deploy(address,address,address)' "$OWNER" "$GATEWAY" "$GAS_SERVICE" \
  --rpc-url "$RPC" --account deployer

# Deployment only; the deployer signs, not necessarily OWNER.
forge script script/AxelarOracle.s.sol:DeployAxelarOracle \
  --sig 'deploy(address,address,address)' "$OWNER" "$GATEWAY" "$GAS_SERVICE" \
  --rpc-url "$RPC" --account deployer --broadcast
```

Set `ORACLE` to the returned deployed address. Verify `owner()(address)`, `gateway()(address)`,
and `gasService()(address)` with `cast call`. CREATE2 prediction depends on the factory, salt,
bytecode, and all constructor arguments, not the sender's nonce. Fund the deployer above Forge's
estimated transaction cost, with headroom for fee changes; a dry run does not prove sufficient funds.

#### Separate chain-map configuration

`script/AxelarChainMap.s.sol:ConfigureAxelarChainMap` configures one route per invocation.
The signing account must control the oracle's owner. Stored lookup names must be lowercase with no
NUL and satisfy Axelar's `ChainNameRaw` rule: 1–20 ASCII bytes, no `_`. These are internal keys,
not the outbound spelling: register `ethereum` for Axelar's `Ethereum`. The script packs the name with
`AxelarStrings.chainKey` and refuses, before broadcasting, any name whose packed key differs from its raw bytes,
such as `Base`; the oracle's setter rejects names that are too long, non-ASCII or contain `_`, which Forge's
simulation also catches before broadcasting. Names and canonical OIF chain IDs are set-once. Repeated
configuration reverts rather than overwriting a route.

```shell
# Example: configure the Base route on an Arbitrum oracle. Dry-run first.
forge script script/AxelarChainMap.s.sol:ConfigureAxelarChainMap \
  --sig 'setChainMap(address,string,uint256)' "$ORACLE" base 8453 \
  --rpc-url "$RPC" --account owner

# Only after checking the route and signing account:
forge script script/AxelarChainMap.s.sol:ConfigureAxelarChainMap \
  --sig 'setChainMap(address,string,uint256)' "$ORACLE" base 8453 \
  --rpc-url "$RPC" --account owner --broadcast

cast call "$ORACLE" 'reverseChainIdMap(uint256)(bytes32)' 8453 --rpc-url "$RPC"
# Expected: $(cast --format-bytes32-string base), the lowercase name packed left-aligned.
```

The sibling [`intents-oracle-owner`](../../intents-oracle-owner/README.md) repository keeps its
ceremony owner keys in GitHub Actions, separately from deployment. Use the target chain's
`expectedOwner` from its reviewed configuration when that owner is intended; the example above uses
its current Base/Arbitrum owner. Axelar uses the numeric `setChainMap(uint256,uint256)` that its
reconciler already supports. The key is `uint256(bytes32(bytes(lowercaseName)))`; the oracle
rejects keys that are not packed lowercase names. The local configuration script is for owners
with an available signer; it does not access GitHub-held keys.

Route checks confirm configuration, not live GMP delivery. `submit` takes the exact Axelar
destination-chain string, not a numeric OIF chain ID. It lowercases the name only to check that its
mapping exists, then sends the original string unchanged to both the gas service and gateway.
For example, pass `Ethereum` with a configured `ethereum` lookup key. Callers must obtain the exact
registered spelling from Axelar; the lookup does not enforce that spelling. An incorrect spelling
can waste the delivery fee, but does not consume the source attestations.
The destination oracle's Axelar address string (EVM `0x…`, Stellar `C…` StrKey, Solana base58)
is also passed through unchecked. Use a nonzero `destinationConfig` only for Solana destinations;
it selects the Borsh envelope. Clients split batches to meet the destination's limits: Stellar
allows 1–4 payloads of ≤684 bytes, and Solana allows one payload of ≤320 bytes. Relayed delivery
requires a positive, off-chain-estimated native gas payment. Self-relay uses zero value and still
requires gateway approval before `execute`.

The ABI is `submit(string,string,address,bytes[],bytes32,uint8)`; there is no numeric-ID overload.
Callers must supply Axelar's exact name instead of the OIF chain ID. Inbound `execute` is unchanged:
it normalizes only for lookup and validates the original source strings with the gateway.
This change requires a new oracle deployment; existing immutable deployments retain the old ABI.

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
