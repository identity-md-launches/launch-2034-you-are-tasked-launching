# erc20t / IMD

A one-use Ethereum launch application and a complete retro-punk website for **erc20t (ERC20T)**. The application calls Adam’s existing `createAndLaunchAtPrice` factory entry point, then verifies the resulting token, allocations, taxes, v4 pool and locked position atomically.

**Status:** implementation and local verification; no mainnet transaction has been signed or broadcast by this project’s build task. The first factory clone already exists, so a first-ever claim would be false. The owner can explicitly accept a later launch; the app reports its exact ordinal from complete factory history after confirmation. Token address and transaction hash remain absent until the real launch receipt exists.

## Run and check

From the repository root:

```sh
forge build
forge test
forge fmt --check
node --test test/web/*.test.mjs
python3 -m http.server 8080 --directory site
```

Open `http://localhost:8080`. `make check` runs all four checks. The website needs HTTP rather than opening `index.html` directly, because it loads local JSON artifacts. It works without a build step, npm install, CDN, or external fonts. Live chain features require an Ethereum RPC; wallet actions require an injected EIP-1193 wallet.

Solidity is pinned to **0.8.26**, Cancun, optimizer 200 runs, `bytecode_hash = "none"`. The compiler is a toolchain prerequisite, not vendored. All Solidity and JavaScript library dependencies are ordinary files in this tree. No FFI, filesystem cheatcode permission, submodule, environment-dependent test, fork RPC, or signing key is required for the test suite. Fuzzing is pinned to the requested seed `0xface3edacf4f36dd957aadc03d25273051b79fc92fa080bf48025fa5c2679d06`, with 512 runs per property.

## What gets deployed

Only **`ERC20TLaunch`**, from `src/ERC20TLaunch.sol`, is an application in this handoff. Its single nonpayable constructor argument is `address owner_`, filled by the deployment manifest’s **`$owner`**, resolving to:

`0x3d6a89C8751a45DD577a4C1F3b34E71C58236193`

The constructor makes no external calls, creates no child contracts, needs no code at dependency addresses, and grants no role to its caller or `tx.origin`. It works on the protected floor’s empty chain. The application has no upgrade, delegatecall, arbitrary-call, withdrawal or ownership-transfer function. Its only write action is the owner’s one-use `launch`. The token itself becomes owned directly by the specified wallet, never by this application or either factory.

The separate deployment service supplies the manifest and application address. No `launch.json` is included. Deploying the application alone does **not** create the ERC20T token: the owner then calls its `launch` function. That call creates and launches the token and pool together through the supplied infrastructure. This separation is necessary because application constructors are rehearsed on an empty chain and the handoff deploys application bytecode, not a funded worker transaction.

## Exact launch parameters

| Parameter | Value |
| --- | --- |
| Chain | Ethereum mainnet, chain ID 1 |
| Token | `erc20t` / `ERC20T`, 18 decimals |
| Initial total supply | `1_000_000_000 * 1e18` |
| Creator allocation | 500 bps = `50_000_000 * 1e18`, directly to owner |
| Liquidity allocation | `950_000_000 * 1e18`, single-sided ERC20T |
| Resting token tax | 100 bps (1%) |
| Launch token tax | 9,900 bps (99%) |
| Decay | 100 bps per 60 seconds; reaches 100 bps at 5,880 seconds |
| Fee recipient | Owner |
| Fee decay recipient | Owner |
| v4 pool fee / tick spacing | 0 / 60; taxes are implemented by the hook |
| Existing hook protocol fee | **15 bps carved out of the token tax**, paid in ETH to the hook’s protocol recipient |
| Suggested price X18 | `540_540_540_540` |
| Deadline | Owner-selected, between current block time and 30 minutes later; website uses 10 minutes |
| Price bound, application | `0 < priceX18 <= MAX_PRICE_X18 = 1e18` |
| Price band, website | `1e10 <= priceX18 <= 1e14`, an FDV of 10 to 100,000 IMD; see "Price assumptions" |
| Rounding allowance | `MAX_LIQUIDITY_DUST = 1e12` token-wei (one millionth of one token) |

The hook takes the token tax from gross swap output, converts collected fees to native ETH through its configured IMD/ETH pool, then distributes them. Its protocol share is included in that tax: `protocolETH = floor(convertedTaxETH * 15 / currentTaxBps)`. At the 100 bps resting rate, the protocol receives 15% of converted fees and the owner receives 85%. At the 9,900 bps launch rate, the protocol receives 15/9,900 of converted fees. Both token fee streams initially go to the owner. The conversion pool has a 1% pool fee; conversion costs and price impact reduce realized ETH payouts. This behavior is asserted against captured mainnet bytecode in the buy/sell test.

