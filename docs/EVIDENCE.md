# Chain evidence and reproducibility

No transaction was signed or broadcast during this build. The application address is supplied by the deployment handoff; the new token, pool and launch transaction are populated only from a successful owner-authorized launch. Addresses returned by `eth_call` are predictions, not deployments.

## Factory history

The supplied [factory](https://etherscan.io/address/0x801411c6acec4fa80c75c5d3c0eae13c84f8a173) deployed at block **26,208,074**, transaction [0xdf27…fd5a](https://etherscan.io/tx/0xdf27d0960e641cfa4b2715a27a37860c022592484feab22ff53977e242ccfd5a). Its first CREATE operation deployed the implementation at `0x2df7DCf4D19a7924e00AE96629CC1d1261670eEe`. CREATE nonce 2 is the first token clone:

`0xBBe9d1EcBae3D811642f3DFFDF8bC5Ae8ea4514f`

That token already existed at block **26,208,319**, transaction [0x5b34…6ba6](https://etherscan.io/tx/0x5b34bbd33143fb92f0102539918cc1115f2fc4f4a44b134e8568b34c5b636ba6). It is another project's PLAYGROUND / PLAY token. It must never be presented as this project's token or receipt.

The initial complete scan through block **26,208,549** found **five** `TokenCreated` events. The machine-readable [preflight observation](preflight-observation.json) records a subsequent complete preparation-time scan, block hash, individual token addresses and transaction hashes. That file is a historical observation; use a fresh scan for a launch decision. The factory nonce alone is not used as a token counter.

The observed event signature is `TokenCreated(address,address,address,address)`, topic `0xf4bf74f6b8c0023b530c01bf7708105754bccf66e3e96db36dccad016af082d7`. Topic 1 contains the token, topic 2 the temporary owner (the factory during creation), and topic 3 the creator. The hook is non-indexed data. Explorer-generated parameter labels were inconsistent with the real calldata and trace; this project decodes raw topics instead. The app scans all blocks from factory deployment in consecutive 2,000-block ranges, checks the factory runtime and anchor hash, deduplicates logs, and matches the final token **and** transaction to derive its ordinal. Failed or partial queries do not imply an empty factory.

## Factory ABI

The matching entry point is:

```solidity
createAndLaunchAtPrice(
    (string,string,uint256,uint256,address,address,address,address,address,
     uint16,address,uint16,uint32,address),
    uint16,
    uint256
) payable returns (address)
```

Selector: **`0xfe30ec00`**. The tuple field names and order are in `src/interfaces/IERC20TFactory.sol`. The observed factory calldata, implementation selectors, mainnet `eth_call`, and offline execution of the captured factory establish this integration. The wrapper's own `launch` is nonpayable and forwards zero ETH. The factory and token implementation were not source-verified on the queried explorer during preparation. Empirical compatibility is not a substitute for their source audit.

## Offline integration fixture

`test/fixtures/MainnetState.sol` captures public runtime bytecode, nonces, native balances and storage required by the launch and trades at:

- Ethereum block **26,208,519**.
- Hash **`0xc3936c45f84438a95414cb8f4969e52d49cac97a69809bae13e6ac578df73157`**.
- Timestamp **1792194875**.
- Factory nonce **7**.

`test/fixtures/provenance.json` lists every captured account, code hash, code length and accessed slot count. The fixture includes the factory, token implementation, ERC20T hook, IMD, Permit2, PositionManager, PoolManager, the existing IMD/ETH conversion hook and protocol recipient. It uses real runtime bytes and storage, not a replacement AMM or invented token implementation. Only these accessed paths are captured; this is not a complete mainnet state dump.

The optional `tools/capture-fixture.mjs` reads an RPC URL from a positional argument. It uses public JSON-RPC calls, including `eth_call` and `eth_createAccessList`. To discover the complete trading path, it temporarily installs `LaunchAndTradeProbe` code at the known owner address and supplies simulated IMD using RPC **state overrides**. These exist only within the read-only call. The stored fixture then reads the **original mainnet** bytecode and storage, never those overrides. The local tests fund only their test swap harness. No account key, signature, transaction submission, environment secret or production balance modification is involved.

The probe is compiled without Foundry's dynamic test-linking rewrite so its child creation is ordinary EVM CREATE, not a cheatcode. Capture requires an RPC that supports access lists, state overrides and the selected historical block. Normal `forge build` and `forge test` need none of these: all inputs are embedded in ordinary repository files. A fixture refresh is a source change requiring review; it must not automatically alter production fingerprints.

## Observed launch and fee settlement

At the suggested input price `540540540540`, the actual production implementation creates the requested 1 billion supply, allocates exactly 50 million to the explicit owner, and transfers the liquidity allocation minus **1,010 token-wei** of rounding dust to PoolManager. The initial position NFT is minted to the implementation's fixed `0x000000000000000000000000000000000000dEaD` recipient. This is a verified protocol lock destination, not a guessed owner or fee recipient. The wrapper checks the destination, liquidity and pool identity atomically.

The fee-conversion route read from `externalBasePool(IMD)` is native ETH / IMD, fee **10,000 millionths (1%)**, tick spacing **60**, hook **`0xc6C965Bd164c483e87d0B550671798e9A3602840`**. Native ETH is represented by currency address zero as required by Uniswap v4. Both `externalBases(IMD)` flags are true. The application checks those values and the conversion hook runtime before launch. It does not own or freeze this external route.

In the fixture, a one-IMD buy at the 99% launch tax produces these amounts:

| Item | Raw integer amount |
| --- | ---: |
| Gross ERC20T output | 1843793748354867823413727 token-wei |
| ERC20T received by buyer | 18437937483548678234138 token-wei |
| Collected fees converted to ETH | 2255285871303536 wei |
| Protocol ETH payout | 3417099805005 wei |
| Owner ETH payout | 2251868771498531 wei |

The buyer receives gross output minus `floor(grossOutput * 9900 / 10000)`. The protocol receives `floor(convertedTaxETH * 15 / 9900)`; it is carved out of the token tax. At the 100 bps resting tax the protocol receives 15% of converted fees, with 85% paid to the owner. The buy/sell test checks gross versus net outputs, the actual native ETH balance changes, recipient split, supply conservation and slippage rollback. ETH realization depends on the conversion pool's fee, price impact and availability.

The recorded read-only probe buys and sells immediately at the launch tax. The offline integration test separately advances time to the resting tax before selling. Their sell outputs intentionally differ. Neither result is a market quotation or a promise of production execution.

## Valuation observation

The suggested input means `0.00000054054054054 IMD` per ERC20T, or **540.54054054 IMD** initial FDV before tick rounding. A [DEX Screener IMD/ETH observation](https://dexscreener.com/ethereum/0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3) on 16 October 2026 showed **$5.55/IMD**, implying approximately **$3,000 FDV**. It is a historical spot observation, not an oracle. The owner chooses the final price and pays gas. Single-sided liquidity supplies no quote-token backing at launch.
