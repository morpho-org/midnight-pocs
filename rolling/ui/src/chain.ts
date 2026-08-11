import {
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  parseEventLogs,
  type Abi,
  type Address,
  type Hex,
  type TransactionReceipt,
} from 'viem'
import { artifacts } from './artifacts'

export const RPC = 'http://127.0.0.1:8545'
const GAS = 28_000_000n

export const MIDNIGHT: Address = '0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A'
export const SETTER_RATIFIER: Address = '0x800B5F12A61B8198a5a6EfD794Cac6699B294d63'
export const USDC: Address = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913'
export const MORPHO_BLUE: Address = '0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb'

export const ERC20_ABI = [
  {
    type: 'function',
    name: 'balanceOf',
    stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'transfer',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'to', type: 'address' }, { name: 'amount', type: 'uint256' }],
    outputs: [{ type: 'bool' }],
  },
  {
    type: 'function',
    name: 'approve',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'spender', type: 'address' }, { name: 'amount', type: 'uint256' }],
    outputs: [{ type: 'bool' }],
  },
  {
    type: 'event',
    name: 'Transfer',
    inputs: [
      { name: 'from', type: 'address', indexed: true },
      { name: 'to', type: 'address', indexed: true },
      { name: 'value', type: 'uint256', indexed: false },
    ],
  },
] as const satisfies Abi

const chain = defineChain({
  id: 8453,
  name: 'Local Base fork',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [RPC] } },
})

export const publicClient = createPublicClient({ chain, transport: http(RPC), pollingInterval: 50 })

const walletFor = (account: Address) => createWalletClient({ account, chain, transport: http(RPC) })

const ALL_ABIS = [
  ...(artifacts.RollingBorrower.abi as unknown as Abi),
  ...(artifacts.FlashRollLender.abi as unknown as Abi),
  ...(artifacts.TwoPartyGate.abi as unknown as Abi),
  ...(artifacts.MockCollateral.abi as unknown as Abi),
  ...(artifacts.IMidnight.abi as unknown as Abi),
  ...(artifacts.ISetterRatifier.abi as unknown as Abi),
  ...(ERC20_ABI as unknown as Abi),
] as Abi

export type EventRecord = { name: string; address: Address; args: Record<string, string> }
export type TxRecord = { label: string; hash: Hex; gasUsed: bigint; events: EventRecord[] }

export async function rpc<T>(method: string, params: unknown[] = []): Promise<T> {
  const response = await fetch(RPC, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  })
  const body = await response.json()
  if (body.error) throw new Error(`${method}: ${body.error.message}`)
  return body.result as T
}

export const resetFork = () => rpc<void>('anvil_reset')
export const snapshotChain = () => rpc<string>('evm_snapshot')
export const revertChain = (id: string) => rpc<boolean>('evm_revert', [id])
export const setBalance = (address: Address) => rpc<void>('anvil_setBalance', [address, '0xde0b6b3a7640000'])

export async function warpTo(timestamp: bigint) {
  const current = (await publicClient.getBlock()).timestamp
  if (timestamp <= current) return
  await rpc('evm_setNextBlockTimestamp', [Number(timestamp)])
  await rpc('evm_mine')
}

const decode = (receipt: TransactionReceipt): EventRecord[] => {
  const parsed = parseEventLogs({ abi: ALL_ABIS, logs: receipt.logs, strict: false })
  return parsed.map((log) => ({
    name: (log as { eventName: string }).eventName,
    address: log.address,
    args: Object.fromEntries(
      Object.entries((log as { args?: Record<string, unknown> }).args ?? {}).map(([key, value]) => [
        key,
        typeof value === 'bigint' ? value.toString() : String(value),
      ]),
    ),
  }))
}

export async function send(
  from: Address,
  label: string,
  request: { address: Address; abi: Abi; functionName: string; args?: readonly unknown[] },
): Promise<TxRecord> {
  await setBalance(from)
  const wallet = walletFor(from)
  const hash = await wallet.writeContract({
    ...request,
    args: request.args ?? [],
    account: from,
    chain,
    gas: GAS,
  } as never)
  const receipt = await publicClient.waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success') throw new Error(`${label} reverted`)
  return { label, hash, gasUsed: receipt.gasUsed, events: decode(receipt) }
}

export async function deploy(
  from: Address,
  label: string,
  artifact: { abi: unknown; bytecode: string },
  args: readonly unknown[] = [],
): Promise<{ address: Address; tx: TxRecord }> {
  await setBalance(from)
  const wallet = walletFor(from)
  const hash = await wallet.deployContract({
    abi: artifact.abi as Abi,
    bytecode: artifact.bytecode as Hex,
    args,
    account: from,
    chain,
    gas: GAS,
  } as never)
  const receipt = await publicClient.waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success' || !receipt.contractAddress) throw new Error(`${label} failed`)
  return {
    address: receipt.contractAddress,
    tx: { label, hash, gasUsed: receipt.gasUsed, events: decode(receipt) },
  }
}

export const read = <T,>(address: Address, abi: Abi, functionName: string, args: readonly unknown[] = []) =>
  publicClient.readContract({ address, abi, functionName, args } as never) as Promise<T>

export async function fundUsdc(to: Address, amount: bigint, label: string) {
  return send(MORPHO_BLUE, label, {
    address: USDC,
    abi: ERC20_ABI as unknown as Abi,
    functionName: 'transfer',
    args: [to, amount],
  })
}

export async function nodeReachable() {
  try {
    return (await rpc<string>('eth_chainId')) === '0x2105'
  } catch {
    return false
  }
}

export function freshAddress(): Address {
  const bytes = new Uint8Array(20)
  crypto.getRandomValues(bytes)
  return `0x${Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('')}` as Address
}