The amount earmarked for liquidity is exactly 95%. Uniswap integer rounding can leave tiny residual tokens in the ERC20T contract. The application enforces `poolManagerBalance + tokenContractDust == 950_000_000e18`, an exact `50_000_000e18` owner balance, and the dust cap above. One observed default-price simulation left only 1,010 token-wei. It does not sweep or grant anyone custody of the LP position.

### The owner pays almost none of the launch tax

Both fee streams go to the owner, as the brief requires. The hook converts every collected tax to ETH and pays it to the fee recipients, so when the **owner** buys during the 99% window the tax on that trade comes back to the owner's own wallet, less the protocol's 15 bps share and the conversion pool's 1% fee and price impact. An independent simulation on the test fixture measured a net cost of about 0.31 IMD for a 10 IMD owner purchase at the 9,900 bps tax, while any other buyer loses 9.9 IMD of the same trade to tax. The anti-snipe schedule therefore deters everyone except the owner. Buyers must assume that the owner can accumulate during the decay at a small cost, and that the creator allocation is not vested. The only ways to remove this advantage are to route `feeDecayRecipient` elsewhere, for example to the protocol, which the brief allows but did not choose, or to have the owner refrain from trading during the decay. The application does not change the brief's recipients; the owner can call the token's `setFeeDecayRecipient` after launch.

### Transfer policy of the launched token

