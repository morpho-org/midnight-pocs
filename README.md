# Midnight POCs

Focused, non-production proofs of concept for integrations built on Morpho Midnight.

Each POC lives in its own directory with an independent README, dependencies, tests and local-run instructions.
The examples are intentionally narrow: they demonstrate specific protocol mechanics without defining a complete
production product.

| POC | Status | Purpose |
| --- | --- | --- |
| [`rolling/`](rolling/) | Implemented | Move a fixed-maturity position into a later Midnight market using four alternative refinancing and liquidity mechanisms. |
| [`warehousing/`](warehousing/) | Documentation only | Outline a future fixed-maturity warehousing facility with senior and junior capital. No code has been added yet. |

## Getting started

Clone with submodules so each implemented POC receives its pinned Solidity dependencies:

```bash
git clone --recurse-submodules https://github.com/morpho-org/midnight-pocs.git
```

Then follow the README inside the POC you want to run.

## Status and safety

Everything in this repository is experimental and unaudited. It has not undergone an independent security
review and must not be deployed in production or used to manage real funds. Passing tests demonstrate only the
scenarios described by each POC; they do not guarantee correctness or security under other configurations.
