import { useEffect, useRef, useState } from 'react'
import { nodeReachable, resetFork, revertChain, snapshotChain, type TxRecord } from './chain'
import { ProtocolFlow } from './ProtocolFlow'
import {
  STEPS,
  cloneCtx,
  emptyCtx,
  prepareFollowingRoll,
  snapshot,
  type Ctx,
  type FundingMode,
  type Snapshot,
} from './steps'

type Mode = 'checking' | 'ready' | 'offline'
type Phase = 'undrawn' | 'draw' | 'ready' | 'trace'
type TxGroup = { title: string; primary: TxRecord; transactions: TxRecord[] }

const usd = (value: bigint, digits = 0) =>
  `$${(Number(value) / 1e6).toLocaleString('en-US', { minimumFractionDigits: digits, maximumFractionDigits: digits })}`

const FUNDING_OPTIONS: { mode: FundingMode; label: string; detail: string }[] = [
  { mode: 'general', label: 'General refinance', detail: 'New lender funds the roll' },
  { mode: 'treasury', label: 'Cash treasury', detail: 'One full standby advance' },
  { mode: 'tranche', label: '10 tranches', detail: 'One tenth standby liquidity' },
  { mode: 'flash', label: 'Flash loan', detail: 'No idle principal' },
]

const traceLabels: Record<FundingMode, string[]> = {
  general: ['', 'New lender offer', 'Replacement loan', 'Move position', 'Old lender repaid', 'Refinance complete'],
  treasury: ['', 'Standby cash', 'New loan', 'Move position', 'Old credit', 'Recycle cash'],
  tranche: ['', 'Tranche buffer', 'Fund tranche', 'Move tranche', 'Old credit', 'Repeat ten times'],
  flash: ['', 'Flash liquidity', 'New loan', 'Move position', 'Old credit', 'Settlement'],
}

