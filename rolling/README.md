# Midnight Rolling POC

## Quick start

Prerequisites: Foundry, Node.js and pnpm.

Clone the repository, initialize its pinned dependencies and run the Solidity tests:

```bash
git clone --recurse-submodules https://github.com/morpho-org/midnight-pocs.git
cd midnight-pocs/rolling
cp .env.example .env
forge test
```

To run the interactive walkthrough, start the local Base fork from the `rolling` directory:

```bash
cd ui
pnpm install --frozen-lockfile
./anvil.sh
```

Then open a second terminal:

```bash
cd midnight-pocs/rolling/ui
pnpm dev
```

Open `http://127.0.0.1:5111` and select one of the four rolling examples. Run `pnpm verify` from `rolling/ui`
to execute all four walkthrough lifecycles without the browser.

A proof of concept for moving a Morpho Midnight loan from one fixed maturity to a later maturity. It separates
two different rolling problems:

1. **General borrower rolling:** the borrower refinances into any valid offer on the new market. The old and new
   lenders may be different.
2. **Two-party / KYC capital rolling:** the same approved lender and borrower remain in the facility, so the
   lender must bridge the period before its old capital becomes withdrawable.

Each individual roll call performs its debt repayment and collateral migration through Midnight callbacks. A
call reverts if its replacement debt, old repayment or collateral movement cannot all complete. The tranche
option is intentionally a sequence of atomic partial rolls rather than one atomic full-facility migration.

## Four rolling examples

| Example | Lender relationship | Source of roll liquidity | Execution | Primary trade-off |
| --- | --- | --- | --- | --- |
| General refinance | Lender A may be replaced by Lender B | A valid offer from the new lender | One singleton roll; Lender A's repaid credit becomes withdrawable | The borrower must find a suitable later-maturity offer before the old loan matures |
| Cash treasury | The same lender funds both loans | Almost one additional advance held by that lender | One full roll, followed by withdrawal of the repaid old credit | Simplest same-lender flow, but requires substantial standby capital |
| Tranches | The same lender funds both loans | A smaller reusable liquidity buffer | Repeated partial rolls and old-credit withdrawals | Less standby capital, but more operations and partial-roll exposure |
| Flash loan | The same lender funds both loans | Temporary external liquidity borrowed atomically | One full roll within nested Midnight and Morpho Blue callbacks | No additional idle principal, but adds adapter and flash-liquidity dependencies |

The general refinance is a borrower-side mechanism: a new lender's offer supplies the proceeds that repay the
old lender. The other three examples solve the separate lender-side liquidity problem that arises when the same
lender wants to remain invested across consecutive maturities.

## General borrower rolling

`MidnightRoller` is a permissionless singleton deployed once per chain and shared by every user. It does not
assume that the lender on the old loan is also the lender on the replacement loan.

```text
Lender B funds the new maturity
                |
                v
        MidnightRoller
                |
                +-- repays the debt funded by Lender A
                +-- withdraws collateral from the old market
                +-- supplies collateral to the new market
                |
                v
Borrower now owes Lender B at the later maturity
```

The borrower calls `roll(params)` with a valid lender offer for the new market. The singleton calls
`Midnight.take()` with the borrower as the taker and itself as the proceeds receiver and callback. Inside
`onSell()`, it repays the old debt and moves the collateral on behalf of the borrower. The old lender is not an
input to the roll; Midnight makes that lender's old-market credit withdrawable when the debt is repaid.

The replacement offer is discounted, so a new loan with the same face value would not produce enough cash to
repay the old face. The singleton capitalizes that gap. It calculates the smallest `newUnits` whose proceeds
cover `oldUnits`, then enforces two borrower-supplied limits:

- `maxNewUnits` caps the replacement debt.
- `maxLtv` caps post-roll debt relative to the selected collateral and oracle. Passing `0` disables this
  additional check; Midnight still performs its own health check.

### Singleton setup

Each borrower authorizes the singleton once through Midnight:

