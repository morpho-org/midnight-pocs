import type { Abi, Address, Hex } from 'viem'
import { artifacts } from './artifacts'
import {
  ERC20_ABI,
  MIDNIGHT,
  MORPHO_BLUE,
  SETTER_RATIFIER,
  USDC,
  deploy,
  freshAddress,
  fundUsdc,
  publicClient,
  read,
  send,
  warpTo,
  type TxRecord,
} from './chain'

const BORROWER = artifacts.RollingBorrower.abi as unknown as Abi
const ROLLER = artifacts.MidnightRoller.abi as unknown as Abi
const LENDER = artifacts.FlashRollLender.abi as unknown as Abi
const COLLATERAL_ABI = artifacts.MockCollateral.abi as unknown as Abi
const HELPER = artifacts.DemoHelper.abi as unknown as Abi
const MIDNIGHT_ABI = artifacts.IMidnight.abi as unknown as Abi
const RATIFIER = artifacts.ISetterRatifier.abi as unknown as Abi
const ERC20 = ERC20_ABI as unknown as Abi

const ZERO = '0x0000000000000000000000000000000000000000' as Address
const ZERO32 = `0x${'00'.repeat(32)}` as Hex
const WAD = 10n ** 18n
const DAY = 86_400n
const APR = 50_000_000_000_000_000n
const TICK_SPACING = 4n
const LLTV = 965_000_000_000_000_000n
const LIQUIDATION_CURSOR = 300_000_000_000_000_000n
export const FACE = 1_000_000_000_000n
export const COLLATERAL = 1_100_000_000_000n
const ORACLE_PRICE = 10n ** 36n
const RESERVE_MARGIN = 1_000_000n
const MAX_UINT = 2n ** 256n - 1n
const TRANCHE_COUNT = 10n
const TRANCHE_UNITS = FACE / TRANCHE_COUNT
const TRANCHE_COLLATERAL = COLLATERAL / TRANCHE_COUNT

export type FundingMode = 'general' | 'treasury' | 'tranche' | 'flash'

export type Roles = {
  borrowerOperator: Address
  lenderOperator: Address
  capitalOwner: Address
  sponsor: Address
  repayer: Address
  liquidator: Address
  useOfProceeds: Address
}

export type Ctx = {
  fundingMode: FundingMode
  roles: Roles
  borrower: Address
  roller: Address
  lender: Address
  oldLender: Address
  newLender: Address
  gate: Address
  collateral: Address
  oracle: Address
  helper: Address
  maturityOld: bigint
  maturityNew: bigint
  oldId: Hex
  newId: Hex
  tick: bigint
  advance: bigint
  dailyCost: bigint
  trancheAdvance: bigint
  rollCarry: bigint
  oldUnits: bigint
  newUnits: bigint
  oldOffer?: unknown
  newOffer?: unknown
  oldRatifierData: Hex
  newRatifierData: Hex
}

export type Snapshot = {
  block: bigint
  balances: Record<'blue' | 'owner' | 'lender' | 'borrower' | 'proceeds' | 'sponsor' | 'repayer', bigint>
  oldDebt: bigint
  newDebt: bigint
  oldCollateral: bigint
  newCollateral: bigint
  oldCredit: bigint
  newCredit: bigint
  walletCollateral: bigint
}

export type StepResult = { txs: TxRecord[]; snap: Snapshot }
export type Step = {
  title: string
  eyebrow: string
  summary: string
  detail: string
  run: (ctx: Ctx) => Promise<TxRecord[]>
}

export function emptyCtx(fundingMode: FundingMode = 'flash'): Ctx {
  return {
    fundingMode,
    roles: {
      borrowerOperator: freshAddress(),
      lenderOperator: freshAddress(),
      capitalOwner: freshAddress(),
      sponsor: freshAddress(),
      repayer: freshAddress(),
      liquidator: freshAddress(),
      useOfProceeds: freshAddress(),
    },
    borrower: ZERO,
    roller: ZERO,
    lender: ZERO,
    oldLender: ZERO,
    newLender: ZERO,
    gate: ZERO,
    collateral: ZERO,
    oracle: ZERO,
    helper: ZERO,
    maturityOld: 0n,
    maturityNew: 0n,
    oldId: ZERO32,
    newId: ZERO32,
    tick: 0n,
    advance: 0n,
    dailyCost: 0n,
    trancheAdvance: 0n,
    rollCarry: 0n,
    oldUnits: 0n,
    newUnits: 0n,
    oldRatifierData: '0x',
    newRatifierData: '0x',
  }
}

