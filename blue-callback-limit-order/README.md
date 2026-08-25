# Blue callback limit order

A deterministic TypeScript integration test for a callback-backed Midnight lend offer. The test runs entirely on an Anvil fork of Base and demonstrates USDC remaining supplied to Morpho Blue until a borrower fills the fixed-rate offer.

The implementation and exact assertions live in `src/callback-flow.test.ts`.
