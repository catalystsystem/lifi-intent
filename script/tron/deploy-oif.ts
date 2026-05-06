/**
 * Deploy OIF contracts to Tron.
 *
 * Mirrors the Forge deploy.s.sol / polymer.s.sol but uses TronWeb instead of CREATE2.
 * Deploy order: InputSettlerEscrowLIFITron -> OutputSettlerSimple -> PolymerOracle
 *
 * Prerequisites:
 *   1. `FOUNDRY_PROFILE=tron forge build --skip 'the-compact' --skip 'InputSettlerCompact' --skip 'RegisterIntent' --skip test --skip 'deploy.s' --skip 'polymer.s' --skip 'wormhole.s' --skip 'multichain.s' --skip 'orderId.s'`
 *   2. Set environment variables:
 *      - PRIVATE_KEY (deployer private key) - can also be passed as --private-key <key>
 *      - RPC_URL_TRON (optional, defaults to https://api.trongrid.io)
 *      - TRONGRID_API_KEY (optional)
 *
 * Usage:
 *   bun run script/tron/deploy-oif.ts [--dry-run] [--testnet|--network tronshasta] [--private-key 0x...] [--rpc-url <url>] [--trongrid-api-key <key>]
 *
 * Required constructor args:
 *   --owner <address>           Initial owner for InputSettlerEscrowLIFITron (defaults to deployer)
 *   --polymer-prover <address>  Polymer CrossL2Prover address on Tron
 *
 * Deploy only selected contracts (canonical order is always preserved):
 *   --step InputSettler
 *   --step OutputSettler
 *   --step PolymerOracle
 *   --step 1   (same as InputSettler; 2 = OutputSettler, 3 = PolymerOracle)
 *   Repeat --step to deploy a subset, e.g. --step 1 --step 3
 */

import { readFile } from 'fs/promises'
import { resolve } from 'path'

import { consola } from 'consola'

import {
  TronContractDeployer,
  tronScanTransactionUrl,
  tronAddressToHex,
  createTronWeb,
  getPrivateKey,
  getTronRpcUrl,
  getTronGridAPIKey,
  TRON_PRO_API_KEY_HEADER,
  promptEnergyRentalReminder,
  type IForgeArtifact,
  type ITronDeploymentConfig,
  type ITronDeploymentResult,
  type TronTvmNetworkName,
} from '@lifi/tron-devkit'

// ── Configuration ──────────────────────────────────────────────────────────────

const ARTIFACTS_DIR = resolve(import.meta.dir, '../../out')
const DEPLOYMENTS_FILE = resolve(
  import.meta.dir,
  '../../deployments/tron.json'
)

async function loadTronArtifact(
  contractName: string,
  sourceFile: string
): Promise<IForgeArtifact> {
  const artifactPath = resolve(
    ARTIFACTS_DIR,
    `${sourceFile}.sol/${contractName}.json`
  )
  const artifact = JSON.parse(await readFile(artifactPath, 'utf-8'))
  if (!artifact.abi || !artifact.bytecode?.object)
    throw new Error(
      `Invalid artifact for ${contractName}: missing ABI or bytecode`
    )
  consola.info(`Loaded ${contractName} from: ${artifactPath}`)
  return artifact
}

/** Contracts to deploy in order. */
const CONTRACTS_TO_DEPLOY = [
  'InputSettler',
  'OutputSettler',
  'PolymerOracle',
] as const

type DeployStepName = (typeof CONTRACTS_TO_DEPLOY)[number]

const TRON_CONTRACT: Record<
  DeployStepName,
  { contractName: string; sourceFile: string }
> = {
  InputSettler: {
    contractName: 'InputSettlerEscrowLIFITron',
    sourceFile: 'InputSettlerEscrowLIFI.tron',
  },
  OutputSettler: {
    contractName: 'OutputSettlerSimple',
    sourceFile: 'OutputSettlerSimple',
  },
  PolymerOracle: {
    contractName: 'PolymerOracle',
    sourceFile: 'PolymerOracle',
  },
}

