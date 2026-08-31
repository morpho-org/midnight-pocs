import assert from 'node:assert/strict'
import type { MarketId } from '@morpho-org/blue-sdk'
import {
  MarketUtils,
  TickLib,
  midnightAbi,
} from '@morpho-org/midnight-sdk'
import { blueAbi, fetchAccrualPosition } from '@morpho-org/blue-sdk-viem'
import {
  createPublicClient,
  createWalletClient,
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
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { base } from 'viem/chains'
import { blueBuyCallbackAbi } from './abis.js'
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
import { prepareBlueCallbackPosition, signBlueCallbackOffer } from './maker.js'
import { simulateTake, takeOffer } from './taker.js'

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

async function blueSupplyAssets(callback: Address) {
  // Position assets prove what the callback owns; buyerAssetsBound only measures immediately executable capacity.
  return (await fetchAccrualPosition(callback, BLUE_MARKET_ID as MarketId, publicClient)).supplyAssets
}

function assertApprox(actual: bigint, expected: bigint, tolerance = 2n) {
  const difference = actual > expected ? actual - expected : expected - actual
  assert(difference <= tolerance, `expected ${actual} to be within ${tolerance} of ${expected}`)
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

  // Validate pinned market constants before any test funding or maker-side transactions.
  const { result: computedMarketId } = await publicClient.simulateContract({
    account: borrower,
    address: MIDNIGHT,
    abi: midnightAbi,
    functionName: 'touchMarket',
    args: [MarketUtils.toStruct(MIDNIGHT_MARKET)],
  })
  assert.equal(computedMarketId, MIDNIGHT_MARKET_ID, 'pinned Midnight market params changed')

  await Promise.all([setEthBalance(maker.address), setEthBalance(borrower.address), setEthBalance(BLUE)])

  await send(BLUE, {
    address: USDC,
    abi: erc20Abi,
    functionName: 'transfer',
    args: [maker.address, OFFER_SIZE],
  })

  const block = await publicClient.getBlock()
  const tick = sixPercentTick(block.timestamp)
  const prepareParameters = {
    publicClient,
    walletClient: wallet(maker),
    account: maker,
    blue: BLUE,
    callbackFactory: CALLBACK_FACTORY,
    ratifier: ECRECOVER_RATIFIER,
    blueMarket: BLUE_MARKET,
    midnightMarket: MIDNIGHT_MARKET,
    assets: OFFER_SIZE,
    salt: SALT,
  }
  const callback = await prepareBlueCallbackPosition(prepareParameters)
  const { callbackData, offer, ratifierData } = await signBlueCallbackOffer({
    walletClient: wallet(maker),
    account: maker,
    callback,
    ratifier: ECRECOVER_RATIFIER,
    blueMarket: BLUE_MARKET,
    midnightMarket: MIDNIGHT_MARKET,
    assets: OFFER_SIZE,
    tick,
    expiry: BigInt(MIDNIGHT_MARKET.maturity) - 1n,
  })
  assert.notEqual(callback, zeroAddress)
  await assert.rejects(
    prepareBlueCallbackPosition(prepareParameters),
    /callback already has a Blue supply position/,
  )
  assert.equal(
    (await publicClient.readContract({ address: callback, abi: blueBuyCallbackAbi, functionName: 'OWNER' })).toLowerCase(),
    maker.address.toLowerCase(),
  )

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

  const capacityBefore = await callbackBound(callback, callbackData)
  const sharesBefore = await blueSupplyShares(callback)
  const suppliedBefore = await blueSupplyAssets(callback)
  const makerPositionBefore = await midnightPosition(maker.address)
  const borrowerPositionBefore = await midnightPosition(borrower.address)
  const borrowerUsdcBefore = await tokenBalance(USDC, borrower.address)
  assertApprox(suppliedBefore, OFFER_SIZE)
  assert(capacityBefore >= OFFER_SIZE - 2n, 'callback cannot immediately fund the offer')

  const firstTake = await takeOffer({
    publicClient,
    walletClient: wallet(borrower),
    account: borrower,
    offer,
    ratifierData,
    buyerAssets: FIRST_FILL,
  })
  const [firstBuyerAssets, firstSellerAssets] = firstTake.result
  assertApprox(firstBuyerAssets, FIRST_FILL)

  const capacityAfterFirst = await callbackBound(callback, callbackData)
  const sharesAfterFirst = await blueSupplyShares(callback)
  const suppliedAfterFirst = await blueSupplyAssets(callback)
  const makerPositionAfterFirst = await midnightPosition(maker.address)
  const borrowerPositionAfterFirst = await midnightPosition(borrower.address)
  const borrowerUsdcAfterFirst = await tokenBalance(USDC, borrower.address)

  assert(sharesAfterFirst < sharesBefore, 'the callback did not withdraw from Blue')
  assertApprox(suppliedBefore - suppliedAfterFirst, firstBuyerAssets)
  assert(capacityAfterFirst < capacityBefore, 'the callback capacity did not decrease')
  assert.equal(makerPositionAfterFirst[0] - makerPositionBefore[0], firstTake.units)
  assert.equal(borrowerPositionAfterFirst[4] - borrowerPositionBefore[4], firstTake.units)
  assert.equal(borrowerUsdcAfterFirst - borrowerUsdcBefore, firstSellerAssets)

  const secondTake = await takeOffer({
    publicClient,
    walletClient: wallet(borrower),
    account: borrower,
    offer,
    ratifierData,
    buyerAssets: SECOND_FILL,
  })
  const [secondBuyerAssets] = secondTake.result
  assertApprox(secondBuyerAssets, SECOND_FILL)

  const capacityAfterSecond = await callbackBound(callback, callbackData)
  const suppliedAfterSecond = await blueSupplyAssets(callback)
  const makerPositionAfterSecond = await midnightPosition(maker.address)
  assertApprox(suppliedAfterFirst - suppliedAfterSecond, secondBuyerAssets)
  assert(capacityAfterSecond < capacityAfterFirst)
  assert.equal(makerPositionAfterSecond[0] - makerPositionAfterFirst[0], secondTake.units)

  const liquidityRemoved = parseUnits('60', 6)
  await send(maker, {
    address: BLUE,
    abi: blueAbi,
    functionName: 'withdraw',
    args: [BLUE_MARKET, liquidityRemoved, 0n, callback, maker.address],
  })
  const staleBound = await callbackBound(callback, callbackData)
  assert(staleBound <= capacityAfterSecond - liquidityRemoved + 2n)

  await assert.rejects(
    simulateTake({
      publicClient,
      account: borrower,
      offer,
      ratifierData,
      buyerAssets: parseUnits('10', 6),
    }),
    /reverted/,
  )

  const apr = TickLib.tickToApr(tick, BigInt(MIDNIGHT_MARKET.maturity) - block.timestamp)
  console.log('Blue callback limit order')
  console.log(`  callback:             ${callback}`)
  console.log(`  fixed APR:            ${(Number(apr) / 1e16).toFixed(4)}%`)
  console.log(`  Blue supplied before: ${displayUsdc(suppliedBefore)}`)
  console.log(`  first fill:           ${displayUsdc(firstBuyerAssets)}`)
  console.log(`  borrower received:    ${displayUsdc(firstSellerAssets)}`)
  console.log(`  Blue after first:     ${displayUsdc(suppliedAfterFirst)}`)
  console.log(`  Blue after second:    ${displayUsdc(suppliedAfterSecond)}`)
  console.log(`  callback capacity:    ${displayUsdc(staleBound)}`)
  console.log(`  stale-liquidity take: reverted as expected`)
  console.log('PASS')
}

main().catch((error: unknown) => {
  console.error(error)
  process.exitCode = 1
})