export default function App() {
  const ctx = useRef<Ctx>(emptyCtx('flash'))
  const zeroChain = useRef('')
  const zeroCtx = useRef<Ctx | null>(null)
  const preRollChain = useRef('')
  const preRollCtx = useRef<Ctx | null>(null)
  const rollCountBefore = useRef(0)
  const [mode, setMode] = useState<Mode>('checking')
  const [fundingMode, setFundingMode] = useState<FundingMode>('flash')
  const [phase, setPhase] = useState<Phase>('undrawn')
  const [traceStep, setTraceStep] = useState(0)
  const [rollCount, setRollCount] = useState(0)
  const [zero, setZero] = useState<Snapshot | null>(null)
  const [before, setBefore] = useState<Snapshot | null>(null)
  const [after, setAfter] = useState<Snapshot | null>(null)
  const [transactionHistory, setTransactionHistory] = useState<TxGroup[]>([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const prepare = async (selectedMode: FundingMode = fundingMode) => {
    setBusy(true)
    setError(null)
    try {
      if (!(await nodeReachable())) {
        setMode('offline')
        return
      }
      await resetFork()
      ctx.current = emptyCtx(selectedMode)
      for (let index = 0; index < 3; index += 1) await STEPS[index].run(ctx.current)
      const state = await snapshot(ctx.current)
      zeroChain.current = await snapshotChain()
      zeroCtx.current = cloneCtx(ctx.current)
      setZero(state)
      setBefore(null)
      setAfter(null)
      setTransactionHistory([])
      setRollCount(0)
      setTraceStep(0)
      setPhase('undrawn')
      setMode('ready')
    } catch (cause) {
      setMode('offline')
      setError(message(cause))
    } finally {
      setBusy(false)
    }
  }

  useEffect(() => {
    void prepare('flash')
  }, [])

  const selectFundingMode = async (selectedMode: FundingMode) => {
    if (busy || selectedMode === fundingMode) return
    setFundingMode(selectedMode)
    await prepare(selectedMode)
  }

  const initiateDraw = async () => {
    if (busy) return
    setBusy(true)
    setError(null)
    try {
      const drawTransactions = await STEPS[3].run(ctx.current)
      const reserveTransactions = await STEPS[4].run(ctx.current)
      const approvalTransactions = await STEPS[5].run(ctx.current)
      const transactions = [...drawTransactions, ...reserveTransactions, ...approvalTransactions]
      const primary = drawTransactions.find((transaction) => transaction.label === 'Open first maturity') ?? drawTransactions.at(-1)
      if (!primary) throw new Error('First draw transaction was not recorded')
      const state = await snapshot(ctx.current)
      preRollChain.current = await snapshotChain()
      preRollCtx.current = cloneCtx(ctx.current)
      rollCountBefore.current = 0
      setBefore(state)
      setAfter(null)
      setTransactionHistory([{ title: 'Initial draw', primary, transactions }])
      setPhase('draw')
    } catch (cause) {
      await restoreZero()
      setError(message(cause))
    } finally {
      setBusy(false)
    }
  }

  const executePreparedRoll = async (supportingTransactions: TxRecord[] = []) => {
    const rollTransactions = await STEPS[6].run(ctx.current)
    const transaction = rollTransactions[0]
    if (!transaction) throw new Error('Roll transaction was not recorded')
    setAfter(await snapshot(ctx.current))
    setTransactionHistory((history) => [...history, {
      title: `Roll ${rollCount + 1}`,
      primary: transaction,
      transactions: [...supportingTransactions, ...rollTransactions],
    }])
    setRollCount((count) => count + 1)
    setTraceStep(1)
    setPhase('trace')
  }

  const runRoll = async () => {
    if (busy || !before) return
    setBusy(true)
    setError(null)
    rollCountBefore.current = rollCount
    try {
      await executePreparedRoll()
    } catch (cause) {
      await restorePreRoll(false)
      setError(message(cause))
    } finally {
      setBusy(false)
    }
  }

  const rollAgain = async () => {
    if (busy || !after) return
    setBusy(true)
    setError(null)
    const priorChain = await snapshotChain()
    const priorCtx = cloneCtx(ctx.current)
    try {
      const supportingTransactions = await prepareFollowingRoll(ctx.current)
      const state = await snapshot(ctx.current)
      preRollChain.current = await snapshotChain()
      preRollCtx.current = cloneCtx(ctx.current)
      rollCountBefore.current = rollCount
      setBefore(state)
      await executePreparedRoll(supportingTransactions)
    } catch (cause) {
      await revertChain(priorChain)
      ctx.current = priorCtx
      setError(message(cause))
    } finally {
      setBusy(false)
    }
  }

  const restoreZero = async () => {
    if (!zeroCtx.current) return
    await revertChain(zeroChain.current)
    zeroChain.current = await snapshotChain()
    ctx.current = cloneCtx(zeroCtx.current)
    setBefore(null)
    setAfter(null)
    setTransactionHistory([])
    setRollCount(0)
    setTraceStep(0)
    setPhase('undrawn')
  }

  const restorePreRoll = async (removeTransaction = true) => {
    if (!preRollCtx.current) return
    await revertChain(preRollChain.current)
    preRollChain.current = await snapshotChain()
    ctx.current = cloneCtx(preRollCtx.current)
    setAfter(null)
    if (removeTransaction) setTransactionHistory((history) => history.slice(0, -1))
    setRollCount(rollCountBefore.current)
    setTraceStep(0)
    setPhase('ready')
  }

  const back = async () => {
    if (busy) return
    if (phase === 'draw' && rollCount === 0) {
      setBusy(true)
      try {
        await restoreZero()
      } finally {
        setBusy(false)
      }
      return
    }
    if (phase === 'ready') {
      if (after) {
        setTraceStep(5)
        setPhase('trace')
      } else {
        setPhase('draw')
      }
      return
    }
    if (phase !== 'trace') return
    if (traceStep > 1) {
      setTraceStep(traceStep - 1)
      return
    }
    setBusy(true)
    setError(null)
    try {
      await restorePreRoll(true)
    } catch (cause) {
      setError(message(cause))
    } finally {
      setBusy(false)
    }
  }

  if (mode === 'offline') {
    return (
      <main className="status-screen">
        <h1>Anvil is not running</h1>
        <code>cd ui &amp;&amp; ./anvil.sh</code>
        <button onClick={() => void prepare()}>Try again</button>
        {error && <p className="error-text">{error}</p>}
      </main>
    )
  }

  if (mode === 'checking' || !zero) {
    return <main className="status-screen"><p>Preparing local demo</p></main>
  }

  const loanNumber = phase === 'undrawn' ? 0 : rollCount + 1
  const title = phase === 'undrawn' ? 'No loan' : phase === 'draw' ? 'First draw' : phase === 'ready' ? `Loan ${loanNumber} outstanding` : traceLabels[fundingMode][traceStep]
  const stepLabel = phase === 'undrawn' ? 'Draw 0' : phase === 'draw' ? 'Draw 1' : phase === 'ready' ? `Loan ${loanNumber}` : `Roll ${rollCount}  Step ${traceStep} of 5`
  const status = flowStatus(fundingMode, phase, traceStep, ctx.current.advance, ctx.current.trancheAdvance, ctx.current.rollCarry)
  const currentTransactions = transactionHistory.at(-1)?.transactions ?? []

  return (
    <main className="app-shell">
      <header>
        <h1>Daily maturity roll</h1>
        <span className="network"><i /> Local Base fork</span>
      </header>

      <section className="funding-toolbar">
        <div className="funding-copy">
          <span>Roll liquidity</span>
          <h2>Choose how the lender bridges maturities</h2>
          <p>Each method resets the local fork and runs its own transactions.</p>
        </div>
        <div className="funding-control">
          <span>Funding method</span>
          <div className="funding-groups">
            <nav className="funding-group general-group" aria-label="Different-lender rolling">
              <small>Different lender</small>
              {FUNDING_OPTIONS.slice(0, 1).map((option) => (
                <button
                  key={option.mode}
                  className={fundingMode === option.mode ? 'active' : ''}
                  onClick={() => void selectFundingMode(option.mode)}
                  disabled={busy}
                  aria-pressed={fundingMode === option.mode}
                >
                  <strong>{option.label}</strong>
                  <span>{option.detail}</span>
                </button>
              ))}
            </nav>
            <nav className="funding-group same-lender-group" aria-label="Same-lender rolling liquidity method">
              <small>Same lender / two-party</small>
              <div className="funding-selector">
                {FUNDING_OPTIONS.slice(1).map((option) => (
                  <button
                    key={option.mode}
                    className={fundingMode === option.mode ? 'active' : ''}
                    onClick={() => void selectFundingMode(option.mode)}
                    disabled={busy}
                    aria-pressed={fundingMode === option.mode}
                  >
                    <strong>{option.label}</strong>
                    <span>{option.detail}</span>
                  </button>
                ))}
              </div>
            </nav>
          </div>
        </div>
      </section>

      <section className="roll-stage">
        <div className="roll-canvas">
          <div className="canvas-status">
            <span>Completed rolls <strong>{rollCount}</strong></span>
            <span>Carry per roll <strong>{ctx.current.rollCarry === 0n ? '$0.00' : usd(ctx.current.rollCarry, 2)}</strong></span>
            <span>Carry rolled <strong>{usd(ctx.current.rollCarry * BigInt(rollCount), 2)}</strong></span>
          </div>
          <Flow fundingMode={fundingMode} phase={phase} step={traceStep} zero={zero} before={before} after={after} advance={ctx.current.advance} trancheAdvance={ctx.current.trancheAdvance} carry={ctx.current.rollCarry} />
        </div>

        <aside className="step-panel">
          <div className="panel-step">
            <span className="panel-number">{phase === 'trace' ? traceStep : phase === 'undrawn' ? '–' : rollCount + 1}</span>
            <div><small>{stepLabel}</small><strong>{title}</strong></div>
            <span className="panel-of">{phase === 'trace' ? `${traceStep}/5` : fundingMode}</span>
          </div>

          <div className="panel-stats">
            <PanelStat label="Current action" value={status.title} />
            <PanelStat label="Amount" value={status.value} mono />
          </div>

          <div className="panel-controls">
            <button className="secondary" onClick={() => void back()} disabled={busy || phase === 'undrawn'}>− Back</button>
            {phase === 'undrawn' && <button className="primary" onClick={() => void initiateDraw()} disabled={busy}>{busy ? 'Opening…' : '+ First draw'}</button>}
            {phase === 'draw' && <button className="primary" onClick={() => setPhase('ready')}>+ Next</button>}
            {phase === 'ready' && !after && <button className="primary" onClick={() => void runRoll()} disabled={busy}>{busy ? 'Rolling…' : '+ Start roll'}</button>}
            {phase === 'ready' && after && <button className="primary" onClick={() => void rollAgain()} disabled={busy}>{busy ? 'Rolling…' : '+ Next roll'}</button>}
            {phase === 'trace' && traceStep < 5 && <button className="primary" onClick={() => setTraceStep(traceStep + 1)}>+ Next step</button>}
            {phase === 'trace' && traceStep === 5 && <button className="primary" onClick={() => setPhase('ready')}>+ Continue</button>}
          </div>
          {error && <div className="error-box">{error}</div>}

          <div className="panel-scroll">
            <section className="panel-section">
              <h3>Explanation</h3>
              <p>{explanationFor(fundingMode, phase, traceStep)}</p>
            </section>
            <PanelTransactions transactions={currentTransactions} />
            {transactionHistory.length > 0 && <TransactionHistory groups={transactionHistory} />}
          </div>
          <button className="panel-reset" onClick={() => void prepare()} disabled={busy}>Reset walkthrough</button>
        </aside>
      </section>

      <footer>Local demo. Unaudited.</footer>
    </main>
  )
}

function PanelStat({ label, value, mono = false }: { label: string; value: string; mono?: boolean }) {
  return <div><span>{label}</span><strong className={mono ? 'mono' : ''}>{value}</strong></div>
}

function PanelTransactions({ transactions }: { transactions: TxRecord[] }) {
  return (
    <section className="panel-section panel-transactions">
      <h3>Transactions <span>{transactions.length}</span></h3>
      {transactions.length === 0 && <p>No transaction in this step.</p>}
      {transactions.map((transaction) => (
        <details key={transaction.hash}>
          <summary><span>›</span><strong>{transaction.label}</strong><code>{transaction.gasUsed.toLocaleString()} gas</code></summary>
          <div><code>{transaction.hash}</code></div>
        </details>
      ))}
    </section>
  )
}

function TransactionHistory({ groups }: { groups: TxGroup[] }) {
  return (
    <details className="panel-history">
      <summary>History <span>{groups.reduce((count, group) => count + group.transactions.length, 0)} confirmed</span></summary>
      <div>
      {groups.map((group, index) => (
        <div className="history-row" key={`${group.title}-${group.primary.hash}`}>
          <span>{String(index + 1).padStart(2, '0')}</span><strong>{group.title}</strong><code>{compactHash(group.primary.hash)}</code><small>{group.transactions.length} tx</small>
        </div>
      ))}
      </div>
    </details>
  )
}

function Flow({ fundingMode, phase, step, zero, before, after, advance, trancheAdvance, carry }: {
  fundingMode: FundingMode
  phase: Phase
  step: number
  zero: Snapshot
  before: Snapshot | null
  after: Snapshot | null
  advance: bigint
  trancheAdvance: bigint
  carry: bigint
}) {
  const arrow = arrowFor(fundingMode, phase, step, advance, trancheAdvance)
  const drawPath = phase === 'draw'
  const settledReady = phase === 'ready' && after
  const current = phase === 'undrawn' ? zero : settledReady ? after : before ?? zero
  const moved = phase === 'trace' && step >= 3 && after
  const oldDebt = moved ? after.oldDebt : settledReady ? after.newDebt : current.oldDebt
  const oldCollateral = moved ? after.oldCollateral : settledReady ? after.newCollateral : current.oldCollateral
  const newDebt = settledReady ? 0n : phase === 'trace' && step >= 2 ? after?.newDebt ?? 0n : current.newDebt
  const newCollateral = settledReady ? 0n : moved ? after.newCollateral : current.newCollateral
  const liquidityName = fundingMode === 'flash' ? 'Morpho Blue' : fundingMode === 'treasury' ? 'Treasury buffer' : 'Tranche buffer'
  const displayedLiquidityName = fundingMode === 'general' ? 'Lender B' : liquidityName
  const liquidityDetail = fundingMode === 'general'
    ? 'Replacement offer'
    : fundingMode === 'flash'
    ? phase === 'trace' && step === 1 ? '$1,000,000 out' : phase === 'trace' && step === 5 ? '$0 exposure' : 'Flash liquidity'
    : fundingMode === 'treasury' ? `${usd(advance, 2)} standby` : `${usd(trancheAdvance, 2)} recycled`

  return (
    <div className="flow">
      <ProtocolFlow
        arrow={arrow}
        drawPath={drawPath}
        advance={usd(advance, 2)}
        general={fundingMode === 'general'}
        liquidityName={displayedLiquidityName}
        lenderName={fundingMode === 'general' ? 'Lender A' : fundingMode === 'flash' ? 'Lender contract' : 'Lender'}
        details={{
          blue: liquidityDetail,
          lender: phase === 'trace' && step === 5
            ? fundingMode === 'flash' ? `${usd(carry, 2)} carry received` : 'Old credit available again'
            : 'Loan funding',
          borrower: phase === 'undrawn' ? 'No debt' : fundingMode === 'general' ? 'Carry capitalized' : `${usd(carry, 2)} interest reserve`,
        }}
      />

      <div className="positions">
        <Position label="Current maturity" debt={oldDebt} collateral={oldCollateral} active={phase !== 'trace' || step === 3 || step === 4} />
        <div className={`position-arrow ${phase === 'trace' && step === 3 ? 'active' : ''}`}>→</div>
        <Position label="Next maturity" debt={newDebt} collateral={newCollateral} active={phase === 'trace' && step >= 2} />
      </div>
    </div>
  )
}

function Position({ label, debt, collateral, active }: { label: string; debt: bigint; collateral: bigint; active: boolean }) {
  return <div className={`position ${active ? 'active' : ''}`}><strong>{label}</strong><dl><div><dt>Debt</dt><dd>{usd(debt)}</dd></div><div><dt>Collateral</dt><dd>{usd(collateral)}</dd></div></dl></div>
}

function arrowFor(fundingMode: FundingMode, phase: Phase, step: number, advance: bigint, trancheAdvance: bigint) {
  if (phase !== 'trace') return { from: -1, to: -1, gap: -1, reverse: false, label: '' }
  if (fundingMode === 'general') {
    if (step === 1) return { from: 0, to: 2, gap: 0, reverse: false, label: 'Valid offer' }
    if (step === 2) return { from: 0, to: 2, gap: 0, reverse: false, label: '$1,000,000' }
    if (step === 3) return { from: 3, to: 2, gap: 2, reverse: true, label: 'Repay and move' }
    if (step === 4) return { from: 2, to: 1, gap: 1, reverse: true, label: 'Old debt repaid' }
    return { from: -1, to: -1, gap: -1, reverse: false, label: '' }
  }
  const funding = fundingMode === 'tranche' ? trancheAdvance : fundingMode === 'treasury' ? advance : FACE_USD
  if (step === 1) return { from: 0, to: 1, gap: 0, reverse: false, label: usd(funding, 2) }
  if (step === 2) return { from: 1, to: 2, gap: 1, reverse: false, label: fundingMode === 'tranche' ? `${usd(trancheAdvance, 2)} × 10` : usd(advance, 2) }
  if (step === 3) return { from: 3, to: 2, gap: 2, reverse: true, label: 'Repay and move' }
  if (step === 4) return { from: 2, to: 1, gap: 1, reverse: true, label: fundingMode === 'tranche' ? '$100,000 × 10' : '$1,000,000' }
  return { from: 1, to: 0, gap: 0, reverse: true, label: fundingMode === 'flash' ? '$1,000,000' : 'Ready for next roll' }
}

const FACE_USD = 1_000_000_000_000n

function flowStatus(fundingMode: FundingMode, phase: Phase, step: number, advance: bigint, trancheAdvance: bigint, carry: bigint) {
  if (phase === 'undrawn') return { title: 'No debt', value: '$0 borrowed' }
  if (phase === 'draw') return { title: 'Lender funds the first loan', value: `${usd(advance, 2)} proceeds  |  $1,000,000 debt` }
  if (phase === 'ready') return { title: 'Loan is outstanding', value: '$1,000,000 debt  |  roll liquidity unused' }
  const titles = fundingMode === 'general'
    ? ['', 'Borrower accepts Lender B’s offer', 'Lender B funds the replacement loan', 'Borrower repays and moves collateral', 'Lender A is repaid', 'Borrower now owes Lender B']
    : fundingMode === 'flash'
    ? ['', 'Blue sends temporary liquidity', 'Lender funds the next loan', 'Borrower repays and moves collateral', 'Midnight releases the old lender credit', 'Lender repays Blue']
    : fundingMode === 'treasury'
      ? ['', 'Lender uses its standby cash', 'Lender funds the next maturity', 'Borrower repays and moves collateral', 'Midnight releases the old lender credit', 'Standby cash is restored']
      : ['', 'Lender starts with one tranche', 'Lender funds the next tranche', 'Borrower moves one tenth of the position', 'Lender withdraws released old credit', 'The same liquidity repeats ten times']
  const values = fundingMode === 'general'
    ? ['', 'Valid later-maturity offer', 'No standby lender capital', '$1,000,000 old debt closed', '$1,000,000 old lender credit released', `${usd(carry, 2)} carry capitalized into new debt`]
    : fundingMode === 'flash'
    ? ['', '$1,000,000 temporary USDC', `${usd(advance, 2)} new advance`, '$1,000,000 debt  |  $1,100,000 collateral', '$1,000,000 lender credit', `$0 Blue exposure  |  ${usd(carry, 2)} carry this roll`]
    : fundingMode === 'treasury'
      ? ['', `${usd(advance, 2)} standby USDC`, `${usd(advance, 2)} new advance`, '$1,000,000 debt  |  $1,100,000 collateral', '$1,000,000 lender credit', `$1,000,000 released  |  ${usd(carry, 2)} carry`]
      : ['', `${usd(trancheAdvance, 2)} standby USDC`, `${usd(trancheAdvance, 2)} per tranche`, '$100,000 debt  |  $110,000 collateral per tranche', '$100,000 old credit per tranche', `10 tranches complete  |  ${usd(carry, 2)} carry`]
  return { title: titles[step], value: values[step] }
}

function explanationFor(fundingMode: FundingMode, phase: Phase, step: number) {
  if (phase === 'undrawn') return 'No loan is open yet. The first draw pledges the collateral and opens the current Midnight maturity.'
  if (phase === 'draw') return 'The lender funds the first fixed-maturity loan. Midnight records $1 million of debt and lender credit while the borrower receives the discounted proceeds.'
  if (phase === 'ready') return 'The current loan is outstanding. Starting the roll executes the selected liquidity method and moves the same position into the next daily maturity.'

  const explanations: Record<FundingMode, string[]> = {
    general: [
      '',
      'The borrower selects a valid offer from Lender B on the later-maturity market. Lender A does not need to provide the replacement capital.',
      'Lender B funds the replacement loan through Midnight. Because this is new capital from a different lender, no treasury buffer, tranches, or flash loan is required.',
      'Inside the singleton callback, the new proceeds repay the old debt and the collateral moves into the later maturity. The financing discount is capitalized into the new debt.',
      'Repaying the old position releases Lender A’s credit. Lender A withdraws its principal and exits while Lender B holds the new credit.',
      'The borrower now owes Lender B at the later maturity. A future roll can repeat the same process with another valid lender offer.',
    ],
    flash: [
      '',
      'Morpho Blue lends $1 million to the lender adapter for this transaction only. The adapter does not keep another principal amount idle.',
      'The adapter uses the temporary cash to fund the next Midnight maturity. The borrower receives the discounted new-loan proceeds.',
      'Inside Midnight’s callback, the borrower adds its interest reserve, repays the old debt, withdraws the collateral, and pledges it to the new maturity.',
      'Repaying the old debt makes the lender adapter’s old-market credit withdrawable. The adapter withdraws that $1 million before the transaction ends.',
      'The adapter returns the $1 million flash principal to Morpho Blue. Only the earned carry remains; Blue finishes with zero exposure.',
    ],
    treasury: [
      '',
      'The lender starts the roll with almost one full additional advance sitting in its treasury. No external liquidity provider is used.',
      'The lender spends that standby cash to fund the next Midnight maturity while its original principal is still locked in the old maturity.',
      'The borrower combines the new proceeds with its interest reserve, repays the old debt, and moves the collateral into the new maturity.',
      'The old repayment releases $1 million of lender credit. The lender withdraws it from Midnight after the position has moved.',
      'The withdrawn old credit becomes the treasury’s standby cash for the following roll. The mechanism is simple but capital intensive.',
    ],
    tranche: [
      '',
      'The lender begins with only one tenth of the next advance available instead of keeping another full loan amount idle.',
      'That buffer funds the first $100,000 slice of the next maturity. The remaining old position stays in place for the moment.',
      'The borrower repays $100,000 of old debt and moves $110,000 of collateral into the new maturity for this slice.',
      'Midnight releases the matching $100,000 of old lender credit. The lender withdraws it and can immediately fund the next slice.',
      'The same cash is recycled through ten roll-and-withdraw pairs until the full debt and collateral have moved to the next maturity.',
    ],
  }
  return explanations[fundingMode][step]
}

const message = (cause: unknown) => cause instanceof Error ? cause.message.split('\n')[0] : String(cause)
const compactHash = (hash: string) => `${hash.slice(0, 10)}...${hash.slice(-8)}`