type ConstructorArgs = Record<DeployStepName, () => unknown[]>

function resolveStepArg(raw: string): DeployStepName {
  if (/^\d+$/.test(raw)) {
    const n = Number.parseInt(raw, 10)
    if (n < 1 || n > CONTRACTS_TO_DEPLOY.length) {
      consola.error(
        `--step index must be between 1 and ${CONTRACTS_TO_DEPLOY.length} (${CONTRACTS_TO_DEPLOY.join(' → ')})`
      )
      process.exit(1)
    }
    return CONTRACTS_TO_DEPLOY[n - 1]!
  }
  const match = CONTRACTS_TO_DEPLOY.find(
    (c) => c.toLowerCase() === raw.toLowerCase()
  )
  if (!match) {
    consola.error(
      `Unknown --step "${raw}". Use: ${CONTRACTS_TO_DEPLOY.join(', ')}, or 1–${CONTRACTS_TO_DEPLOY.length}`
    )
    process.exit(1)
  }
  return match
}

function parseStepFlags(args: string[]): DeployStepName[] | undefined {
  const steps: DeployStepName[] = []
  for (let i = 0; i < args.length; i++) {
    if (args[i] !== '--step') continue
    const raw = args[i + 1]
    if (!raw || raw.startsWith('--')) {
      consola.error('--step requires a contract name or index (1–3)')
      process.exit(1)
    }
    steps.push(resolveStepArg(raw))
    i++
  }
  if (steps.length === 0) return undefined
  const selected = new Set(steps)
  return CONTRACTS_TO_DEPLOY.filter((c) => selected.has(c))
}

// ── CLI argument parsing ───────────────────────────────────────────────────────

function getFlagValue(args: string[], flag: string): string | undefined {
  const idx = args.indexOf(flag)
  return idx >= 0 ? args[idx + 1] : undefined
}

function parseArgs(): {
  dryRun: boolean
  network: TronTvmNetworkName
  privateKey?: string
  rpcUrl?: string
  trongridApiKey?: string
  owner?: string
  polymerProver?: string
  steps?: DeployStepName[]
} {
  const args = process.argv.slice(2)
  const dryRun = args.includes('--dry-run')
  const testnet = args.includes('--testnet')
  const networkArg = getFlagValue(args, '--network')
  const network: TronTvmNetworkName =
    testnet || networkArg === 'tronshasta' ? 'tronshasta' : 'tron'
  const privateKey = getFlagValue(args, '--private-key')
  const rpcUrl = getFlagValue(args, '--rpc-url')
  const trongridApiKey = getFlagValue(args, '--trongrid-api-key')
  const owner = getFlagValue(args, '--owner')
  const polymerProver = getFlagValue(args, '--polymer-prover')
  const steps = parseStepFlags(args)
  return { dryRun, network, privateKey, rpcUrl, trongridApiKey, owner, polymerProver, steps }
}

// ── Deployment persistence ─────────────────────────────────────────────────────

async function loadDeployments(): Promise<Record<string, string>> {
  try {
    return await Bun.file(DEPLOYMENTS_FILE).json()
  } catch {
    return {}
  }
}

async function saveDeployments(
  deployments: Record<string, string>
): Promise<void> {
  await Bun.write(DEPLOYMENTS_FILE, JSON.stringify(deployments, null, 2) + '\n')
  consola.info(`Deployments saved to: ${DEPLOYMENTS_FILE}`)
}

// ── Main ───────────────────────────────────────────────────────────────────────

