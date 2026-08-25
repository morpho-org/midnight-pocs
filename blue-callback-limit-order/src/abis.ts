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