export const cloneCtx = (ctx: Ctx): Ctx => structuredClone(ctx)

const market = (ctx: Ctx, maturity: bigint) => ({
  chainId: 8453n,
  midnight: MIDNIGHT,
  loanToken: USDC,
  collateralParams: [
    { token: ctx.collateral, lltv: LLTV, liquidationCursor: LIQUIDATION_CURSOR, oracle: ctx.oracle },
  ],
  maturity,
  rcfThreshold: 0n,
  enterGate: ctx.gate,
  liquidatorGate: ctx.gate,
})

const offer = (ctx: Ctx, maturity: bigint, maker: Address = ctx.lender, maxUnits: bigint = FACE) => ({
  market: market(ctx, maturity),
  buy: true,
  maker,
  start: 0n,
  expiry: maturity,
  tick: ctx.tick,
  group: `0x${maturity.toString(16).padStart(64, '0')}` as Hex,
  callback: ZERO,
  callbackData: '0x' as Hex,
  receiverIfMakerIsSeller: ZERO,
  ratifier: SETTER_RATIFIER,
  reduceOnly: false,
  maxUnits,
  maxAssets: 0n,
  continuousFeeCap: 2n ** 256n - 1n,
})

const ratifierData = (root: Hex) =>
  `0x${root.slice(2)}${'0'.repeat(64)}${(96n).toString(16).padStart(64, '0')}${'0'.repeat(64)}` as Hex

async function rootFor(ctx: Ctx, value: unknown) {
  return read<Hex>(ctx.helper, HELPER, 'hashOffer', [value])
}

async function prepareEoaLender(ctx: Ctx, lender: Address = ctx.roles.capitalOwner) {
  return [
    await send(lender, 'Authorize Setter Ratifier', {
      address: MIDNIGHT,
      abi: MIDNIGHT_ABI,
      functionName: 'setIsAuthorized',
      args: [SETTER_RATIFIER, true, lender],
    }),
    await send(lender, 'Approve lender USDC', {
      address: USDC,
      abi: ERC20,
      functionName: 'approve',
      args: [MIDNIGHT, MAX_UINT],
    }),
  ]
}

async function ratifyEoaOffer(ctx: Ctx, root: Hex, label: string, lender: Address = ctx.roles.capitalOwner) {
  return send(lender, label, {
    address: SETTER_RATIFIER,
    abi: RATIFIER,
    functionName: 'setIsRootRatified',
    args: [lender, root, true],
  })
}

async function fundCarryReserve(ctx: Ctx, amount: bigint) {
  return [
    await fundUsdc(ctx.roles.sponsor, amount, 'Fund reserve sponsor'),
    await send(ctx.roles.sponsor, 'Transfer carry reserve', {
      address: USDC,
      abi: ERC20,
      functionName: 'transfer',
      args: [ctx.borrower, amount],
    }),
  ]
}

