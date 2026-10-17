export const CONFIG = Object.freeze({
  chainId: 1,
  owner: '0x3d6a89C8751a45DD577a4C1F3b34E71C58236193',
  factory: '0x801411c6aCeC4Fa80c75c5d3C0eAe13C84f8a173',
  hook: '0xed9A04Fa6693e754661A22502524DF9b1857e544',
  quoteToken: '0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7',
  positionManager: '0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e',
  permit2: '0x000000000022D473030F116dDEE9F6B43aC78BA3',
  poolManager: '0x000000000004444c5dc75cB358380D2e3dE08A90',
  conversionHook: '0xc6C965Bd164c483e87d0B550671798e9A3602840',
  firstToken: '0xBBe9d1EcBae3D811642f3DFFDF8bC5Ae8ea4514f',
  factoryDeploymentBlock: 26208074,
  rpcUrl: 'https://ethereum-rpc.publicnode.com',
  supply: 1_000_000_000n * 10n ** 18n,
  suggestedPriceX18: 540_540_540_540n,
  factoryCodeHash: '0x474f926e1425178a191768de94d3a734dec4b8e8ba8095699e511e8275ab1867',
  quoteObservation: Object.freeze({
    usd: '5.55',
    date: '2026-10-16',
    source: 'https://dexscreener.com/ethereum/0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3'
  })
});

export const TOKEN_ABI = [
  'function name() view returns(string)', 'function symbol() view returns(string)',
  'function decimals() view returns(uint8)', 'function owner() view returns(address)',
  'function totalSupply() view returns(uint256)', 'function balanceOf(address) view returns(uint256)',
  'function launchedAt() view returns(uint64)', 'function taxBps() view returns(uint16)',
  'function restingTaxBps() view returns(uint16)', 'function launchTaxBps() view returns(uint16)',
  'function taxDecayIntervalSeconds() view returns(uint32)',
  'function feeRecipient() view returns(address)', 'function feeDecayRecipient() view returns(address)',
  'function poolKey() view returns(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)'
];
