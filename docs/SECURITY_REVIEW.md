# Implementation review and release responsibilities

This is a review of the submitted integration, not an independent audit. The application uses existing, partly source-unverified infrastructure. An independent contributor should review the application and that infrastructure before release involving real funds.

## Authority and deployment

`ERC20TLaunch` takes one explicit immutable owner. The deployment manifest supplies `$owner`, resolving to the wallet named in the README. The factory caller and transaction origin receive no role. The constructor rejects the zero address, itself and the factory; it accepts other pinned infrastructure addresses, which would produce an inert application that nothing can launch and nothing can lose. The website refuses an application whose `owner()` differs from the designated wallet, and the README asks the operator to verify `owner()` before publishing. An inert deployment is replaced, not repaired. Construction is nonpayable, performs no external calls, and works on an empty chain. Only `launch` changes application state; it checks the owner and Ethereum chain ID before proceeding. The application has no admin reassignment, token custody, approval path, upgrade, arbitrary execution or withdrawal. Lost owner access cannot be recovered through it.

The token is created only during the later owner call and is owned by that wallet. Its 5% allocation is immediately liquid. The underlying implementation retains owner powers over tax after decay, recipients, distributors and ownership. Initial tax values are fixed by this application, not guaranteed permanently. Those powers are disclosed in the site and tested where exercised. The application cannot administer the token after launch.

## Transfer policy of the launched token