async function authorizeNextRoll(ctx: Ctx) {
  await warpTo(ctx.maturityOld - 3_600n)
  const txs: TxRecord[] = []
  txs.push(await send(ctx.roles.borrowerOperator, 'Touch next Midnight market', {
    address: MIDNIGHT,
    abi: MIDNIGHT_ABI,
    functionName: 'touchMarket',
    args: [market(ctx, ctx.maturityNew)],
  }))
  ctx.newId = await read<Hex>(ctx.helper, HELPER, 'toId', [market(ctx, ctx.maturityNew)])
  ctx.newOffer = ctx.fundingMode === 'general'
    ? offer(ctx, ctx.maturityNew, ctx.newLender, FACE * 2n)
    : offer(ctx, ctx.maturityNew)
  const root = await rootFor(ctx, ctx.newOffer)
  ctx.newRatifierData = ratifierData(root)
  if (ctx.fundingMode === 'general') {
    txs.push(await fundUsdc(ctx.newLender, FACE * 2n, 'Fund replacement lender'))
    txs.push(...await prepareEoaLender(ctx, ctx.newLender))
    txs.push(await ratifyEoaOffer(ctx, root, 'Ratify replacement offer', ctx.newLender))
  } else if (ctx.fundingMode === 'flash') {
    txs.push(await send(ctx.roles.capitalOwner, 'Ratify next lender offer', {
      address: ctx.lender,
      abi: LENDER,
      functionName: 'setRootRatified',
      args: [root, true],
    }))
    const authorization = await read<Hex>(ctx.borrower, BORROWER, 'rollAuthorizationHash', [
      ctx.newOffer,
      ctx.newRatifierData,
      FACE,
      market(ctx, ctx.maturityOld),
      FACE,
      COLLATERAL,
    ])
    txs.push(await send(ctx.roles.borrowerOperator, 'Authorize exact roll', {
      address: ctx.borrower,
      abi: BORROWER,
      functionName: 'setRollAuthorization',
      args: [authorization, true],
    }))
  } else {
    txs.push(await ratifyEoaOffer(ctx, root, 'Ratify next lender offer'))
  }
  return txs
}

export async function prepareFollowingRoll(ctx: Ctx) {
  ctx.maturityOld = ctx.maturityNew
  ctx.oldId = ctx.newId
  ctx.oldOffer = ctx.newOffer
  ctx.oldRatifierData = ctx.newRatifierData
  ctx.oldUnits = ctx.newUnits
  if (ctx.fundingMode === 'general') {
    ctx.oldLender = ctx.newLender
    ctx.newLender = freshAddress()
  }
  ctx.maturityNew = ctx.maturityOld + DAY
  const txs = ctx.fundingMode === 'general' ? [] : await fundCarryReserve(ctx, ctx.rollCarry)
  txs.push(...await authorizeNextRoll(ctx))
  return txs
}

