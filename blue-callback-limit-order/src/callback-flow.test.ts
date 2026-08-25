import assert from 'node:assert/strict'
import {
  EcrecoverRatifierUtils,
  MarketUtils,
  Offer,
  OfferUtils,
  TakeAmountsLib,
  TickLib,
  Tree,
  midnightAbi,
} from '@morpho-org/midnight-sdk'
import { blueAbi } from '@morpho-org/blue-sdk-viem'
import {
  createPublicClient,
  createWalletClient,
  encodeAbiParameters,
  erc20Abi,
  formatUnits,
  http,
  keccak256,
  parseUnits,
  stringToHex,
  zeroAddress,
  type Abi,
  type Account,
  type Address,
  type Hash,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { base } from 'viem/chains'
import { blueBuyCallbackAbi, blueBuyCallbackFactoryAbi } from './abis.js'
import {
  BLUE,
  BLUE_MARKET,
  BLUE_MARKET_ID,
  BORROWER_PRIVATE_KEY,
  CALLBACK_FACTORY,
  CBBTC,
  CHAIN_ID,
  ECRECOVER_RATIFIER,
  MAKER_PRIVATE_KEY,
  MIDNIGHT,
  MIDNIGHT_MARKET,
  MIDNIGHT_MARKET_ID,
  RPC_URL,
  USDC,
} from './constants.js'

const WAD = 10n ** 18n
const YEAR = 365n * 24n * 60n * 60n
const OFFER_SIZE = parseUnits('100', 6)
const FIRST_FILL = parseUnits('25', 6)
const SECOND_FILL = parseUnits('10', 6)
const COLLATERAL = parseUnits('0.001', 8)
const SALT = keccak256(stringToHex('blue-callback-limit-order'))

const maker = privateKeyToAccount(MAKER_PRIVATE_KEY)
const borrower = privateKeyToAccount(BORROWER_PRIVATE_KEY)

const publicClient = createPublicClient({ chain: base, transport: http(RPC_URL), pollingInterval: 50 })
const wallet = (account: Account | Address) =>
  createWalletClient({ account, chain: base, transport: http(RPC_URL), pollingInterval: 50 })

async function setEthBalance(address: Address) {
  await publicClient.request({
    method: 'anvil_setBalance' as never,
    params: [address, '0x56bc75e2d63100000'] as never,
  })
}

async function send(
  account: Account | Address,
  request: { address: Address; abi: Abi; functionName: string; args?: readonly unknown[] },
) {
  const client = wallet(account)
  const hash = await client.writeContract({
    account,
    address: request.address,
    abi: request.abi,
    functionName: request.functionName,
    args: request.args ?? [],
    chain: base,
    gas: 5_000_000n,
  } as never)
  const receipt = await publicClient.waitForTransactionReceipt({ hash })
  assert.equal(receipt.status, 'success')
  return receipt
}

async function tokenBalance(token: Address, account: Address) {
  return publicClient.readContract({ address: token, abi: erc20Abi, functionName: 'balanceOf', args: [account] })
}

async function callbackBound(callback: Address, callbackData: `0x${string}`) {
  return publicClient.readContract({
    address: callback,
    abi: blueBuyCallbackAbi,
    functionName: 'buyerAssetsBound',
    args: [MIDNIGHT_MARKET_ID, MarketUtils.toStruct(MIDNIGHT_MARKET), maker.address, callbackData],
  })
}

async function blueSupplyShares(callback: Address) {
  const position = await publicClient.readContract({
    address: BLUE,
    abi: blueAbi,
    functionName: 'position',
    args: [BLUE_MARKET_ID, callback],
  })
  return position[0]
}

async function midnightPosition(user: Address) {
  return publicClient.readContract({
    address: MIDNIGHT,
    abi: midnightAbi,
    functionName: 'position',
    args: [MIDNIGHT_MARKET_ID, user],
  })
}

function sixPercentTick(timestamp: bigint) {
  const timeToMaturity = BigInt(MIDNIGHT_MARKET.maturity) - timestamp
  assert(timeToMaturity > 0n, 'December 2026 Midnight market has already matured')
  const periodRate = (6n * WAD * timeToMaturity) / (100n * YEAR)
  return TickLib.priceToTick(TickLib.rateToPrice(periodRate))
}

function displayUsdc(assets: bigint) {
  return `${formatUnits(assets, 6)} USDC`
}

async function main() {
  const chainId = await publicClient.getChainId().catch(() => 0)
  assert.equal(chainId, CHAIN_ID, `Anvil Base fork is not reachable at ${RPC_URL}`)
  assert.notEqual(await publicClient.getCode({ address: CALLBACK_FACTORY }), '0x', 'callback factory is not deployed')

  await Promise.all([setEthBalance(maker.address), setEthBalance(borrower.address), setEthBalance(BLUE)])

  let callback = await publicClient.readContract({
    address: CALLBACK_FACTORY,
    abi: blueBuyCallbackFactoryAbi,
    functionName: 'callbackOf',
    args: [maker.address, SALT],
  })
  assert.equal(callback, zeroAddress, 'test requires a fresh Anvil fork')
  await send(maker, {
    address: CALLBACK_FACTORY,
    abi: blueBuyCallbackFactoryAbi,
    functionName: 'createBlueBuyCallback',
    args: [maker.address, SALT],
  })
  callback = await publicClient.readContract({
    address: CALLBACK_FACTORY,
    abi: blueBuyCallbackFactoryAbi,
    functionName: 'callbackOf',
    args: [maker.address, SALT],
  })
  assert.notEqual(callback, zeroAddress)
  assert.equal(
    (await publicClient.readContract({ address: callback, abi: blueBuyCallbackAbi, functionName: 'OWNER' })).toLowerCase(),
    maker.address.toLowerCase(),
  )

  await send(BLUE, {
    address: USDC,
    abi: erc20Abi,
    functionName: 'transfer',
    args: [maker.address, OFFER_SIZE],
  })
  await send(maker, {
    address: USDC,
    abi: erc20Abi,
    functionName: 'approve',
    args: [BLUE, OFFER_SIZE],
  })
  await send(maker, {
    address: BLUE,
    abi: blueAbi,
    functionName: 'supply',
    args: [BLUE_MARKET, OFFER_SIZE, 0n, callback, '0x'],
  })
  await send(maker, {
    address: MIDNIGHT,
    abi: midnightAbi,
    functionName: 'setIsAuthorized',
    args: [ECRECOVER_RATIFIER, true, maker.address],
  })

  const callbackData = encodeAbiParameters(
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
    [BLUE_MARKET],
  )

  const block = await publicClient.getBlock()
  const tick = sixPercentTick(block.timestamp)
  const offer = Offer.create({
    market: MIDNIGHT_MARKET,
    buy: true,
    maker: maker.address,
    tick,
    expiry: BigInt(MIDNIGHT_MARKET.maturity) - 1n,
    callback,
    callbackData,
    ratifier: ECRECOVER_RATIFIER,
    maxAssets: OFFER_SIZE,
  })
  const tree = Tree.create([offer])
  const [ratified] = await EcrecoverRatifierUtils.ratify({ tree, client: wallet(maker), account: maker })
  assert(ratified)
  const offerStruct = OfferUtils.toStruct({ offer: ratified.offer })

  const { result: computedMarketId } = await publicClient.simulateContract({
    account: borrower,
    address: MIDNIGHT,
    abi: midnightAbi,
    functionName: 'touchMarket',
    args: [MarketUtils.toStruct(MIDNIGHT_MARKET)],
  })
  assert.equal(computedMarketId, MIDNIGHT_MARKET_ID, 'pinned Midnight market params changed')

  await send(BLUE, {
    address: CBBTC,
    abi: erc20Abi,
    functionName: 'transfer',
    args: [borrower.address, COLLATERAL],
  })
  await send(borrower, {
    address: CBBTC,
    abi: erc20Abi,
    functionName: 'approve',
    args: [MIDNIGHT, COLLATERAL],
  })
  await send(borrower, {
    address: MIDNIGHT,
    abi: midnightAbi,
    functionName: 'supplyCollateral',
    args: [MarketUtils.toStruct(MIDNIGHT_MARKET), 0n, COLLATERAL, borrower.address],
  })

  const settlementFee = await publicClient.readContract({
    address: MIDNIGHT,
    abi: midnightAbi,
    functionName: 'settlementFee',
    args: [MIDNIGHT_MARKET_ID, BigInt(MIDNIGHT_MARKET.maturity) - block.timestamp],
  })
  const unitsFor = (buyerAssets: bigint) =>
    TakeAmountsLib.buyerAssetsToUnits({ offer, targetBuyerAssets: buyerAssets, settlementFee })

  const boundBefore = await callbackBound(callback, callbackData)
  const sharesBefore = await blueSupplyShares(callback)
  const makerPositionBefore = await midnightPosition(maker.address)
  const borrowerPositionBefore = await midnightPosition(borrower.address)
  const borrowerUsdcBefore = await tokenBalance(USDC, borrower.address)
  assert(boundBefore >= OFFER_SIZE - 2n, 'callback does not hold the expected Blue position')

  const firstUnits = unitsFor(FIRST_FILL)
  const { result: firstResult, request: firstTake } = await publicClient.simulateContract({
    account: borrower,
    address: MIDNIGHT,
    abi: midnightAbi,
    functionName: 'take',
    args: [
      offerStruct,
      ratified.ratifierData,
      firstUnits,
      borrower.address,
      borrower.address,
      zeroAddress,
      '0x',
    ],
  })
  const [firstBuyerAssets, firstSellerAssets] = firstResult
  assert(firstBuyerAssets <= FIRST_FILL)
  await send(borrower, firstTake as never)

  const boundAfterFirst = await callbackBound(callback, callbackData)
  const sharesAfterFirst = await blueSupplyShares(callback)
  const makerPositionAfterFirst = await midnightPosition(maker.address)
  const borrowerPositionAfterFirst = await midnightPosition(borrower.address)
  const borrowerUsdcAfterFirst = await tokenBalance(USDC, borrower.address)

  assert(sharesAfterFirst < sharesBefore, 'the callback did not withdraw from Blue')
  assert(boundAfterFirst < boundBefore, 'the callback bound did not decrease')
  assert.equal(makerPositionAfterFirst[0] - makerPositionBefore[0], firstUnits)
  assert.equal(borrowerPositionAfterFirst[4] - borrowerPositionBefore[4], firstUnits)
  assert.equal(borrowerUsdcAfterFirst - borrowerUsdcBefore, firstSellerAssets)

  const secondUnits = unitsFor(SECOND_FILL)
  const { request: secondTake } = await publicClient.simulateContract({
    account: borrower,
    address: MIDNIGHT,
    abi: midnightAbi,
    functionName: 'take',
    args: [
      offerStruct,
      ratified.ratifierData,
      secondUnits,
      borrower.address,
      borrower.address,
      zeroAddress,
      '0x',
    ],
  })
  await send(borrower, secondTake as never)

  const boundAfterSecond = await callbackBound(callback, callbackData)
  const makerPositionAfterSecond = await midnightPosition(maker.address)
  assert(boundAfterSecond < boundAfterFirst)
  assert.equal(makerPositionAfterSecond[0] - makerPositionAfterFirst[0], secondUnits)

  const liquidityRemoved = parseUnits('60', 6)
  await send(maker, {
    address: BLUE,
    abi: blueAbi,
    functionName: 'withdraw',
    args: [BLUE_MARKET, liquidityRemoved, 0n, callback, maker.address],
  })
  const staleBound = await callbackBound(callback, callbackData)
  assert(staleBound <= boundAfterSecond - liquidityRemoved + 2n)

  const oversizedUnits = unitsFor(parseUnits('10', 6))
  await assert.rejects(
    publicClient.simulateContract({
      account: borrower,
      address: MIDNIGHT,
      abi: midnightAbi,
      functionName: 'take',
      args: [
        offerStruct,
        ratified.ratifierData,
        oversizedUnits,
        borrower.address,
        borrower.address,
        zeroAddress,
        '0x',
      ],
    }),
    /reverted/,
  )

  const apr = TickLib.tickToApr(tick, BigInt(MIDNIGHT_MARKET.maturity) - block.timestamp)
  console.log('Blue callback limit order')
  console.log(`  callback:             ${callback}`)
  console.log(`  fixed APR:            ${(Number(apr) / 1e16).toFixed(4)}%`)
  console.log(`  Blue before:          ${displayUsdc(boundBefore)}`)
  console.log(`  first fill:           ${displayUsdc(firstBuyerAssets)}`)
  console.log(`  borrower received:    ${displayUsdc(firstSellerAssets)}`)
  console.log(`  Blue after first:     ${displayUsdc(boundAfterFirst)}`)
  console.log(`  Blue after second:    ${displayUsdc(boundAfterSecond)}`)
  console.log(`  stale-liquidity take: reverted as expected`)
  console.log('PASS')
}

main().catch((error: unknown) => {
  console.error(error)
  process.exitCode = 1
})