```solidity
MIDNIGHT.setIsAuthorized(address(roller), true, borrower);
```

Anyone can prime the singleton's Midnight allowance once per loan or collateral token:

```solidity
roller.setApprovalMax(token);
```

The borrower can then roll into a valid later-maturity offer:

```solidity
roller.roll(MidnightRoller.RollParams({
    oldMarket: oldMarket,
    oldCollateralIndex: 0,
    newCollateralIndex: 0,
    collateralAmount: collateralAmount,
    oldUnits: oldDebt,
    maxNewUnits: maximumReplacementDebt,
    maxLtv: maximumPostRollLtv,
    newOffer: newLenderOffer,
    ratifierData: ratifierData
}));
```

### Singleton assumptions

The singleton verifies the fields required to execute the migration, but it does not decide whether a replacement
market or offer is commercially appropriate. Before signing or submitting a roll, the borrower or its interface
must validate the complete target configuration, including the lender offer, oracle, LLTV, liquidation settings,
gates, maturity and fees.

- The borrower must have no existing debt in the target market. Existing target collateral is permitted; the
  optional `maxLtv` check remains conservative because it uses only the collateral moved by this roll.
- The borrower can revoke the singleton at any time with
  `MIDNIGHT.setIsAuthorized(address(roller), false, borrower)`. Revocation prevents later rolls but does not undo
  a completed transaction.
- Loan and collateral assets are assumed to be standard, non-rebasing, non-fee-on-transfer ERC-20 tokens whose
  `approve` function returns a boolean.
- The singleton is not a custody contract. Successful rolls leave it with no loan tokens or collateral, and it
  intentionally has no general-purpose token recovery function.

## Two-party / KYC capital rolling

When the same lender funds both maturities, transaction ordering creates a lender-side liquidity requirement:

```text
fund the new maturity -> repay the old debt -> withdraw the old lender credit
```

The lender cannot reuse the old principal until after it has funded the replacement loan. This POC preserves
the simple treasury baseline and demonstrates two ways to reduce that additional capital requirement.

| Funding method | Additional lender liquidity | Roll execution | Main trade-off |
| --- | ---: | --- | --- |
| Cash treasury | Almost one full additional advance | One roll call | Approximately half of total lender capital sits idle between rolls |
| Tranches | One tranche; the test uses one tenth of the advance | Ten roll calls in the test | More execution and partial-roll operational exposure |
| Flash loan | No additional idle principal | One atomic roll | Additional adapter, callback and flash-liquidity dependency |

### Cash treasury baseline

The lender keeps almost one additional advance available. It funds the next-maturity offer, the borrower uses
those proceeds plus its interest reserve to repay the old face, and the lender withdraws the released old credit.
That withdrawn capital becomes the standby liquidity for the following roll.

`DirectRoll.t.sol` demonstrates this full-face same-lender roll and confirms the idle-advance requirement.

### Tranche-funded option

The same sequence can be divided into smaller pieces. With a $100,000 liquidity buffer for a $1 million loan:

1. The lender funds $100,000 of the new maturity.
2. The borrower repays $100,000 of old debt and moves the proportional collateral.
3. The lender withdraws the released $100,000 of old credit.
4. The lender reuses it for the next tranche.

`TrancheRoll.t.sol` repeats this cycle ten times, verifies debt, credit, collateral and cash after every tranche,
then repays the final maturity and returns the collateral. The calls could be orchestrated differently, including
through a more complex bundled contract, but tranching does not remove the additional execution and gas.

### Flash-funded option

`FlashRollLender` uses Morpho Blue to bridge the full principal inside one transaction:

1. The capital owner ratifies the replacement Midnight offer.
2. The borrower operator approves the exact roll terms for one use.
3. The lender operator requests a full-face Morpho Blue flash loan.
4. Midnight funds the replacement advance through the lender adapter.
5. The borrower adds its interest reserve, repays the old debt and moves the collateral.
6. The adapter withdraws the released old lender credit.
7. Morpho Blue pulls back the flash principal.

