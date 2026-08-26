import { blueAbi } from '@morpho-org/blue-sdk-viem'
import {
  EcrecoverRatifierUtils,
  Offer,
  OfferUtils,
  Tree,
  midnightAbi,
  type IMarketParams,
  type OfferStruct,
} from '@morpho-org/midnight-sdk'
import {
  encodeAbiParameters,
  erc20Abi,
  zeroAddress,
  type Account,
  type Address,
  type Chain,
  type Hash,
  type Hex,
  type PublicClient,
  type Transport,
  type WalletClient,
} from 'viem'
import { blueBuyCallbackFactoryAbi } from './abis.js'

export interface BlueMarketParams {
  readonly loanToken: Address
  readonly collateralToken: Address
  readonly oracle: Address
  readonly irm: Address
  readonly lltv: bigint
}

export interface MakeBlueCallbackOfferParameters<
  chain extends Chain,
  publicTransport extends Transport,
  walletTransport extends Transport,
  account extends Account,
> {
  publicClient: PublicClient<publicTransport, chain>
  walletClient: WalletClient<walletTransport, chain, account>
  account: account
  blue: Address
  callbackFactory: Address
  ratifier: Address
  blueMarket: BlueMarketParams
  midnightMarket: IMarketParams
  assets: bigint
  tick: bigint
  expiry: bigint
  salt: Hash
}

export interface SignedBlueCallbackOffer {
  callback: Address
  callbackData: Hex
  offer: OfferStruct
  ratifierData: Hex
  transactionHashes: readonly Hash[]
}

const encodeBlueMarket = (market: BlueMarketParams) =>
  encodeAbiParameters(
    [
      {
        type: 'tuple',
        components: [
          { name: 'loanToken', type: 'address' },
          { name: 'collateralToken', type: 'address' },
          { name: 'oracle', type: 'address' },
          { name: 'irm', type: 'address' },
          { name: 'lltv', type: 'uint256' },
        ],
      },
    ],
    [market],
  )

async function confirm<transport extends Transport, chain extends Chain>(
  publicClient: PublicClient<transport, chain>,
  hash: Hash,
) {
  const receipt = await publicClient.waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success') throw new Error(`transaction reverted: ${hash}`)
}

/** Supplies the maker's loan tokens to Blue and signs a callback-backed Midnight offer. */
export async function makeBlueCallbackOffer<
  chain extends Chain,
  publicTransport extends Transport,
  walletTransport extends Transport,
  account extends Account,
>({
  publicClient,
  walletClient,
  account,
  blue,
  callbackFactory,
  ratifier,
  blueMarket,
  midnightMarket,
  assets,
  tick,
  expiry,
  salt,
}: MakeBlueCallbackOfferParameters<chain, publicTransport, walletTransport, account>): Promise<SignedBlueCallbackOffer> {
  if (assets <= 0n) throw new Error('assets must be positive')
  if (blueMarket.loanToken.toLowerCase() !== midnightMarket.loanToken.toLowerCase()) {
    throw new Error('Blue and Midnight loan tokens must match')
  }

  const transactionHashes: Hash[] = []
  let callback = await publicClient.readContract({
    address: callbackFactory,
    abi: blueBuyCallbackFactoryAbi,
    functionName: 'callbackOf',
    args: [account.address, salt],
  })

  if (callback === zeroAddress) {
    const { request } = await publicClient.simulateContract({
      account,
      address: callbackFactory,
      abi: blueBuyCallbackFactoryAbi,
      functionName: 'createBlueBuyCallback',
      args: [account.address, salt],
    })
    const hash = await walletClient.writeContract(request as never)
    transactionHashes.push(hash)
    await confirm(publicClient, hash)
    callback = await publicClient.readContract({
      address: callbackFactory,
      abi: blueBuyCallbackFactoryAbi,
      functionName: 'callbackOf',
      args: [account.address, salt],
    })
  }

  const allowance = await publicClient.readContract({
    address: blueMarket.loanToken,
    abi: erc20Abi,
    functionName: 'allowance',
    args: [account.address, blue],
  })
  if (allowance < assets) {
    const { request } = await publicClient.simulateContract({
      account,
      address: blueMarket.loanToken,
      abi: erc20Abi,
      functionName: 'approve',
      args: [blue, assets],
    })
    const hash = await walletClient.writeContract(request as never)
    transactionHashes.push(hash)
    await confirm(publicClient, hash)
  }

  const { request: supply } = await publicClient.simulateContract({
    account,
    address: blue,
    abi: blueAbi,
    functionName: 'supply',
    args: [blueMarket, assets, 0n, callback, '0x'],
  })
  const supplyHash = await walletClient.writeContract(supply as never)
  transactionHashes.push(supplyHash)
  await confirm(publicClient, supplyHash)

  const isAuthorized = await publicClient.readContract({
    address: midnightMarket.midnight,
    abi: midnightAbi,
    functionName: 'isAuthorized',
    args: [account.address, ratifier],
  })
  if (!isAuthorized) {
    const { request } = await publicClient.simulateContract({
      account,
      address: midnightMarket.midnight,
      abi: midnightAbi,
      functionName: 'setIsAuthorized',
      args: [ratifier, true, account.address],
    })
    const hash = await walletClient.writeContract(request as never)
    transactionHashes.push(hash)
    await confirm(publicClient, hash)
  }

  const callbackData = encodeBlueMarket(blueMarket)
  const unsignedOffer = Offer.create({
    market: midnightMarket,
    buy: true,
    maker: account.address,
    tick,
    expiry,
    callback,
    callbackData,
    ratifier,
    maxAssets: assets,
  })
  const [signed] = await EcrecoverRatifierUtils.ratify({
    tree: Tree.create([unsignedOffer]),
    client: walletClient,
    account,
  })
  if (!signed) throw new Error('ratifier returned no signed offer')

  return {
    callback,
    callbackData,
    offer: OfferUtils.toStruct({ offer: signed.offer }),
    ratifierData: signed.ratifierData,
    transactionHashes,
  }
}
