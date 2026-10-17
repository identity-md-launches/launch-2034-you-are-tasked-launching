# Local validation

Completed with Solidity **0.8.26** and the root `foundry.toml` configuration.

| Check | Result |
| --- | --- |
| `forge build` | Passed; heuristic lint diagnostics reviewed in `SECURITY_REVIEW.md` |
| `forge test` | **42 passed, 0 failed, 0 skipped** across two suites |
| Fuzzing | Five properties, 512 runs each, seed below |
| `forge fmt --check` | Passed |
| `node --test test/web/*.test.mjs` | **13 passed, 0 failed** |
| Chromium integration check | Passed; local mock RPC/wallet, no submitted transactions |
| Application runtime | **10,000 bytes**, below EIP-170's 24,576-byte limit |
| Application creation bytecode | **10,280 bytes** before its single static constructor argument |
| Link placeholders | None |
| Empty-chain construction and explicit owner | Passed |
| Forbidden application opcodes | No DELEGATECALL, CALLCODE or SELFDESTRUCT |

Fuzz seed:

```text
0xface3edacf4f36dd957aadc03d25273051b79fc92fa080bf48025fa5c2679d06
```

The integration suite executes captured mainnet runtime bytecode for actual token creation, single-sided position minting, tax decay, buys, sells and fee conversion. Fault injection separately covers rejection and rollback. The browser check verifies network switching, owner and runtime checks, first-only rejection, simulation before signing, stale review invalidation, explicit mainnet transaction requests, wallet rejection, receipt recovery, five versus fifteen confirmations, factory ordinal, token import, reorg handling and layouts at 390, 768 and 1,440 pixels. Screenshots were inspected locally and remain disposable test scaffolding.

The optional Chromium executable is a testing tool, not an application dependency. The website's JavaScript, fonts and Solidity test dependencies are vendored in the delivered tree. The mandatory build and test commands do not use a live RPC, a wallet, `test/scratch/`, or an environment variable for application configuration. The seed is also pinned in Foundry configuration.

These are local check results, not independent verification or a security audit. No project token address or mainnet launch transaction is asserted. Deployment and owner execution remain with the documented handoff.