export const STEPS: Step[] = [
  {
    eyebrow: 'Local setup',
    title: 'Deploy the rolling stack',
    summary: 'Deploy the borrower, lender adapter, gate, collateral and oracle onto the local Base fork.',
    detail: 'These are real contract-creation transactions sent to Anvil. The deployed Base Midnight, Morpho Blue and USDC contracts are reused from the fork.',
    run: async (ctx) => {
      const txs: TxRecord[] = []
      const helper = await deploy(ctx.roles.borrowerOperator, 'Deploy DemoHelper', artifacts.DemoHelper)
      ctx.helper = helper.address
      txs.push(helper.tx)
      if (ctx.fundingMode === 'general') {
        ctx.borrower = ctx.roles.borrowerOperator
        const roller = await deploy(ctx.roles.borrowerOperator, 'Deploy MidnightRoller', artifacts.MidnightRoller, [
          MIDNIGHT,
        ])
        ctx.roller = roller.address
        txs.push(roller.tx)
      } else {
        const borrower = await deploy(ctx.roles.borrowerOperator, 'Deploy RollingBorrower', artifacts.RollingBorrower, [
          MIDNIGHT,
          ctx.roles.borrowerOperator,
        ])
        ctx.borrower = borrower.address
        txs.push(borrower.tx)
      }
      const collateral = await deploy(ctx.roles.borrowerOperator, 'Deploy MockCollateral', artifacts.MockCollateral)
      ctx.collateral = collateral.address
      txs.push(collateral.tx)
      const oracle = await deploy(ctx.roles.borrowerOperator, 'Deploy FixedOracle', artifacts.FixedOracle, [ORACLE_PRICE])
      ctx.oracle = oracle.address
      txs.push(oracle.tx)
      if (ctx.fundingMode === 'general') {
        ctx.oldLender = ctx.roles.capitalOwner
        ctx.newLender = ctx.roles.lenderOperator
        ctx.lender = ctx.oldLender
      } else if (ctx.fundingMode === 'flash') {
        const lender = await deploy(ctx.roles.lenderOperator, 'Deploy FlashRollLender', artifacts.FlashRollLender, [
          MORPHO_BLUE,
          MIDNIGHT,
          USDC,
          SETTER_RATIFIER,
          ctx.borrower,
          ctx.roles.lenderOperator,
          ctx.roles.capitalOwner,
        ])
        ctx.lender = lender.address
        txs.push(lender.tx)
      } else {
        ctx.lender = ctx.roles.capitalOwner
      }
      if (ctx.fundingMode !== 'general') {
        const gate = await deploy(ctx.roles.borrowerOperator, 'Deploy TwoPartyGate', artifacts.TwoPartyGate, [
          ctx.lender,
          ctx.borrower,
          ctx.roles.liquidator,
        ])
        ctx.gate = gate.address
        txs.push(gate.tx)
      }
      return txs
    },
  },
  {
    eyebrow: 'Market policy',
    title: 'Pin the market and permissions',
    summary: 'Configure the only permitted market shape and give the lender adapter one narrowly scoped roll permission.',
    detail: 'Every field except maturity is pinned. A future roll cannot swap the token, oracle, LLTV, liquidation parameters or gates.',
    run: async (ctx) => {
      const now = (await publicClient.getBlock()).timestamp
      ctx.maturityOld = now + DAY
      ctx.maturityNew = now + 2n * DAY
      if (ctx.fundingMode === 'general') {
        return [
          await send(ctx.roles.borrowerOperator, 'Approve collateral to Midnight', {
            address: ctx.collateral,
            abi: ERC20,
            functionName: 'approve',
            args: [MIDNIGHT, MAX_UINT],
          }),
          await send(ctx.roles.borrowerOperator, 'Approve USDC to Midnight', {
            address: USDC,
            abi: ERC20,
            functionName: 'approve',
            args: [MIDNIGHT, MAX_UINT],
          }),
          await send(ctx.roles.borrowerOperator, 'Prime roller collateral approval', {
            address: ctx.roller,
            abi: ROLLER,
            functionName: 'setApprovalMax',
            args: [ctx.collateral],
          }),
          await send(ctx.roles.borrowerOperator, 'Prime roller USDC approval', {
            address: ctx.roller,
            abi: ROLLER,
            functionName: 'setApprovalMax',
            args: [USDC],
          }),
          await send(ctx.roles.borrowerOperator, 'Authorize singleton roller', {
            address: MIDNIGHT,
            abi: MIDNIGHT_ABI,
            functionName: 'setIsAuthorized',
            args: [ctx.roller, true, ctx.borrower],
          }),
        ]
      }
      const txs = [
        await send(ctx.roles.borrowerOperator, 'Configure market template', {
          address: ctx.borrower,
          abi: BORROWER,
          functionName: 'configureMarket',
          args: [market(ctx, ctx.maturityOld)],
        }),
        await send(ctx.roles.borrowerOperator, 'Approve collateral to Midnight', {
          address: ctx.borrower,
          abi: BORROWER,
          functionName: 'approveToken',
          args: [ctx.collateral],
        }),
        await send(ctx.roles.borrowerOperator, 'Approve USDC to Midnight', {
          address: ctx.borrower,
          abi: BORROWER,
          functionName: 'approveToken',
          args: [USDC],
        }),
      ]
      if (ctx.fundingMode === 'flash') {
        txs.splice(1, 0, await send(ctx.roles.borrowerOperator, 'Set roll executor', {
          address: ctx.borrower,
          abi: BORROWER,
          functionName: 'setRollExecutor',
          args: [ctx.lender],
        }))
      }
      return txs
    },
  },
  {
    eyebrow: 'Collateral',
    title: 'Pledge the collateral',
    summary: 'Mint the demo collateral to the borrower and supply it into the first Midnight maturity.',
    detail: 'The token and fixed oracle are intentionally plain. They stand in for the collateral and valuation system used by a real integration.',
    run: async (ctx) => {
      if (ctx.fundingMode === 'general') {
        const txs = [
          await send(ctx.roles.borrowerOperator, 'Mint collateral', {
            address: ctx.collateral,
            abi: COLLATERAL_ABI,
            functionName: 'mint',
            args: [ctx.borrower, COLLATERAL],
          }),
          await send(ctx.roles.borrowerOperator, 'Supply collateral to Midnight', {
            address: MIDNIGHT,
            abi: MIDNIGHT_ABI,
            functionName: 'supplyCollateral',
            args: [market(ctx, ctx.maturityOld), 0n, COLLATERAL, ctx.borrower],
          }),
        ]
        ctx.oldId = await read<Hex>(ctx.helper, HELPER, 'toId', [market(ctx, ctx.maturityOld)])
        return txs
      }
      const txs = [
        await send(ctx.roles.borrowerOperator, 'Mint collateral', {
          address: ctx.collateral,
          abi: COLLATERAL_ABI,
          functionName: 'mint',
          args: [ctx.borrower, COLLATERAL],
        }),
        await send(ctx.roles.borrowerOperator, 'Supply collateral to Midnight', {
          address: ctx.borrower,
          abi: BORROWER,
          functionName: 'supplyCollateral',
          args: [market(ctx, ctx.maturityOld), COLLATERAL],
        }),
      ]
      ctx.oldId = await read<Hex>(ctx.helper, HELPER, 'toId', [market(ctx, ctx.maturityOld)])
      return txs
    },
  },
  {
    eyebrow: 'Initial funding',
    title: 'Open the first maturity',
    summary: 'The capital owner funds the lender adapter, which advances USDC to the borrower through Midnight.',
    detail: 'The advance is discounted from face by one day of carry. It goes directly to the use-of-proceeds account; Midnight records debt and lender credit but holds no float.',
    run: async (ctx) => {
      const txs: TxRecord[] = []
      txs.push(await send(ctx.roles.borrowerOperator, 'Touch first Midnight market', {
        address: MIDNIGHT,
        abi: MIDNIGHT_ABI,
        functionName: 'touchMarket',
        args: [market(ctx, ctx.maturityOld)],
      }))
      ctx.oldId = await read<Hex>(ctx.helper, HELPER, 'toId', [market(ctx, ctx.maturityOld)])
      const targetPrice = (WAD * WAD) / (WAD + APR / 365n)
      ctx.tick = await read<bigint>(ctx.helper, HELPER, 'priceToTick', [targetPrice, TICK_SPACING])
      const price = await read<bigint>(ctx.helper, HELPER, 'tickToPrice', [ctx.tick])
      ctx.advance = (FACE * price) / WAD
      ctx.dailyCost = FACE - ctx.advance
      ctx.trancheAdvance = (TRANCHE_UNITS * price) / WAD
      ctx.rollCarry = ctx.fundingMode === 'tranche'
        ? TRANCHE_COUNT * (TRANCHE_UNITS - ctx.trancheAdvance)
        : ctx.dailyCost
      if (ctx.fundingMode === 'general') {
        txs.push(await fundUsdc(ctx.oldLender, ctx.advance, 'Fund original lender'))
        txs.push(...await prepareEoaLender(ctx, ctx.oldLender))
      } else if (ctx.fundingMode === 'flash') {
        txs.push(await fundUsdc(ctx.roles.capitalOwner, ctx.advance, 'Fund capital owner'))
        txs.push(await send(ctx.roles.capitalOwner, 'Fund lender adapter', {
          address: USDC,
          abi: ERC20,
          functionName: 'transfer',
          args: [ctx.lender, ctx.advance],
        }))
      } else {
        const standby = ctx.fundingMode === 'treasury' ? ctx.advance : ctx.trancheAdvance
        txs.push(await fundUsdc(ctx.roles.capitalOwner, ctx.advance + standby, 'Fund lender treasury'))
        txs.push(...await prepareEoaLender(ctx))
      }
      ctx.oldOffer = ctx.fundingMode === 'general'
        ? offer(ctx, ctx.maturityOld, ctx.oldLender)
        : offer(ctx, ctx.maturityOld)
      const root = await rootFor(ctx, ctx.oldOffer)
      ctx.oldRatifierData = ratifierData(root)
      if (ctx.fundingMode === 'general') {
        txs.push(await ratifyEoaOffer(ctx, root, 'Ratify original lender offer', ctx.oldLender))
      } else if (ctx.fundingMode === 'flash') {
        txs.push(await send(ctx.roles.capitalOwner, 'Ratify first lender offer', {
          address: ctx.lender,
          abi: LENDER,
          functionName: 'setRootRatified',
          args: [root, true],
        }))
      } else {
        txs.push(await ratifyEoaOffer(ctx, root, 'Ratify first lender offer'))
      }
      if (ctx.fundingMode === 'general') {
        txs.push(await send(ctx.roles.borrowerOperator, 'Open first maturity', {
          address: MIDNIGHT,
          abi: MIDNIGHT_ABI,
          functionName: 'take',
          args: [ctx.oldOffer, ctx.oldRatifierData, FACE, ctx.borrower, ctx.roles.useOfProceeds, ZERO, '0x'],
        }))
        ctx.oldUnits = FACE
      } else {
        txs.push(await send(ctx.roles.borrowerOperator, 'Open first maturity', {
          address: ctx.borrower,
          abi: BORROWER,
          functionName: 'open',
          args: [ctx.oldOffer, ctx.oldRatifierData, FACE, ctx.roles.useOfProceeds],
        }))
      }
      return txs
    },
  },
  {
    eyebrow: 'Carry',
    title: 'Fund the interest reserve',
    summary: 'The sponsor funds only the permanent difference between the new advance and the old face.',
    detail: 'The flash loan will bridge principal timing. It cannot pay interest that remains owed after the transaction, so the borrower supplies one day of carry.',
    run: async (ctx) => ctx.fundingMode === 'general' ? [] : fundCarryReserve(ctx, ctx.rollCarry + RESERVE_MARGIN),
  },
  {
    eyebrow: 'Consent',
    title: 'Approve the next maturity',
    summary: 'The capital owner approves the offer; the borrower separately approves the exact roll terms for one use.',
    detail: 'Separating these approvals means the lender operator can execute the roll but cannot choose a punitive tick or create an unrelated use of capital.',
    run: authorizeNextRoll,
  },
  {
    eyebrow: 'Atomic roll',
    title: 'Execute the flash-funded roll',
    summary: 'One transaction moves the full face, repays the old maturity and re-pledges the collateral.',
    detail: 'Morpho Blue supplies the temporary face. Midnight releases the old lender credit inside the same transaction, allowing Blue to be repaid before control returns.',
    run: async (ctx) => {
      if (ctx.fundingMode === 'general') {
        const txs = [await send(ctx.roles.borrowerOperator, 'Refinance into Lender B offer', {
          address: ctx.roller,
          abi: ROLLER,
          functionName: 'roll',
          args: [{
            oldMarket: market(ctx, ctx.maturityOld),
            oldCollateralIndex: 0n,
            newCollateralIndex: 0n,
            collateralAmount: COLLATERAL,
            oldUnits: ctx.oldUnits,
            maxNewUnits: FACE * 2n,
            maxLtv: 0n,
            newOffer: ctx.newOffer,
            ratifierData: ctx.newRatifierData,
          }],
        })]
        ctx.newUnits = await midnightValue(ctx, 'debt', ctx.newId, ctx.borrower)
        ctx.rollCarry = ctx.newUnits - ctx.oldUnits
        txs.push(await send(ctx.oldLender, 'Original lender withdraws repaid credit', {
          address: MIDNIGHT,
          abi: MIDNIGHT_ABI,
          functionName: 'withdraw',
          args: [market(ctx, ctx.maturityOld), ctx.oldUnits, ctx.oldLender, ctx.oldLender],
        }))
        return txs
      }
      if (ctx.fundingMode === 'flash') {
        return [await send(ctx.roles.lenderOperator, 'Execute full-face flash roll', {
          address: ctx.lender,
          abi: LENDER,
          functionName: 'executeRoll',
          args: [{
            newOffer: ctx.newOffer,
            ratifierData: ctx.newRatifierData,
            oldMarket: market(ctx, ctx.maturityOld),
            units: FACE,
            collateralAmount: COLLATERAL,
          }],
        })]
      }

      const txs: TxRecord[] = []
      const count = ctx.fundingMode === 'tranche' ? TRANCHE_COUNT : 1n
      const units = ctx.fundingMode === 'tranche' ? TRANCHE_UNITS : FACE
      const collateralAmount = ctx.fundingMode === 'tranche' ? TRANCHE_COLLATERAL : COLLATERAL
      for (let index = 0n; index < count; index += 1n) {
        const suffix = ctx.fundingMode === 'tranche' ? ` ${index + 1n} of ${TRANCHE_COUNT}` : ''
        const rollLabel = ctx.fundingMode === 'tranche' ? `Roll tranche${suffix}` : 'Execute treasury-funded roll'
        txs.push(await send(ctx.roles.borrowerOperator, rollLabel, {
          address: ctx.borrower,
          abi: BORROWER,
          functionName: 'roll',
          args: [
            ctx.newOffer,
            ctx.newRatifierData,
            units,
            market(ctx, ctx.maturityOld),
            units,
            collateralAmount,
          ],
        }))
        txs.push(await send(ctx.roles.capitalOwner, `Withdraw released credit${suffix}`, {
          address: MIDNIGHT,
          abi: MIDNIGHT_ABI,
          functionName: 'withdraw',
          args: [market(ctx, ctx.maturityOld), units, ctx.roles.capitalOwner, ctx.roles.capitalOwner],
        }))
      }
      return txs
    },
  },
  {
    eyebrow: 'Lender return',
    title: 'Sweep the earned carry',
    summary: 'After the critical roll completes, the lender adapter pays the day’s carry to the beneficiary.',
    detail: 'Keeping payout outside the flash callback prevents a beneficiary problem from blocking the maturity roll.',
    run: async (ctx) => ctx.fundingMode === 'flash' ? [
      await send(ctx.roles.lenderOperator, 'Sweep carry to capital owner', {
        address: ctx.lender,
        abi: LENDER,
        functionName: 'sweepAsset',
        args: [ctx.dailyCost],
      }),
    ] : [],
  },
  {
    eyebrow: 'Repayment',
    title: 'Repay the final maturity',
    summary: 'An external repayment source returns the face to the borrower, which retires the final Midnight debt.',
    detail: 'This represents the underlying financing being repaid. It is separate from the rolling mechanism itself.',
    run: async (ctx) => {
      const amount = ctx.fundingMode === 'general' ? ctx.newUnits : FACE
      const txs = [
        await fundUsdc(ctx.roles.repayer, amount, 'Fund repayment source'),
        await send(ctx.roles.repayer, 'Send final repayment', {
        address: USDC,
        abi: ERC20,
        functionName: 'transfer',
          args: [ctx.borrower, amount],
        }),
      ]
      if (ctx.fundingMode === 'general') {
        txs.push(await send(ctx.roles.borrowerOperator, 'Repay final Midnight debt', {
          address: MIDNIGHT,
          abi: MIDNIGHT_ABI,
          functionName: 'repay',
          args: [market(ctx, ctx.maturityNew), amount, ctx.borrower, ZERO, '0x'],
        }))
      } else {
        txs.push(await send(ctx.roles.borrowerOperator, 'Repay final Midnight debt', {
          address: ctx.borrower,
          abi: BORROWER,
          functionName: 'repay',
          args: [market(ctx, ctx.maturityNew), FACE],
        }))
      }
      return txs
    },
  },
  {
    eyebrow: 'Close',
    title: 'Return principal and collateral',
    summary: 'The capital owner withdraws lender credit; the borrower releases its collateral.',
    detail: 'The lender receives face plus carry, both Midnight positions finish at zero, and the collateral returns to the borrower operator.',
    run: async (ctx) => {
      const txs: TxRecord[] = []
      if (ctx.fundingMode === 'general') {
        txs.push(await send(ctx.newLender, 'Replacement lender withdraws final credit', {
          address: MIDNIGHT,
          abi: MIDNIGHT_ABI,
          functionName: 'withdraw',
          args: [market(ctx, ctx.maturityNew), ctx.newUnits, ctx.newLender, ctx.newLender],
        }))
      } else if (ctx.fundingMode === 'flash') {
        txs.push(await send(ctx.roles.capitalOwner, 'Withdraw final lender credit', {
          address: ctx.lender,
          abi: LENDER,
          functionName: 'withdrawCredit',
          args: [market(ctx, ctx.maturityNew), FACE],
        }))
        txs.push(await send(ctx.roles.capitalOwner, 'Sweep returned principal', {
          address: ctx.lender,
          abi: LENDER,
          functionName: 'sweepAsset',
          args: [FACE],
        }))
      } else {
        txs.push(await send(ctx.roles.capitalOwner, 'Withdraw final lender credit', {
          address: MIDNIGHT,
          abi: MIDNIGHT_ABI,
          functionName: 'withdraw',
          args: [market(ctx, ctx.maturityNew), FACE, ctx.roles.capitalOwner, ctx.roles.capitalOwner],
        }))
      }
      if (ctx.fundingMode === 'general') {
        txs.push(await send(ctx.roles.borrowerOperator, 'Release collateral', {
          address: MIDNIGHT,
          abi: MIDNIGHT_ABI,
          functionName: 'withdrawCollateral',
          args: [market(ctx, ctx.maturityNew), 0n, COLLATERAL, ctx.borrower, ctx.roles.borrowerOperator],
        }))
      } else {
        txs.push(await send(ctx.roles.borrowerOperator, 'Release collateral', {
          address: ctx.borrower,
          abi: BORROWER,
          functionName: 'withdrawCollateral',
          args: [market(ctx, ctx.maturityNew), COLLATERAL, ctx.roles.borrowerOperator],
        }))
      }
      return txs
    },
  },
]

