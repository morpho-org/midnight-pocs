# Midnight Warehousing POC

This directory describes a future proof of concept for financing a portfolio of fixed-maturity Midnight loans
with senior and junior capital. It contains no implementation code yet.

## Objective

The POC should demonstrate that an on-chain facility can:

1. Receive junior capital from a sponsor and senior capital from a lender.
2. Use the combined capital to fund eligible borrower loans on Midnight.
3. Track the facility's cash, loan assets, senior debt and junior equity without inventing balances that are not
   present on-chain.
4. Move or refinance positions as maturities approach.
5. Apply repayments and losses through a defined senior/junior waterfall.
6. Return lender principal, residual sponsor value and collateral when the facility closes.

## Proposed participants

- **Borrower:** receives fixed-maturity financing and pledges collateral through Midnight.
- **Facility or SPV:** holds the financed positions and applies the eligibility and accounting rules.
- **Senior lender:** supplies senior capital and receives repayment according to the senior terms.
- **Junior sponsor:** supplies first-loss capital and receives the residual economics.
- **Midnight:** provides the underlying fixed-maturity markets, debt, credit and collateral accounting.
- **Oracle and gates:** provide valuation and restrict participation or liquidation where required.

## Lifecycle to demonstrate

```text
Configure facility and permissions
            |
            v
Fund junior and senior capital
            |
            v
Originate eligible Midnight loans
            |
            v
Monitor, roll, repay or liquidate positions
            |
            v
Apply the senior / junior waterfall
            |
            v
Close the facility and return remaining assets
```

The implementation should keep custody, accounting and permissions explicit. Every figure shown by a future
walkthrough should be derived from contract and token state rather than authored presentation data.

## Questions to resolve before implementation

- Which party owns each Midnight debt, credit and collateral position?
- Which market fields are fixed by the facility, and which may change between maturities?
- What eligibility, concentration and loan-to-value limits are enforced on-chain?
- How are interest, fees, defaults, cures and liquidation proceeds allocated?
- Does the senior lender remain constant across rolls, and if so, how is roll liquidity supplied?
- Which actions require borrower, lender, sponsor or multi-party approval?
- What is the exact shutdown and run-off behavior after maturity or a breach?

## Current status

Documentation only. No contracts, deployment scripts, tests or UI are included in this directory.
