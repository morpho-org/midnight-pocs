export const erc20Abi = [
  {
    type: 'function',
    name: 'balanceOf',
    stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ name: 'balance', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'approve',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'spender', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
    outputs: [{ name: 'success', type: 'bool' }],
  },
  {
    type: 'function',
    name: 'transfer',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'to', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
    outputs: [{ name: 'success', type: 'bool' }],
  },
] as const

const blueMarketParams = [
  { name: 'loanToken', type: 'address' },
  { name: 'collateralToken', type: 'address' },
  { name: 'oracle', type: 'address' },
  { name: 'irm', type: 'address' },
  { name: 'lltv', type: 'uint256' },
] as const

export const blueAbi = [
  {
    type: 'function',
    name: 'supply',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'marketParams', type: 'tuple', components: blueMarketParams },
      { name: 'assets', type: 'uint256' },
      { name: 'shares', type: 'uint256' },
      { name: 'onBehalf', type: 'address' },
      { name: 'data', type: 'bytes' },
    ],
    outputs: [
      { name: 'assetsSupplied', type: 'uint256' },
      { name: 'sharesSupplied', type: 'uint256' },
    ],
  },
  {
    type: 'function',
    name: 'withdraw',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'marketParams', type: 'tuple', components: blueMarketParams },
      { name: 'assets', type: 'uint256' },
      { name: 'shares', type: 'uint256' },
      { name: 'onBehalf', type: 'address' },
      { name: 'receiver', type: 'address' },
    ],
    outputs: [
      { name: 'assetsWithdrawn', type: 'uint256' },
      { name: 'sharesWithdrawn', type: 'uint256' },
    ],
  },
  {
    type: 'function',
    name: 'position',
    stateMutability: 'view',
    inputs: [
      { name: 'id', type: 'bytes32' },
      { name: 'user', type: 'address' },
    ],
    outputs: [
      { name: 'supplyShares', type: 'uint256' },
      { name: 'borrowShares', type: 'uint128' },
      { name: 'collateral', type: 'uint128' },
    ],
  },
] as const

export const blueBuyCallbackFactoryAbi = [
  {
    type: 'function',
    name: 'callbackOf',
    stateMutability: 'view',
    inputs: [
      { name: 'owner', type: 'address' },
      { name: 'salt', type: 'bytes32' },
    ],
    outputs: [{ name: 'callback', type: 'address' }],
  },
  {
    type: 'function',
    name: 'createBlueBuyCallback',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'owner', type: 'address' },
      { name: 'salt', type: 'bytes32' },
    ],
    outputs: [{ name: 'callback', type: 'address' }],
  },
] as const

const collateralParams = [
  { name: 'token', type: 'address' },
  { name: 'lltv', type: 'uint256' },
  { name: 'liquidationCursor', type: 'uint256' },
  { name: 'oracle', type: 'address' },
] as const

const midnightMarket = [
  { name: 'chainId', type: 'uint256' },
  { name: 'midnight', type: 'address' },
  { name: 'loanToken', type: 'address' },
  { name: 'collateralParams', type: 'tuple[]', components: collateralParams },
  { name: 'maturity', type: 'uint256' },
  { name: 'rcfThreshold', type: 'uint256' },
  { name: 'enterGate', type: 'address' },
  { name: 'liquidatorGate', type: 'address' },
] as const

export const blueBuyCallbackAbi = [
  {
    type: 'function',
    name: 'OWNER',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: 'owner', type: 'address' }],
  },
  {
    type: 'function',
    name: 'buyerAssetsBound',
    stateMutability: 'view',
    inputs: [
      { name: 'id', type: 'bytes32' },
      { name: 'market', type: 'tuple', components: midnightMarket },
      { name: 'buyer', type: 'address' },
      { name: 'data', type: 'bytes' },
    ],
    outputs: [{ name: 'assets', type: 'uint256' }],
  },
] as const
