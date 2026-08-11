# Local walkthrough

This interface runs only against the Anvil Base fork configured in the repository root `.env`.

```bash
# terminal one
cp ../.env.example ../.env
./anvil.sh

# terminal two
pnpm install --frozen-lockfile
pnpm dev
```

Open `http://127.0.0.1:5111`.

- Choose **General refinance**, **Cash treasury**, **10 tranches** or **Flash loan**. The general case uses a new
  lender offer; the other three demonstrate same-lender liquidity options. Changing the method resets the local
  fork and prepares that implementation from scratch.
- The app starts with pledged collateral and zero debt.
- **Initiate first draw** opens the first Midnight loan.
- **Roll to next maturity** submits the real atomic roll and opens its five-step trace.
- **Roll again** prepares and executes another daily maturity.
- **Back** restores the pre-roll Anvil snapshot, including its timestamp.
- **Reset** returns to pledged collateral and zero debt.
- Every displayed balance and transaction is read from the local chain; the selector does not substitute a
  presentation-only animation.
- `pnpm verify` checks the full lifecycle, rewind and three consecutive rolls for all four rolling methods.

Experimental, unaudited demonstration code. Do not use it with real funds.
