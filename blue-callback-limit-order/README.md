# Blue callback limit order

A small TypeScript implementation of a callback-backed Midnight lend offer. It shows a lender keeping USDC supplied to Morpho Blue until a borrower fills a signed fixed-rate offer.

The example separates reusable maker and taker functions from a deterministic Anvil test. The test uses deployed Morpho Blue, Midnight, `BlueBuyCallbackFactory`, and ratifier contracts on a Base fork, but it neither publishes an offer nor sends a transaction to Base.

## Implementation

- [`createMaker()`](src/maker.ts) binds the clients, account, contracts and markets once, then exposes the maker steps below.
- `createCallback()` deploys the maker's callback through the factory when it does not already exist.
- `approveBlue()` approves Blue to transfer the requested USDC when the existing allowance is insufficient.
- `supplyBlue()` supplies USDC to Blue with the callback as the position owner.
- `authorizeRatifier()` authorizes the Midnight ratifier when needed.
- `signOffer()` constructs and signs an offer with `@morpho-org/midnight-sdk` without changing onchain state.
- [`simulateTake()`](src/taker.ts) reads the current settlement fee, quotes the requested partial fill and simulates `take()` without changing state.
- [`takeOffer()`](src/taker.ts) calls `simulateTake()` and submits its exact request.
- [`src/callback-flow.test.ts`](src/callback-flow.test.ts) contains only fork setup, test funding, borrower collateral and assertions around those reusable functions.

Neither reusable function contains Anvil impersonation or test balance manipulation.

## What it proves

The test performs the following flow:

1. Creates a `BlueBuyCallback` for a local lender.
2. Supplies 100 USDC to the callback's cbBTC/USDC Morpho Blue position.
3. Constructs a roughly 6% APR December 2026 Midnight lend offer with `@morpho-org/midnight-sdk`.
4. Signs the offer locally using the deployed `EcrecoverRatifier` scheme.
5. Supplies cbBTC collateral for a local borrower.
6. Simulates and executes a 25 USDC partial fill.
7. Verifies that the callback withdrew 25 USDC from Blue, the lender received Midnight credit, the borrower received USDC and the borrower incurred matching Midnight debt.
8. Executes a second 10 USDC partial fill with the same signed offer.
9. Removes most of the remaining Blue liquidity and verifies that a stale oversized fill reverts.

Expected summary:

```text
Blue callback limit order
  fixed APR:            ~6.00%
  Blue before:          100 USDC
  first fill:           25 USDC
  borrower received:    25 USDC
  Blue after first:     75 USDC
  Blue after second:    65 USDC
  stale-liquidity take: reverted as expected
PASS
```

## Run it

Requirements:

- Node.js 22+
- pnpm 10+
- Foundry/Anvil
- A Base RPC endpoint that supports recent state

Install dependencies:

```bash
pnpm install
```

Start the fork in one terminal:

```bash
cp .env.example .env
# Set BASE_RPC in .env if the public endpoint is unsuitable.
pnpm anvil
```

Run the test in another terminal:

```bash
pnpm test
```

Restart Anvil before rerunning the test so every run begins from a clean fork. Use `FORK_BLOCK` in `.env` to pin a known block when exact historical reproducibility matters.

Run the static check independently with:

```bash
pnpm typecheck
```

## API boundary

This example deliberately does not use the live Midnight API. A signed Midnight offer is an offchain object and can be passed directly to `Midnight.take`; API publication and discovery are not prerequisites for settlement. Keeping the core test local avoids dependence on a changing public order book and avoids publishing test offers.

An API smoke test can be added separately for market discovery, mempool payload validation and quote retrieval without weakening this deterministic callback settlement test.

## Pinned markets

The example pins the currently deployed Base cbBTC/USDC market parameters for both Morpho Blue and the December 25, 2026 Midnight market. The script verifies the Midnight market ID before executing the flow. If the callback factory is unavailable at the selected fork block or the pinned market has already matured, the test fails with a direct setup error.

## Safety

This is an experimental, unaudited demonstration. It is not production software and must not be used with real funds. See the repository-level safety notice for the full limitations.