async function main() {
  const {
    dryRun,
    network,
    privateKey: pkFlag,
    rpcUrl: rpcUrlFlag,
    trongridApiKey: apiKeyFlag,
    owner: ownerFlag,
    polymerProver,
    steps,
  } = parseArgs()

  const contractsToRun = steps ?? [...CONTRACTS_TO_DEPLOY]

  const needsPolymer = contractsToRun.includes('PolymerOracle')
  if (needsPolymer && !polymerProver) {
    consola.error('--polymer-prover <address> is required when deploying PolymerOracle')
    process.exit(1)
  }

  consola.info(`Deploying OIF contracts to ${network}...`)
  if (steps) {
    consola.info(`Steps: ${contractsToRun.join(' → ')}`)
  }
  if (dryRun) consola.warn('DRY RUN mode - no transactions will be broadcast')

  if (!dryRun) await promptEnergyRentalReminder()

  const privateKey = getPrivateKey(pkFlag)
  const rpcUrl = getTronRpcUrl(network, rpcUrlFlag)
  const trongridApiKey = getTronGridAPIKey(apiKeyFlag)

  const headers: Record<string, string> = {}
  if (trongridApiKey) headers[TRON_PRO_API_KEY_HEADER] = trongridApiKey

  const config: ITronDeploymentConfig = {
    fullHost: rpcUrl,
    tvmNetworkKey: network,
    privateKey,
    dryRun,
    verbose: process.argv.includes('--verbose'),
    ...(Object.keys(headers).length > 0 && { headers }),
  }

  const deployer = new TronContractDeployer(config)
  const tronWeb = createTronWeb({ rpcUrl, privateKey })

  const info = await deployer.getNetworkInfo()
  consola.info('Network info:', {
    network: info.network,
    block: info.block,
    address: info.address,
    balance: `${info.balance} TRX`,
  })

  const toHex = (addr: string): string => {
    if (addr.startsWith('0x')) return addr
    const hex = tronAddressToHex(tronWeb, addr)
    return hex.startsWith('0x') ? hex : `0x${hex}`
  }

  const owner = ownerFlag
    ? toHex(ownerFlag)
    : '0x0000000000000000000000000000000000000000'

  const constructorArgs: ConstructorArgs = {
    InputSettler: () => [owner],
    OutputSettler: () => [],
    PolymerOracle: () => [toHex(polymerProver!)],
  }

  const deployments = await loadDeployments()
  const results: Array<{
    contract: string
    result: ITronDeploymentResult
  }> = []

  for (const contractName of contractsToRun) {
    const { contractName: tronName, sourceFile } = TRON_CONTRACT[contractName]
    const args = constructorArgs[contractName]()
    consola.info(`\n--- Deploying ${contractName} (${tronName}) ---`)
    if (args.length > 0) {
      consola.info(`  Constructor args: ${JSON.stringify(args)}`)
    }

    try {
      const artifact = await loadTronArtifact(tronName, sourceFile)
      const result = await deployer.deployContract(artifact, args)

      results.push({ contract: contractName, result })
      deployments[contractName] = result.contractAddress

      consola.success(`${contractName} deployed:`)
      consola.info(`  Address: ${result.contractAddress}`)
      consola.info(
        `  TX: ${tronScanTransactionUrl(network, result.transactionId)}`
      )
      consola.info(`  Cost: ${result.actualCost.trxCost} TRX`)
    } catch (error: any) {
      if (dryRun && /insufficient balance/i.test(error.message)) {
        consola.warn(`${contractName}: ${error.message}`)
        continue
      }
      consola.error(`Failed to deploy ${contractName}: ${error.message}`)
      process.exit(1)
    }
  }

  if (!dryRun) {
    await saveDeployments(deployments)
  }

  consola.info('\n=== Deployment Summary ===')
  for (const { contract, result } of results) {
    consola.info(`  ${contract}: ${result.contractAddress}`)
  }
  consola.success(
    steps
      ? 'Selected contract(s) deployed successfully!'
      : 'All OIF contracts deployed successfully!'
  )
}

main().catch((error) => {
  consola.error('Deployment failed:', error)
  process.exit(1)
})