The implementation the factory clones (`ERC20T`, Solady `ERC20` plus Solady `Ownable`, source verified on Blockscout and Sourcify for `0x2df7DCf4D19a7924e00AE96629CC1d1261670eEe`) enforces a transfer policy in `_afterTokenTransfer`. A transfer passes only if it is a mint or burn; or it touches the PoolManager within the allowance the hook grants during a canonical-pool swap; or the owner is the sender or recipient; or a distributor contract (local list, or the hook owner's shared registry while `useGlobalDistributors` is true, which is the initial state) is the sender or recipient; or it is a direct wallet call with `msg.sender == from == tx.origin` and neither side has code. Everything else reverts with `InvalidTransfer()` (`0x2f352531`). The consequences for holders, the owner's distributor powers, and the fact that the hook owner's shared registry is trusted by default are disclosed in the README, the website FAQ and the technical notes. No `TokenConfig` field changes this, so the application cannot. Tests execute the captured implementation for each branch: direct wallet transfers during and after the decay, `transferFrom`, contract holders, transfers to contracts, relayed wallet calls, approving and revoking a distributor, rejecting a wallet as distributor, and opting out of the shared registry.

An earlier review reported that ordinary holder-to-holder transfers revert. That is accurate for every path except a wallet's own `transfer` in its own transaction; a test harness that pranks `msg.sender` without `tx.origin`, or holds tokens in a contract, observes the revert. The direct wallet path is tested with both `msg.sender` and `tx.origin` set.

## The owner and the launch tax

Both fee recipients are the owner, as the brief requires. Because the hook pays converted tax to those recipients, the owner's own trades during the decay cost only the protocol's 15 bps carve-out plus conversion costs (about 3% of the trade in an independent fixture simulation), while every other buyer pays the scheduled rate. This is disclosed on the site and in the README as a trust assumption; the remedy, if the requester wants one, is to set `feeDecayRecipient` to the protocol after launch or to revise the brief. The application does not deviate from the brief.

## External calls, reentry and rollback

Dependency queries before the state transition are view calls and therefore static calls. `status = Launching` is set before the factory's state-changing call. A callback by any other account fails authorization; even a callback through a contract owner fails the Ready-state check. A fault-injection test redirects the factory call, preserves its checked code hash, and demonstrates the owner callback receives `AlreadyLaunched`. The entire failed launch restores Ready state.

After the factory returns, every postcondition is checked before storing the successful receipt. Tests inject failed factory calls, invalid output, missing creator funds, an unlocked NFT and zero position liquidity; creation, factory nonce or position state roll back. There is no partial successful application state. A second successful launch is prohibited.

The integration makes no ETH or token transfers itself and needs no user approvals. Token initialization and Permit2 allowances are handled by the pinned infrastructure. Fees from subsequent trading are converted and paid by the external hook. Recipient failures, malicious protocol changes and conversion-route availability remain external operational risks. The app verifies current route configuration before launch; it cannot guarantee that configuration remains unchanged afterward.

## Supply, pricing and lock

Tests execute the captured real factory, token implementation, hook and Uniswap runtimes. Five fuzz properties run 512 cases each with the required seed. Price coverage includes both currency sort orders; allocation conservation is exact, with a bounded `1e12` token-wei rounding allowance. Actual swap tests verify token inventory, gross/net tax, native fee payouts, protocol share and failed-slippage rollback.

The owner picks a positive price no greater than 1 IMD per token. The application bound keeps the factory arithmetic in its tested range; it is not a valuation check, and a launch is one-shot. The website, the shipped launch path, refuses a price outside an FDV of 10 to 100,000 IMD before simulating and before sending, and shows the exact FDV in the review dialog. The application runtime was left unchanged in this revision because the browser verifies deployments against the reviewed runtime artifact; a tighter on-chain band remains a candidate for a future build that regenerates that artifact. The suggestion is a documented historical valuation, not an oracle. Fixed supply multiplication fits within uint256; the explicit price bound also keeps this factory's launch arithmetic in its tested range. Fuzzing does not prove all production states. The factory snaps to a 60-tick grid; the tested suggested opening price is within one spacing of the requested value.

The verified initial NFT belongs to the implementation's fixed burn address and has positive liquidity for the exact expected pool key. The wrapper cannot recover it. This locks the initial position; it does not lock the creator allocation, prevent new positions, guarantee quote liquidity, or eliminate trading loss. Permanent inaccessibility relies on the burn address and existing PositionManager semantics.

## First-token evidence and transaction ordering

The factory is already occupied. `requireFirst = true` fails before creation. If the first-clone probe is empty, the wrapper additionally requires the returned token to be that first CREATE address, preventing a missing-code probe from falsely labeling a later nonce. Tests cover both conditions and an unused factory state. This relies on the exact pinned factory runtime and its CREATE ordering.

The frontend separately scans complete creation history. It never estimates an ordinal from a nonce or a simulation. First-only preference defaults on; the owner must explicitly accept a later launch. Other launches can execute before the owner's transaction. Simulation cannot reserve an address or ordinal.

## Browser transaction boundary

The browser validates chain ID, exact compiled application runtime with the owner immutable inserted, and the returned owner. Before requesting a transaction it checks the wallet account, scans history, simulates, estimates gas, and displays a concrete review. A changed account, network, address or price invalidates the review. Submission checks those values again, simulates again, and sets chain ID 1 explicitly. The application independently checks authority, deadline and launch arguments.

Confirmed details are recovered from a successful receipt, its canonical block, the application's emitted event and stored token/pool/position. Ordinal comes from matching the token and transaction in full factory history. Links to trading and wallet import require 12 confirmations. This is a UI threshold, not a finality proof. A refresh detects changed receipt/state; data are labeled as snapshots and proof-dependent actions are disabled when RPC reads fail. RPC honesty, wallet integrity and secure site hosting remain trust assumptions.

All displayed chain values use text nodes and validated address/transaction links. Scripts, fonts and artwork are local files. A restrictive CSP excludes remote scripts and limits network reads to the configured public RPC. Changing that endpoint requires updating both the configuration and CSP. Production hosting should use HTTPS and appropriate security/cache headers. No credentials or analytics are required.

## Checks and remaining responsibilities

The delivered tests cover empty-chain construction, runtime size and forbidden opcodes, authorization, chain ID, deadlines, replay, reentry, changed dependency code, changed configuration, creation rollback, liquidity lock, tax boundaries, both token sort orders, real trading and fee settlement. JavaScript unit tests cover exact decimal parsing, runtime ownership, receipts, full history scans, errors and reorgs. The optional browser test uses a local mock wallet/RPC and exercises the actual page at mobile, tablet and desktop sizes. Mocks are not evidence of mainnet submission.

The operator must deploy the application with the specified owner, provide its confirmed address, review current IMD pricing and factory history, obtain independent review, execute the owner's launch, and publish the real token and transaction evidence. Monitor token owner changes, recipients, conversion configuration and the existing protocol's operations. Do not weaken runtime fingerprints to bypass an unexplained dependency mismatch.

### Build diagnostics reviewed

Foundry's heuristic lint reports reentry/event ordering at the factory call, timestamp use, strict balance equality, a uint64 cast and an unused position-info return value. The pre-call Launching state and callback test cover reentry; the event is intentionally emitted only after successful postconditions. Timestamp checks enforce a deadline and matching initialization time, not randomness. The uint64 cast follows the successful equality check against the token's uint64 launch time. Exact balance checks are intentional atomic creation postconditions for a newly minted token; a preexisting token cannot satisfy this factory creation path. Only the pool key is needed from the combined position-info getter because owner and liquidity are checked independently. Test timestamp lint refers to deliberate time advancement. These diagnostics were reviewed, not disabled globally.
