import { addresses } from '@morpho-org/morpho-ts'
import type { IMarketParams } from '@morpho-org/midnight-sdk'
import type { Address, Hash, Hex } from 'viem'
import { zeroAddress } from 'viem'

export const CHAIN_ID = 8453
export const RPC_URL = process.env.ANVIL_RPC ?? 'http://127.0.0.1:8545'

const baseAddresses = addresses[CHAIN_ID]

export const BLUE = baseAddresses.blue!
export const MIDNIGHT = baseAddresses.midnight!
export const CALLBACK_FACTORY = baseAddresses.midnightBlueBuyCallbackFactory!
export const ECRECOVER_RATIFIER = baseAddresses.ecrecoverRatifier!
export const USDC = baseAddresses.usdc!
export const CBBTC: Address = '0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf'

export const BLUE_MARKET_ID: Hash =
  '0x9103c3b4e834476c9a62ea009ba2c884ee42e94e6e314a26f04d312434191836'
export const MIDNIGHT_MARKET_ID: Hash =
  '0x9593c3a6dba45b6106af8dc8b45ba8c505d90d3d68a3d33f7c278dd921b637da'

export const BLUE_MARKET = {
  loanToken: USDC,
  collateralToken: CBBTC,
  oracle: '0x663BECd10daE6C4A3Dcd89F1d76c1174199639B9' as Address,
  irm: '0x46415998764C29aB2a25CbeA6254146D50D22687' as Address,
  lltv: 860_000000000000000n,
} as const

export const MIDNIGHT_MARKET: IMarketParams = {
  chainId: CHAIN_ID,
  midnight: MIDNIGHT,
  loanToken: USDC,
  collateralParams: [
    {
      token: CBBTC,
      lltv: 860_000000000000000n,
      liquidationCursor: 300_000000000000000n,
      oracle: BLUE_MARKET.oracle,
    },
  ],
  maturity: 1_798_210_800n,
  rcfThreshold: 3_000_000_000n,
  enterGate: zeroAddress,
  liquidatorGate: zeroAddress,
}

export const MAKER_PRIVATE_KEY: Hex =
  '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'
export const BORROWER_PRIVATE_KEY: Hex =
  '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d'
