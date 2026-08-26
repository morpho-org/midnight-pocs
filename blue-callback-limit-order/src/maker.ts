import { marketParamsAbi, type InputMarketParams } from '@morpho-org/blue-sdk'
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
  type Hash,
  type Hex,
  type PublicClient,
  type Transport,
  type WalletClient,
} from 'viem'
import { base } from 'viem/chains'
import { blueBuyCallbackFactoryAbi } from './abis.js'

type BasePublicClient = PublicClient<Transport, typeof base>
type BaseWalletClient = WalletClient<Transport, typeof base, Account>

export interface MakerContext {
  publicClient: BasePublicClient
  walletClient: BaseWalletClient
  account: Account
  blue: Address
  callbackFactory: Address
  ratifier: Address
  blueMarket: InputMarketParams
  midnightMarket: IMarketParams
}

export interface SignOfferParameters {
  callback: Address
  assets: bigint
  tick: bigint
  expiry: bigint
}

export interface SignedOffer {
  callbackData: Hex
  offer: OfferStruct
  ratifierData: Hex
}

function validateAssets(assets: bigint) {
  if (assets <= 0n) throw new Error('assets must be positive')
}

export function createMaker(context: MakerContext) {
  const { publicClient, walletClient, account, blue, callbackFactory, ratifier, blueMarket, midnightMarket } = context

  if (blueMarket.loanToken.toLowerCase() !== midnightMarket.loanToken.toLowerCase()) {
    throw new Error('Blue and Midnight loan tokens must match')
  }

  async function confirm(transaction: Promise<Hash>) {
    const hash = await transaction
    const receipt = await publicClient.waitForTransactionReceipt({ hash })
    if (receipt.status !== 'success') throw new Error(`transaction reverted: ${hash}`)
  }

  async function createCallback(salt: Hash) {
    const existing = await publicClient.readContract({
      address: callbackFactory,
      abi: blueBuyCallbackFactoryAbi,
      functionName: 'callbackOf',
      args: [account.address, salt],
    })
    if (existing !== zeroAddress) return existing

    await confirm(
      walletClient.writeContract({
        address: callbackFactory,
        abi: blueBuyCallbackFactoryAbi,
        functionName: 'createBlueBuyCallback',
        args: [account.address, salt],
        chain: base,
        account,
      }),
    )

    const callback = await publicClient.readContract({
      address: callbackFactory,
      abi: blueBuyCallbackFactoryAbi,
      functionName: 'callbackOf',
      args: [account.address, salt],
    })
    if (callback === zeroAddress) throw new Error('callback creation failed')
    return callback
  }

  async function approveBlue(assets: bigint) {
    validateAssets(assets)
    const allowance = await publicClient.readContract({
      address: blueMarket.loanToken,
      abi: erc20Abi,
      functionName: 'allowance',
      args: [account.address, blue],
    })
    if (allowance >= assets) return

    await confirm(
      walletClient.writeContract({
        address: blueMarket.loanToken,
        abi: erc20Abi,
        functionName: 'approve',
        args: [blue, assets],
        chain: base,
        account,
      }),
    )
  }

  async function supplyBlue(callback: Address, assets: bigint) {
    validateAssets(assets)
    if (callback === zeroAddress) throw new Error('callback is required')

    await confirm(
      walletClient.writeContract({
        address: blue,
        abi: blueAbi,
        functionName: 'supply',
        args: [blueMarket, assets, 0n, callback, '0x'],
        chain: base,
        account,
      }),
    )
  }

  async function authorizeRatifier() {
    const isAuthorized = await publicClient.readContract({
      address: midnightMarket.midnight,
      abi: midnightAbi,
      functionName: 'isAuthorized',
      args: [account.address, ratifier],
    })
    if (isAuthorized) return

    await confirm(
      walletClient.writeContract({
        address: midnightMarket.midnight,
        abi: midnightAbi,
        functionName: 'setIsAuthorized',
        args: [ratifier, true, account.address],
        chain: base,
        account,
      }),
    )
  }

  async function signOffer({ callback, assets, tick, expiry }: SignOfferParameters): Promise<SignedOffer> {
    validateAssets(assets)
    if (callback === zeroAddress) throw new Error('callback is required')

    const callbackData = encodeAbiParameters([marketParamsAbi], [blueMarket])
    const offer = Offer.create({
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
      tree: Tree.create([offer]),
      client: walletClient,
      account,
    })
    if (!signed) throw new Error('ratifier returned no signed offer')

    return {
      callbackData,
      offer: OfferUtils.toStruct({ offer: signed.offer }),
      ratifierData: signed.ratifierData,
    }
  }

  return { createCallback, approveBlue, supplyBlue, authorizeRatifier, signOffer }
}
