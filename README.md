# Midnight POCs

> [!CAUTION]
> **EXPERIMENTAL, UNAUDITED, NOT FOR PRODUCTION USE.**
>
> This repository contains research prototypes only. Nothing here has been audited or security
> reviewed, nothing here is a Morpho product, and nothing here should ever be deployed to a
> production network or used to custody, route or manage real funds. Assume every contract,
> script and document in this repository contains bugs, including bugs that lead to total loss
> of funds. Use at your own risk. See [Status and safety](#status-and-safety) before reading
> any further.

Proof of concepts for integrations built on Morpho Midnight. Each POC lives in its own directory
with an independent README, dependencies, tests and local-run instructions.

The examples are intentionally narrow: they demonstrate specific protocol mechanics without defining
a complete production product. They are written to explore and communicate ideas, not to be reused
as libraries or starting points for live deployments.

| POC | Status | Purpose |
| --- | --- | --- |
| [`rolling/`](rolling/) | Implemented (unaudited prototype) | Move a fixed-maturity position into a later Midnight market using four alternative refinancing and liquidity mechanisms. |
| [`warehousing/`](warehousing/) | Implemented (unaudited prototype) | Demonstrate a simple receivable warehouse with junior first-loss capital, a Midnight senior draw, cash sweeps, deficiency controls and senior-first run-off. |

## Getting started

Clone with submodules so each implemented POC receives its pinned Solidity dependencies:

```bash
git clone --recurse-submodules https://github.com/morpho-org/midnight-pocs.git
```

Then follow the README inside the POC you want to run. POCs are intended to be run locally or on
test networks only.

## Status and safety

Read this section in full before using anything in this repository.

**Unaudited and unreviewed.** No code in this repository has undergone an independent security
audit, formal verification, or internal Morpho security review. It has not been reviewed to the
standard applied to production Morpho contracts.

**Not production software.** Nothing here is intended for deployment to any production or mainnet
environment, and nothing here may be used to hold, route, price or manage real user funds. Do not
copy these contracts, scripts or configurations into a production system, in whole or in part,
without a complete independent redesign, review and audit for which you alone are responsible.

**Expect bugs and known limitations.** Code paths may be incomplete, edge cases may be unhandled,
access control may be missing or intentionally simplified, and invariants that matter in production
may be deliberately ignored to keep an example readable. Passing tests demonstrate only the specific
scenarios described by each POC; they do not guarantee correctness, safety, liveness or economic
soundness under any other configuration, parameter set, market condition or integration.

**Not a Morpho product, and no endorsement.** These POCs are research artifacts. They are not
Morpho products, are not part of the Morpho protocol, are not deployed or maintained by the Morpho
DAO, and their presence in this organization does not imply endorsement, support, or any intention to
productionize them. Deployed addresses appearing anywhere in this repository, if any, are test
artifacts and must not be treated as canonical.

**No maintenance, support or stability guarantees.** This repository may be modified, rewritten,
archived or deleted without notice. There is no release process, no versioning guarantee, no
backwards compatibility guarantee and no support channel. Dependencies may be outdated or contain
known vulnerabilities. Documentation may be stale or contradict the code, in which case neither
should be trusted.

**Forward-looking material is not a commitment.** Documentation-only POCs and design notes describe
ideas under exploration. They do not describe existing functionality, do not constitute a roadmap,
and may never be implemented.

**Not advice or an offer.** Nothing in this repository is financial, investment, legal, tax or
accounting advice, and nothing here is an offer, solicitation or recommendation to enter into any
transaction or to use any financial product. Any economic figures, rates or yields shown are
illustrative only.

**No warranty and no liability.** All material in this repository is provided "as is" and "as
available", without warranty of any kind, express or implied, including without limitation any
warranty of merchantability, fitness for a particular purpose, title or non-infringement. To the
maximum extent permitted by applicable law, the authors, contributors and Morpho entities accept no
liability for any claim, damage or loss of any kind arising from or in connection with this
repository or its use, including loss of funds.

**You are responsible for compliance.** If you choose to experiment with this code you do so
entirely at your own risk and are solely responsible for complying with all laws and regulations
applicable to you.
