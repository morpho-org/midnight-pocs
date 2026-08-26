import { MarketUtils, TakeAmountsLib, midnightAbi, type OfferStruct } from '@morpho-org/midnight-sdk'
import {
  zeroAddress,
  type Account,
  type Address,
  type Hex,
  type PublicClient,
  type Transport,
  type WalletClient,
} from 'viem'
import { base } from 'viem/chains'

type BasePublicClient = PublicClient<Transport, typeof base>
type BaseWalletClient = WalletClient<Transport, typeof base, Account>

export interface SimulateTakeParameters {
  publicClient: BasePublicClient
  account: Account
  offer: OfferStruct
  ratifierData: Hex
  buyerAssets: bigint
  receiver?: Address
  onBehalf?: Address
}

export type TakeOfferParameters = SimulateTakeParameters & {
  walletClient: BaseWalletClient
}

export async function simulateTake({
  publicClient,
  account,
  offer,
  ratifierData,
  buyerAssets,
  receiver = account.address,
  onBehalf = account.address,
}: SimulateTakeParameters) {
  if (buyerAssets <= 0n) throw new Error('buyerAssets must be positive')

  const { timestamp } = await publicClient.getBlock()
  const timeToMaturity = BigInt(offer.market.maturity) - timestamp
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

export async function takeOffer({ walletClient, ...parameters }: TakeOfferParameters) {
  const simulation = await simulateTake(parameters)
  const hash = await walletClient.writeContract(simulation.request as never)
  const receipt = await parameters.publicClient.waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success') throw new Error(`take reverted: ${hash}`)
  return { ...simulation, hash, receipt }
}
