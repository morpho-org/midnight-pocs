# Midnight warehouse facility POC

A focused proof of concept for financing a pool of tokenized receivables with junior first-loss cash and a
senior loan originated through Morpho Midnight.

The demonstration is intentionally one warehouse account, one receivable token, one borrower-isolated Midnight market, one
junior provider, one senior commitment, a 21-day availability period, and one use-of-proceeds account. It shows the structure and its flow of funds; it is not an
attempt to implement a generalized private-credit platform.

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

`WarehouseAccount` derives cash, collateral, and debt from live token and Midnight state. Only receivables pledged
to Midnight receive borrowing-base credit; deposited but unpledged tokens remain visible for reporting and can be
recovered after senior is repaid in run-off. The only cumulative
book entries are the junior contribution and withdrawal totals used for reporting.

## Lifecycle

1. The administrator allows a receivable and assigns its oracle and advance rate. The warehouse pins those terms
   when its Midnight market is configured; subsequent registry changes cannot loosen the active facility.
2. Junior deposits the first-loss cash required to complete the receivable purchase.
3. The operator transfers receivables into the warehouse and pledges them to Midnight.
4. The warehouse takes a senior lender offer, subject to the borrowing-base cap.
5. `fundOriginations` sends the combined senior and junior cash to the fixed originator account.
6. While active, borrower or takeout cash, senior repayment, and removal of the corresponding receivables occur
   atomically through `settleReceivables`; this prevents cash and paid receivables from being counted together.
7. The resulting equity cash can fund replacement receivables during the availability period.
8. If the oracle mark or eligibility terms make debt exceed the borrowing base, anyone can flag a deficiency.
9. A deficiency blocks new draws and origination funding. Anyone can call `sweepCollectionsToSenior` to apply
   all trapped cash to senior; added collateral, that paydown, or a recovered valuation can cure the facility.
   If Midnight realizes bad debt, the facility preserves the unpaid senior claim and blocks junior or originator
   distributions until cash pays that loss or the fixed senior beneficiary explicitly resolves it.
10. The availability end or market maturity blocks new money and lets anyone enter run-off. Run-off permanently
    blocks new draws, receivable deposits, and origination funding. The same cash sweep
    repays senior first; junior can withdraw only after both Midnight debt and the preserved senior claim reach zero.

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
- liquidation or bad-debt realization cannot erase the senior claim or unlock junior cash;
- registry changes cannot rewrite the active facility's pinned oracle and advance rate;
- the senior commitment, minimum draw proceeds, and single-borrower market gate are enforced;
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
- The warehouse itself is the Midnight enter gate, so unrelated borrowers cannot socialize losses into its senior line.
- The operator is trusted to match token movements to the legal receivable purchase and servicing records.
- The mock receivable is transferable and the oracle is administrator-set; neither verifies off-chain assets.
- The facility assumes the receivable and loan token use the same decimals.
- Cash application is explicit operator execution, not an automated payment waterfall or lockbox.
- There are no rolls, lender aggregation, tranching tokens, servicing fees, concentration limits, grace periods,
  liquidations, governance, deployment scripts, or UI.
- The tests demonstrate only the stated scenarios and are not a security review.
