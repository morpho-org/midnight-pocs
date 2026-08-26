import { MarketUtils, TakeAmountsLib, midnightAbi, type OfferStruct } from '@morpho-org/midnight-sdk'
import {
  zeroAddress,
  type Account,
  type Address,
  type Chain,
  type Hex,
  type PublicClient,
  type Transport,
  type WalletClient,
} from 'viem'

export interface SimulateTakeParameters<
  chain extends Chain,
  publicTransport extends Transport,
  account extends Account,
> {
  publicClient: PublicClient<publicTransport, chain>
  account: account
  offer: OfferStruct
  ratifierData: Hex
  buyerAssets: bigint
  receiver?: Address
  onBehalf?: Address
}

/** Quotes and simulates a partial fill without changing state. */
export async function simulateTake<
  chain extends Chain,
  publicTransport extends Transport,
  account extends Account,
>({
  publicClient,
  account,
  offer,
  ratifierData,
  buyerAssets,
  receiver = account.address,
  onBehalf = account.address,
}: SimulateTakeParameters<chain, publicTransport, account>) {
  if (buyerAssets <= 0n) throw new Error('buyerAssets must be positive')

  const block = await publicClient.getBlock()
  const timeToMaturity = BigInt(offer.market.maturity) - block.timestamp
  if (timeToMaturity <= 0n) throw new Error('market has matured')
  const settlementFee = await publicClient.readContract({
    address: offer.market.midnight,
    abi: midnightAbi,
    functionName: 'settlementFee',
    args: [MarketUtils.toId(offer.market), timeToMaturity],
  })
  const units = TakeAmountsLib.buyerAssetsToUnits({ offer, targetBuyerAssets: buyerAssets, settlementFee })
  const simulation = await publicClient.simulateContract({
    account,
    address: offer.market.midnight,
    abi: midnightAbi,
    functionName: 'take',
    args: [offer, ratifierData, units, receiver, onBehalf, zeroAddress, '0x'],
  })
  const gas = await publicClient.estimateContractGas(simulation.request as never)
  return { ...simulation, request: { ...simulation.request, gas: (gas * 12n) / 10n }, units }
}

/** Simulates and submits one partial fill of a signed Midnight offer. */
export async function takeOffer<
  chain extends Chain,
  publicTransport extends Transport,
  walletTransport extends Transport,
  account extends Account,
>(
  parameters: SimulateTakeParameters<chain, publicTransport, account> & {
    walletClient: WalletClient<walletTransport, chain, account>
  },
) {
  const { walletClient, ...simulateParameters } = parameters
  const simulation = await simulateTake(simulateParameters)
  const hash = await walletClient.writeContract(simulation.request as never)
  const receipt = await parameters.publicClient.waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success') throw new Error(`take reverted: ${hash}`)
  return { ...simulation, hash, receipt }
}