The lender supplies the initial advance that remains invested in Midnight, but does not keep another principal
amount idle for each roll. Morpho Blue must have sufficient liquidity when the roll executes.

## Interest treatment

The lender-liquidity mechanism and the treatment of interest are separate design choices:

- The general singleton capitalizes the interest gap by increasing the replacement debt.
- The two-party direct, tranche and flash tests keep debt fixed at $1 million and use a borrower-funded interest
  reserve to cover the difference between face value and discounted proceeds.

A same-lender facility could also capitalize interest, but doing so would not eliminate the lender's temporary
principal requirement. Treasury, tranches or a liquidity bridge would still be needed to recycle the same
capital.

## Contracts

- `MidnightRoller.sol`: shared borrower-side singleton for rolling into any valid later-maturity lender offer.
- `RollingBorrower.sol`: controlled borrower adapter for the two-party implementations. It pins every market
  field except maturity and requires exact one-use authorization for delegated rolls.
- `FlashRollLender.sol`: same-lender Morpho Blue flash-loan adapter.
- `TwoPartyGate.sol`: restricts credit, debt and liquidation to the configured institutional participants.

The tranche option uses `RollingBorrower` repeatedly and does not require another production contract in this
POC.

## Tests

The tests fork Base and use the deployed Midnight, Setter Ratifier, Morpho Blue and Base USDC contracts. The
collateral and oracle are intentionally simple local mocks.

```bash
git submodule update --init --recursive
cp .env.example .env
forge test
forge build --sizes
```

The deterministic test block is `49,358,285`. Remove `FORK_BLOCK` to run against the current Base tip.

Coverage includes:

- a complete general roll from Lender A to Lender B, followed by both lender exits and collateral return;
- repeated general rolls from Lender A to Lender B to Lender C with capitalized carry;
- singleton authorization, callback binding, target-position and nonzero-input protections;
- nonzero Midnight settlement-fee accounting in replacement debt;
- singleton debt and LTV limits, collateral compatibility, index bounds and maturity ordering;
- a direct full-face same-lender roll and its idle treasury requirement;
- a ten-tranche same-lender lifecycle using one tenth of an advance as the liquidity buffer;
- a 30-day flash lifecycle with 29 full-face rolls and no idle adapter principal;
- exact Morpho Blue balance reconciliation;
- borrower-approved terms, one-use authorization and replay protection;
- empty interest reserve and insufficient flash liquidity atomic failure;
- pinned two-party market configuration and separated custody permissions; and
- final repayment, lender principal recovery and collateral release.

## Local walkthrough

The `ui/` directory contains an unhosted transaction walkthrough for the general different-lender refinance and
all three two-party funding options. A selector separates general refinancing from cash treasury, ten tranches
and a Morpho Blue flash loan. Each selection resets the local fork, starts with pledged collateral and no debt,
submits the first draw, and then allows consecutive daily rolls. Every displayed figure and transaction is read
from the local chain.

Start the fork:

```bash
cp .env.example .env
cd ui
pnpm install --frozen-lockfile
./anvil.sh
```

In a second terminal:

```bash
cd ui
pnpm dev
```

Open `http://127.0.0.1:5111`. To verify every funding method's lifecycle, rewind path and three consecutive rolls
without the browser:

```bash
cd ui
pnpm verify
```

## Scope

This repository demonstrates alternative on-chain rolling primitives; it is not a production lending product.
The code and walkthrough are experimental and unaudited, have not undergone an independent security review, and
must not be deployed in production or used to manage real funds. Passing tests demonstrate only the scenarios
described above and do not guarantee correctness or security under other configurations or market conditions.

The fork asserts that Midnight settlement and continuous fees are zero for the fixed-face two-party markets. If
those fees change, reserve sizing and lender returns must account for them. The singleton includes settlement
fees in its replacement-debt calculation and relies on the offer's continuous-fee cap for that market.