async function balance(token: Address, account: Address) {
  return read<bigint>(token, token === USDC ? ERC20 : COLLATERAL_ABI, 'balanceOf', [account])
}

async function midnightValue(ctx: Ctx, functionName: 'debt' | 'credit' | 'collateral', id: Hex, account: Address) {
  if (id === ZERO32) return 0n
  const args = functionName === 'collateral' ? [id, account, 0n] : [id, account]
  return read<bigint>(MIDNIGHT, MIDNIGHT_ABI, functionName, args)
}

export async function snapshot(ctx: Ctx): Promise<Snapshot> {
  const deployed = ctx.borrower !== ZERO
  const [block, blue, owner, lender, borrowerCash, proceeds, sponsor, repayer] = await Promise.all([
    publicClient.getBlockNumber(),
    balance(USDC, MORPHO_BLUE),
    balance(USDC, ctx.roles.capitalOwner),
    deployed ? balance(USDC, ctx.lender) : 0n,
    deployed ? balance(USDC, ctx.borrower) : 0n,
    balance(USDC, ctx.roles.useOfProceeds),
    balance(USDC, ctx.roles.sponsor),
    balance(USDC, ctx.roles.repayer),
  ])

  const [oldDebt, newDebt, oldCollateral, newCollateral, oldCredit, newCredit, walletCollateral] = deployed
    ? await Promise.all([
        midnightValue(ctx, 'debt', ctx.oldId, ctx.borrower),
        midnightValue(ctx, 'debt', ctx.newId, ctx.borrower),
        midnightValue(ctx, 'collateral', ctx.oldId, ctx.borrower),
        midnightValue(ctx, 'collateral', ctx.newId, ctx.borrower),
        midnightValue(ctx, 'credit', ctx.oldId, ctx.fundingMode === 'general' ? ctx.oldLender : ctx.lender),
        midnightValue(ctx, 'credit', ctx.newId, ctx.fundingMode === 'general' ? ctx.newLender : ctx.lender),
        balance(ctx.collateral, ctx.roles.borrowerOperator),
      ])
    : [0n, 0n, 0n, 0n, 0n, 0n, 0n]

  return {
    block,
    balances: { blue, owner, lender, borrower: borrowerCash, proceeds, sponsor, repayer },
    oldDebt,
    newDebt,
    oldCollateral,
    newCollateral,
    oldCredit,
    newCredit,
    walletCollateral,
  }
}