The implementation this factory clones, [`0x2df7…0eEe`](https://etherscan.io/address/0x2df7DCf4D19a7924e00AE96629CC1d1261670eEe), is **not a freely transferable ERC-20**. Its verified source (Solady `ERC20` plus an `_afterTokenTransfer` policy, contract `ERC20T`) reverts with the custom error `InvalidTransfer()` (`0x2f352531`) unless one of these holds, checked in this order:

1. The transfer is a mint or burn.
2. The transfer is to or from Uniswap's PoolManager, within the transfer allowance the hook grants during a swap of the canonical pool. This is how buys and sells settle.
3. The sender or the recipient is the token owner.
4. The sender or the recipient is an approved **distributor** contract: either on the token's own list (`setDistributors`, owner only, code only) or, while `useGlobalDistributors` is true, on the hook owner's shared registry (`IERC20THook.isDistributor`). New tokens start with `useGlobalDistributors = true`.
5. The call is a direct wallet transfer: `msg.sender == from`, `msg.sender == tx.origin`, and neither the sender nor the recipient has code.

In practice, after launch:

- A wallet can send ERC20T to another wallet with a plain `transfer` from its own transaction. These transfers are untaxed; the tax applies to pool swaps only.
- `transferFrom` by any spender reverts, even with an allowance, unless the owner or a distributor is on one side. Approvals to routers, aggregators, lending markets, bridges, airdrop tools, vesting or staking contracts do not work. Trades must go through the canonical ERC20T/IMD pool, whose hook grants the settlement allowance; a Uniswap v4 router swapping that pool works because the token moves to and from the PoolManager, not the router.
- A holder that has code (a Safe or other multisig, a smart-contract wallet, an EIP-7702 delegated account, an exchange custody contract) cannot send or receive ERC20T unless the owner approves it as a distributor. Sending to such an address reverts; nothing is lost, but the transfer does not happen.
- The token owner can transfer to and from anyone, and can approve or revoke distributor contracts at any time. A distributor "can transfer to or from any wallet" in the implementation's words, so the owner must only approve trusted code. The owner can also opt the token out of the hook owner's shared registry with `setUseGlobalDistributors(false)`; while it is opted in, the protocol's hook owner, not this project's owner, decides which shared contracts count as distributors.

No field of the factory's `TokenConfig` disables this policy, so the launch application cannot change it. The adapter launches the token as the brief specifies and documents the policy here, in the website FAQ and technical notes, and in `docs/SECURITY_REVIEW.md`. The tests in `test/ERC20TLaunch.t.sol` execute the captured implementation and assert each branch: direct wallet transfers succeed during and after the decay; `transferFrom`, transfers from contract holders, transfers to contracts and relayed wallet calls revert with `InvalidTransfer()`; the owner can approve and revoke a distributor contract; wallets cannot become distributors; only the owner can change the lists.

The fixed burn address `0x000000000000000000000000000000000000dEaD` is **hardcoded by the existing token implementation as its position NFT recipient**. It is not an invented beneficiary or a missing configuration value. The application checks `ownerOf(positionId)`, positive liquidity, exactly one newly minted position, and a pool key matching the token, IMD, hook, fee and tick spacing. A failure reverts the entire factory operation.

### Existing infrastructure

| Contract | Ethereum address |
| --- | --- |
| Factory | `0x801411c6aCeC4Fa80c75c5d3C0eAe13C84f8a173` |
| Hook | `0xed9A04Fa6693e754661A22502524DF9b1857e544` |
| IMD | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` |
| PositionManager | `0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| PoolManager, read from the infrastructure | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| Factory token implementation, read onchain | `0x2df7DCf4D19a7924e00AE96629CC1d1261670eEe` |
| IMD/ETH fee-conversion hook, read onchain | `0xc6C965Bd164c483e87d0B550671798e9A3602840` |

Runtime hashes are checked before launch. The application also checks IMD decimals, the factory implementation pointer, the configured protocol recipient and the tested IMD-to-ETH fee-conversion route. Hashes bind this integration to the bytecode actually tested; they do not freeze mutable state or constitute an audit.

## Price assumptions

The factory input is **IMD per ERC20T, scaled by 1e18**. Both currencies have 18 decimals, verified for IMD on mainnet. The factory handles token sorting and snaps the starting price to its single-sided tick range; the requested and actual tick prices can differ by approximately one 60-tick spacing (~0.6%). Tests cover both currency sort orders and opening price tolerance.

The launch is one-shot: a mis-priced launch cannot be retried, because the position is burned to the implementation's lock address and the application refuses a second launch. The application accepts any `priceX18` in `1..1e18`; that bound keeps the factory's arithmetic in its tested range, it is not a sanity check on the valuation. The website, which is the shipped launch path, additionally refuses a price outside the band `1e10..1e14` (an FDV of **10 to 100,000 IMD**, roughly $55 to $555,000 at the observation below) before it simulates, so that a slipped decimal point cannot reach the wallet; the review dialog then prints the exact price and FDV in IMD that will be sent. An owner who deliberately wants a price outside the band must call `launch` directly and takes responsibility for the valuation.

The suggested price is `0.00000054054054054 IMD / ERC20T`, giving an indicative fully diluted valuation of **540.54054054 IMD**. A [DEX Screener IMD/ETH observation](https://dexscreener.com/ethereum/0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3) at **$5.55 per IMD on 16 October 2026** implies about **$3,000 FDV**. This historical spot quote is not used as an oracle or a promise of cash backing. The owner must review the current quote before signing. No IMD or ETH principal is deposited at launch; the caller pays Ethereum gas.

## Factory order and evidence

The factory deployed at block **26,208,074**. It created its implementation with CREATE nonce 1; its first possible token clone is CREATE nonce 2:

`0xBBe9d1EcBae3D811642f3DFFDF8bC5Ae8ea4514f`

The complete preparation-time scan found **five** token creations through block **26,208,549**. That first address already had code and a successful creation/launch receipt at block **26,208,319**. The transaction is [0x5b34…6ba6](https://etherscan.io/tx/0x5b34bbd33143fb92f0102539918cc1115f2fc4f4a44b134e8568b34c5b636ba6). It is another token, not this project’s receipt.

`launch(priceX18, deadline, true)` therefore fails on the occupied first slot. With `requireFirst = false`, only the designated owner can accept a later launch. There is no fabricated onchain count: the factory exposes no total-created counter. The frontend scans `TokenCreated` logs from the deployment block in complete 2,000-block ranges, validates the factory hash and anchor block, and computes the ordinal by matching both token and transaction in chain order. Partial scans and RPC errors never become “zero tokens.” Another transaction may take an earlier position while the owner reviews; simulation reserves nothing.

Read-only CLI preflight:

```sh
node tools/preflight.mjs
```

It optionally accepts a public RPC URL and an output file as positional arguments. It cannot send or sign a transaction. `docs/preflight-observation.json` records a preparation-time observation; refresh it for an operational decision. See [docs/EVIDENCE.md](docs/EVIDENCE.md) for provenance and limits.

## After launch

1. The deployment operator supplies the confirmed **application** address. Set `controller` in `site/deployment.json`, or paste it into the website. No token or pool address is guessed. The browser checks the exact compiled runtime with the designated owner inserted in its immutable slots.
2. The owner reviews current IMD pricing, full factory history, the 99% launch tax, the 15 bps protocol share of the tax, fees/allocations, gas and deadline. Connect the owner wallet on mainnet, explicitly accept a later factory launch if desired, and choose **Review & simulate launch**.
3. Review the concrete simulation, then choose **Confirm in wallet**. The transaction explicitly names chain 1. An expired review, wrong account/chain, changed application or rejected wallet request requires a fresh review.
4. Record the successful application `Launched` event, token address, transaction hash, pool ID and position ID. Refresh the app to verify the receipt against application state and complete factory history. The website displays mined versus confirmed status; trade/watch-asset links require 12 confirmations. Download the verified evidence JSON from the proof panel.
5. Publish the application address and confirmed evidence. The app can recover the launch receipt from `launchBlock()` after a reload; no wallet secret or local transaction-history database is needed. Verify the source and monitor the token’s current owner, recipients, tax and the hook’s protocol settings.
6. Decide the token's transfer policy settings on the **token** contract (owner only, see "Transfer policy of the launched token"): `setDistributors(address[] accounts, bool allowed)` for every contract that must hold or move ERC20T (a treasury multisig, a vesting or staking contract, an airdrop tool), and `setUseGlobalDistributors(bool)` to keep or drop the hook owner's shared registry, which is on by default. Approve only audited code. Nothing in the launch application sets these.
7. Decide whether the owner keeps `feeDecayRecipient` (see "The owner pays almost none of the launch tax"); `setFeeDecayRecipient` on the token changes it.

There are no missing requester-owned services, oracle IDs or contract settings, and no app setters to initialize after deployment. Price, deadline and first-only acceptance are explicit owner inputs at launch. The **existing token** retains administrative powers: resting-tax edits are blocked during decay, then restricted to the implementation’s **30–500 bps** range; fee recipients, distributor permissions and ownership can change under its own access controls. Both initial fee recipients belong to the owner, while the hook’s protocol recipient belongs to the existing protocol. The creator’s 5% allocation is immediately available and not vested. Single-sided liquidity locking does not guarantee a price or prevent selling the creator allocation. Holder-to-holder transfers are limited to direct wallet calls unless the owner or an approved distributor is involved.

The application constructor rejects the zero address, itself and the factory as owner. It does not reject the other pinned infrastructure addresses: an application deployed with, say, the hook as owner would be inert, because only the owner can call `launch` and a contract never will. The manifest fills the owner with the fixed `$owner` value above, the website refuses to work with an application whose `owner()` differs from that wallet, and an inert application is redeployed rather than repaired, so no funds or token can be affected. Verify `owner()` on the deployed application before publishing its address.

## Tests and maintenance

The [local validation record](docs/VALIDATION.md) reports 42 Foundry tests, 13 JavaScript tests and browser integration checks passing for the accepted build, and explains why the four Foundry tests and one JavaScript test added by the transfer-policy revision (46 and 14 expected) could not be executed on the worker that wrote them.

- `test/Deployment.t.sol`: empty-chain factory deployment with explicit ownership; invalid owners; EIP-170 size and forbidden-opcode rehearsal.
- `test/ERC20TLaunch.t.sol`: actual captured factory/implementation/hook/Uniswap runtimes; allocation and tax checks; first-only and later launches; both token orders and opening prices; fuzzed prices and tax time; deadline, authorization, replay, reentry, dependency and rollback failures; the token's transfer policy (direct wallet transfers, `transferFrom`, contract holders, distributors, the shared registry switch). Fault injection uses Foundry mocks only in specifically named failure tests. `test/helpers/HolderProbe.sol` is a test-only contract holder.
- `test/web/core.test.mjs` also covers the website's price band.
- `test/fixtures/MainnetState.sol`: captured runtime bytecode and required real mainnet storage, embedded as Solidity literals so the suite works with no network or filesystem permission. `provenance.json` gives the block hash, dependency hashes and nonces. It is not replacement token or AMM logic.
- `test/web/core.test.mjs`: exact decimal math; receipt validation; first/ordinal evidence; full history range coverage; reorg/error handling; runtime/owner verification; static asset completeness.
- `test/browser/check.mjs`: optional Chromium browser check of responsive layouts, wallet switching, application verification, first-only rejection, simulation, stale reviews, rejected submissions, confirmed receipts, token import and reorg handling. Run `node test/browser/check.mjs /path/to/chrome-headless-shell`; screenshots are written under `test/scratch/` and are not shipped.
- `tools/export-artifacts.mjs`: after a Solidity change, run `make export` and include the regenerated local browser artifact. The frontend refuses a deployment with different runtime bytes.
- `tools/capture-fixture.mjs`: optional read-only fixture refresh. It uses `eth_call`, `eth_createAccessList` and state reads, never broadcasting. A refresh changes a test artifact and must be reviewed, not used to weaken dependency checks.

The factory and token implementation were not source-verified on the queried explorer during preparation. The ABI is matched to observed calldata, bytecode selectors and successful production-bytecode simulations. A separate independent adversarial review of this application **and the external infrastructure** remains an operational responsibility before committing real funds. The local tests and [implementation review](docs/SECURITY_REVIEW.md) in this repository are not that independent audit.

Third-party versions and licenses are in [THIRD_PARTY.md](THIRD_PARTY.md). The web experience includes no analytics, remote image service or CDN dependency.
