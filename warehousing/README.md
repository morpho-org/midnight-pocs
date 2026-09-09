# Midnight warehouse facility POC

A focused proof of concept for financing a pool of tokenized receivables with sponsor first-loss equity and a
senior loan originated through Morpho Midnight. The sponsor equity is not a tokenized or transferable tranche.

The demonstration is intentionally one warehouse account, one receivable token, one borrower-isolated Midnight
market, one junior provider, one senior facility cap, a 21-day availability period, and one use-of-proceeds
account. It shows the structure and its flow of funds; it is not an attempt to implement a generalized
private-credit platform.

> [!CAUTION]
> Experimental, unaudited research code. It is not production software and must not hold real funds.

## Facility model

```text
Junior provider ---------------------> WarehouseAccount
                                            |
Originator ---- tokenized receivable ------>|
                                            | pledge collateral
                                            v
Senior lender -------------------------> Midnight
                                            |
                                            | discounted senior proceeds
                                            v
Originator <----- fundOriginations() -- WarehouseAccount

Takeout / borrower ---> collections ---> WarehouseAccount
                                            |
                                            +--> recycle cash while active
                                            +--> cash sweep to senior in deficiency/run-off
                                            +--> junior residual only after senior is repaid
```

The receivable oracle reports gross value in Midnight's `1e36` scale. `AssetRegistry` applies a separate
advance rate to that value:

```text
collateral value = receivable units x oracle price
borrowing base   = collateral value x advance rate
deficiency       = Midnight debt face > borrowing base
```

The example uses a 75% warehouse advance rate and a 96.5% Midnight LLTV. The lower warehouse limit is a deal
covenant; Midnight's higher LLTV remains the protocol liquidation boundary. This separation lets a facility
freeze new money and cure a borrowing-base deficiency before its position becomes liquidatable.

## Contracts

| Contract | Purpose |
| --- | --- |
| `src/AssetRegistry.sol` | Stores receivable eligibility, oracle, and advance rate; calculates gross value and borrowing base. |
| `src/WarehouseAccount.sol` | Holds junior cash and receivables, owns the Midnight debt position, sweeps cash, and enforces facility states and payment priority. |
| `test/mocks/MockReceivable.sol` | Provides the tokenized receivable and mutable oracle used in the demonstration. |

`WarehouseAccount` uses live token and Midnight state rather than maintaining parallel accounting. Only pledged
receivables receive borrowing-base credit. Any accidentally transferred loose tokens are recoverable after senior
is discharged in run-off.

## Lifecycle

1. The administrator allows a receivable and assigns its oracle and advance rate; those terms are then locked.
2. Junior deposits the first-loss cash required to complete the receivable purchase.
3. The operator atomically transfers and pledges receivables to Midnight.
4. The warehouse takes a senior lender offer, subject to the borrowing-base cap.
5. `fundOriginations` sends the combined senior and junior cash to the fixed originator account.
6. While active, borrower or takeout cash, senior repayment, and removal of the corresponding receivables occur
   atomically through `settleReceivables`; this prevents cash and paid receivables from being counted together.
7. The resulting equity cash can fund replacement receivables during the availability period.
8. If the oracle mark or eligibility terms make debt exceed the borrowing base, anyone can flag a deficiency.
9. A deficiency blocks new draws and origination funding. Anyone can call `sweepCollectionsToSenior` to apply
   all trapped cash to senior; added collateral, that paydown, or a recovered valuation can cure the facility.
   A realized Midnight loss permanently freezes outward distributions; recovery is outside this focused POC.
10. The availability end, which cannot exceed market maturity, blocks new money and lets anyone enter run-off.
    Run-off permanently blocks new draws, receivable deposits, and origination funding. The same cash sweep
    repays senior first; junior can withdraw only after Midnight debt is zero and no loss was realized.

## Tests

The suite runs against deployed Midnight and Base USDC on a Base fork. The main lifecycle test executes a
complete $1 million warehouse:

- junior and senior funding;
- initial receivable purchase and origination funding;
- a seasoned partial collection followed by full-size replenishment and an incremental senior draw;
- expiry of the 21-day availability period and permissionless run-off;
- a below-par takeout in which the buyer receives the actual receivable pool; and
- full senior repayment before the sponsor absorbs the realized loss.

The integration tests separately verify:

- a draw above the borrowing base reverts atomically;
- an impairment freezes draws and origination funding while its cash sweep pays senior down;
- expiry automatically closes new money and opens run-off and the cash sweep to anyone;
- cash-backed liquidations are distinguished from bad-debt realization, which permanently freezes junior cash;
- configured oracle and advance-rate terms cannot be rewritten;
- a failed oracle cannot strand collateral after senior debt is fully satisfied;
- the senior facility cap, minimum draw proceeds, and single-borrower/single-lender market gate are enforced;
- pledged receivables cannot leave if that would undersecure senior;
- unpledged receivables neither support a draw nor become stranded in run-off;
- run-off is one-way and junior remains structurally subordinated;
- only the named operator and junior provider can move facility assets; and
- removing an asset from the registry halts new money without trapping senior repayment or collateral release.

Run the suite:

```bash
git clone --recurse-submodules https://github.com/morpho-org/midnight-pocs.git
cd midnight-pocs/warehousing
cp .env.example .env
forge test -vv
```

`BASE_RPC` must point to a Base archive-capable RPC. `FORK_BLOCK` is optional; pinning it makes repeat runs
deterministic.

## Deliberate limits

- One warehouse account supports one receivable token and one fixed-maturity Midnight market.
- The warehouse itself is the Midnight enter gate, so only this borrower and its fixed senior lender can use the
  market.
- The operator is trusted to match token movements to the legal receivable purchase and servicing records.
- The mock receivable is transferable and the oracle is administrator-set; neither verifies off-chain assets.
- The facility assumes the receivable and loan token use the same decimals.
- Cash application is explicit operator execution, not an automated payment waterfall or lockbox.
- A realized bad-debt loss makes the demo terminal; it does not attempt on-chain loss recovery.
- There are no rolls, lender aggregation, tranching tokens, servicing fees, concentration limits, grace periods,
  custom liquidation strategies, governance, deployment scripts, or UI.
- The tests demonstrate only the stated scenarios and are not a security review.
