import { resetFork, revertChain, snapshotChain } from './chain'
import { FACE, STEPS, cloneCtx, emptyCtx, prepareFollowingRoll, snapshot, type FundingMode } from './steps'

const ALL_MODES: FundingMode[] = ['general', 'treasury', 'tranche', 'flash']
const requestedMode = process.argv[2] as FundingMode | undefined
if (requestedMode && !ALL_MODES.includes(requestedMode)) throw new Error(`Unknown funding mode: ${requestedMode}`)
const MODES = requestedMode ? [requestedMode] : ALL_MODES

const assert = (condition: boolean, message: string) => {
  if (!condition) throw new Error(message)
}

async function verifyForward(mode: FundingMode) {
  await resetFork()
  const ctx = emptyCtx(mode)
  let rollBlueBefore = 0n
  let transactionCount = 0

  for (let index = 0; index < STEPS.length; ++index) {
    if (index === 6) rollBlueBefore = (await snapshot(ctx)).balances.blue
    const txs = await STEPS[index].run(ctx)
    transactionCount += txs.length
    const state = await snapshot(ctx)

    if (index === 3) {
      assert(state.oldDebt === FACE, 'opening debt is not face')
      if (mode === 'flash') assert(state.balances.lender === 0n, 'flash lender retained idle opening principal')
      if (mode === 'treasury') assert(state.balances.lender === ctx.advance, 'treasury standby advance is wrong')
      if (mode === 'tranche') assert(state.balances.lender === ctx.trancheAdvance, 'tranche buffer is wrong')
    }
    if (index === 6) {
      if (mode === 'flash') assert(state.balances.blue === rollBlueBefore, 'Morpho Blue flash principal did not reconcile')
      assert(state.oldDebt === 0n && (mode === 'general' ? state.newDebt > FACE : state.newDebt === FACE), 'roll did not move the debt')
      assert(state.oldCollateral === 0n && state.newCollateral > 0n, 'roll did not move the collateral')
    }
    if (index === STEPS.length - 1) {
      assert(state.oldDebt === 0n && state.newDebt === 0n, 'final debt remains')
      assert(state.oldCollateral === 0n && state.newCollateral === 0n, 'final collateral remains')
      if (mode === 'flash') assert(state.balances.lender === 0n, 'lender adapter did not finish empty')
      assert(state.walletCollateral > 0n, 'collateral did not return to the borrower operator')
    }
  }

  return transactionCount
}

async function verifyUndo(mode: FundingMode) {
  await resetFork()
  const ctx = emptyCtx(mode)
  for (let index = 0; index <= 5; ++index) await STEPS[index].run(ctx)

  const beforeCtx = cloneCtx(ctx)
  const beforeRoll = await snapshotChain()
  await STEPS[6].run(ctx)
  assert((await snapshot(ctx)).newDebt >= FACE, 'roll did not execute before undo')

  assert(await revertChain(beforeRoll), 'evm_revert failed')
  const restored = await snapshot(beforeCtx)
  assert(restored.oldDebt === FACE && restored.newDebt === 0n, 'undo did not restore the old maturity')

  await STEPS[6].run(beforeCtx)
  assert((await snapshot(beforeCtx)).newDebt >= FACE, 'roll could not execute again after undo')
}

async function verifyRepeatedRolls(mode: FundingMode) {
  await resetFork()
  const ctx = emptyCtx(mode)
  for (let index = 0; index <= 5; ++index) await STEPS[index].run(ctx)
  for (let roll = 1; roll <= 3; roll += 1) {
    if (roll > 1) await prepareFollowingRoll(ctx)
    const blueBefore = (await snapshot(ctx)).balances.blue
    await STEPS[6].run(ctx)
    const state = await snapshot(ctx)
    if (mode === 'flash') assert(state.balances.blue === blueBefore, `Blue principal did not reconcile on roll ${roll}`)
    assert(state.oldDebt === 0n && (mode === 'general' ? state.newDebt > ctx.oldUnits : state.newDebt === FACE), `debt did not move on roll ${roll}`)
    assert(state.oldCollateral === 0n && state.newCollateral > 0n, `collateral did not move on roll ${roll}`)
    if (mode === 'flash') {
      assert(state.balances.lender === ctx.rollCarry * BigInt(roll), `carry did not accumulate on roll ${roll}`)
    }
  }
}

for (const mode of MODES) {
  const count = await verifyForward(mode)
  await verifyUndo(mode)
  await verifyRepeatedRolls(mode)
  console.log(`${mode} verified: ${count} lifecycle transactions, rewind and three consecutive rolls`)
}
console.log(`walkthrough verified: ${MODES.length} funding ${MODES.length === 1 ? 'method' : 'methods'} and ${STEPS.length} lifecycle steps each`)
