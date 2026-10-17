// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20TLaunch} from "../src/ERC20TLaunch.sol";
import {IERC20T, IERC20THook, IPositionManager, PoolKey} from "../src/interfaces/IERC20T.sol";
import {MainnetState} from "./fixtures/MainnetState.sol";
import {LaunchInvariantHandler} from "./helpers/LaunchInvariantHandler.sol";
import {ITestToken} from "./helpers/SwapHarness.sol";

/// @notice Random call sequences against the launch adapter and the real captured infrastructure.
///         The adapter itself must never hold value; the token, pool and locked position must keep
///         their accounting under any order of launches, trades, transfers, burns, time and owner edits.
/// forge-config: default.invariant.runs = 48
/// forge-config: default.invariant.depth = 32
/// forge-config: default.invariant.fail-on-revert = false
contract ERC20TLaunchInvariantTest is MainnetState {
    address internal constant OWNER = 0x3d6a89C8751a45DD577a4C1F3b34E71C58236193;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    ERC20TLaunch internal app;
    LaunchInvariantHandler internal handler;
    address internal protocolRecipient;
    uint256 internal imdBaseline;

    function setUp() public {
        loadMainnetState();
        app = new ERC20TLaunch(OWNER);
        handler = new LaunchInvariantHandler(app, 3);
        protocolRecipient = IERC20THook(app.HOOK()).protocolFeeRecipient();
        imdBaseline = _imdHeldByTracked();
        targetContract(address(handler));
    }

    // ---------------------------------------------------------------- adapter state machine

    function invariant_statusNeverRestsInLaunching() public view {
        assertTrue(app.status() != ERC20TLaunch.Status.Launching);
        assertFalse(handler.sawLaunchingStatus());
    }

    function invariant_launchHappensAtMostOnceAndOnlyForTheOwnerWithValidInputs() public view {
        assertLe(handler.launchSuccesses(), 1);
        assertEq(handler.unauthorizedSuccesses(), 0);
        assertEq(handler.invalidInputSuccesses(), 0);
        // The captured factory state already has an occupant in its first clone slot.
        assertEq(handler.requireFirstSuccesses(), 0);
        bool launched = app.status() == ERC20TLaunch.Status.Launched;
        assertEq(launched, handler.launched());
        assertEq(app.token(), handler.ghostToken());
        if (launched) {
            assertEq(app.positionId(), handler.ghostPositionId());
            assertEq(app.launchedAt(), handler.ghostLaunchedAt());
            assertFalse(app.wasFirst());
            assertEq(IERC20T(app.token()).launchedAt(), app.launchedAt());
        } else {
            assertEq(app.positionId(), 0);
            assertEq(app.poolId(), bytes32(0));
            assertEq(app.launchBlock(), 0);
        }
    }

    function invariant_adapterNeverHoldsValue() public view {
        assertEq(address(app).balance, 0);
        assertEq(ITestToken(app.IMD()).balanceOf(address(app)), 0);
        if (handler.launched()) assertEq(ITestToken(app.token()).balanceOf(address(app)), 0);
    }

    // ---------------------------------------------------------------- token accounting

    function invariant_supplyIsFixedMinusVoluntaryBurns() public view {
        if (!handler.launched()) return;
        IERC20T t = IERC20T(app.token());
        assertEq(t.totalSupply(), app.TOTAL_SUPPLY() - handler.burned());
        assertEq(_tokenHeldByTracked(address(t)), t.totalSupply(), "tokens leaked to an untracked holder");
    }

    function invariant_ownerAllocationIsExactlyFivePercent() public view {
        if (!handler.launched()) return;
        // Only the owner's own gifts move the creator allocation; swaps and fees never touch it.
        assertEq(ITestToken(app.token()).balanceOf(OWNER), app.CREATOR_SUPPLY() - handler.ownerGifted());
        assertEq(handler.ownerGiftFailures(), 0, "owner transfer rejected");
    }

    function invariant_walletTransfersAreUntaxedAndConserveTheGiftedAmount() public view {
        if (!handler.launched()) return;
        address t = app.token();
        uint256 held;
        for (uint256 i; i < handler.walletCount(); i++) {
            held += ITestToken(t).balanceOf(handler.walletAt(i));
        }
        assertEq(held, handler.ownerGifted(), "wallet-to-wallet transfer created, taxed or lost tokens");
    }

    /// @dev The token implementation's transfer policy, as disclosed in docs/SECURITY_REVIEW.md: a
    ///      wallet's own direct transfer to a wallet always passes; a relayed wallet call, a wallet
    ///      sending to code, and code sending to a non-owner are rejected, during and after decay.
    function invariant_transferPolicyMatchesTheDisclosure() public view {
        assertEq(handler.walletTransferFailures(), 0, "direct wallet transfer rejected");
        assertEq(handler.relayedSuccesses(), 0, "relayed wallet transfer accepted");
        assertEq(handler.walletToCodeSuccesses(), 0, "wallet sent to non-distributor code");
        assertEq(handler.contractTransferSuccesses(), 0, "contract holder sent to non-owner");
    }

    function invariant_tradersNeverHoldMoreThanThePoolReleased() public view {
        if (!handler.launched()) return;
        address t = app.token();
        uint256 held;
        for (uint256 i; i < handler.actorCount(); i++) {
            held += ITestToken(t).balanceOf(handler.actorAt(i));
        }
        uint256 inPool = ITestToken(t).balanceOf(app.POOL_MANAGER()) + ITestToken(t).balanceOf(t);
        assertLe(held + handler.burned() + inPool, app.LIQUIDITY_SUPPLY());
        assertEq(held + handler.burned() + inPool, app.LIQUIDITY_SUPPLY());
    }

    function invariant_quoteTokenIsConserved() public view {
        assertEq(_imdHeldByTracked(), imdBaseline + handler.imdDealt(), "IMD leaked to an untracked holder");
    }

    // ---------------------------------------------------------------- locked liquidity

    function invariant_initialPositionStaysLockedWithItsLiquidity() public view {
        if (!handler.launched()) return;
        IPositionManager pm = IPositionManager(app.POSITION_MANAGER());
        uint256 id = app.positionId();
        assertEq(pm.ownerOf(id), DEAD);
        assertGt(pm.getPositionLiquidity(id), 0);
        assertEq(pm.getPositionLiquidity(id), handler.liquidityAtLaunch());
        assertGt(pm.nextTokenId(), id);
        (PoolKey memory key,) = pm.getPoolAndPositionInfo(id);
        assertEq(keccak256(abi.encode(key)), app.poolId());
        assertEq(keccak256(abi.encode(IERC20T(app.token()).poolKey())), app.poolId());
        assertEq(key.hooks, app.HOOK());
    }

    // ---------------------------------------------------------------- tax schedule

    function invariant_taxFollowsTheDecayScheduleThenTheOwnerSetting() public view {
        if (!handler.launched()) return;
        IERC20T t = IERC20T(app.token());
        uint256 steps = (block.timestamp - app.launchedAt()) / 60;
        uint16 tax = t.taxBps();
        assertLe(tax, 9900);
        assertGe(tax, 30);
        if (steps < 98) {
            assertEq(tax, 9900 - steps * 100);
            assertEq(t.restingTaxBps(), 100);
            assertEq(handler.taxEdits(), 0);
        } else {
            assertEq(tax, t.restingTaxBps());
            if (handler.taxEdits() == 0) assertEq(tax, 100);
        }
        assertEq(t.launchTaxBps(), 9900);
        assertEq(t.owner(), OWNER);
        assertEq(t.feeRecipient(), OWNER);
        assertEq(t.feeDecayRecipient(), OWNER);
    }

    // ---------------------------------------------------------------- handler liveness

    /// @dev The handler swallows reverts, so prove its paths are live: one scripted sequence must
    ///      launch, buy, transfer, burn, sell and edit the tax, or the invariants above are vacuous.
    function test_handlerSequenceExercisesEveryPath() public {
        handler.launch(1, 540_540_540_540, 100, true);
        assertFalse(handler.launched(), "requireFirst must fail on the occupied factory");
        handler.launch(1, 540_540_540_540, 100, false);
        assertFalse(handler.launched(), "a non-owner must not launch");
        handler.launch(0, 540_540_540_540, 100, false);
        assertTrue(handler.launched());
        assertEq(handler.launchSuccesses(), 1);
        handler.launch(0, 540_540_540_540, 100, false);
        assertEq(handler.launchSuccesses(), 1);

        handler.buy(0, 3 ether);
        handler.buy(1, 2 ether);
        assertEq(handler.buys(), 2);
        handler.transferTokens(0, 2, 1e18);
        assertEq(handler.transferRejections(), 1);
        handler.ownerGift(0, 1_000 ether);
        assertEq(handler.ownerGifted(), 1_000 ether);
        handler.walletTransfer(0, 1, 400 ether, 0);
        assertEq(handler.walletTransfers(), 1);
        assertEq(ITestToken(app.token()).balanceOf(handler.walletAt(1)), 400 ether);
        handler.walletTransfer(0, 1, 1 ether, 1);
        assertEq(handler.relayedRejections(), 1);
        handler.walletTransfer(1, 0, 1 ether, 2);
        assertEq(handler.walletToCodeRejections(), 1);
        handler.burn(1, 1e18);
        assertEq(handler.burned(), 1e18);
        handler.sell(0, 1e18);
        assertEq(handler.sells(), 1);

        handler.ownerSetTax(50);
        assertEq(handler.taxEdits(), 0, "tax edit must fail during decay");
        handler.warp(98 minutes);
        handler.ownerSetTax(50);
        assertEq(handler.taxEdits(), 1);
        assertEq(IERC20T(app.token()).taxBps(), 50);
        // After the decay the same policy holds.
        handler.walletTransfer(1, 2, 100 ether, 0);
        assertEq(handler.walletTransfers(), 2);
        handler.walletTransfer(1, 2, 1 ether, 1);
        assertEq(handler.relayedRejections(), 2);

        invariant_statusNeverRestsInLaunching();
        invariant_launchHappensAtMostOnceAndOnlyForTheOwnerWithValidInputs();
        invariant_adapterNeverHoldsValue();
        invariant_supplyIsFixedMinusVoluntaryBurns();
        invariant_ownerAllocationIsExactlyFivePercent();
        invariant_walletTransfersAreUntaxedAndConserveTheGiftedAmount();
        invariant_transferPolicyMatchesTheDisclosure();
        invariant_tradersNeverHoldMoreThanThePoolReleased();
        invariant_quoteTokenIsConserved();
        invariant_initialPositionStaysLockedWithItsLiquidity();
        invariant_taxFollowsTheDecayScheduleThenTheOwnerSetting();
    }

    // ---------------------------------------------------------------- helpers

    function _trackedHolders() internal view returns (address[] memory holders) {
        uint256 n = handler.actorCount();
        uint256 w = handler.walletCount();
        holders = new address[](n + w + 10);
        for (uint256 i; i < n; i++) {
            holders[i] = handler.actorAt(i);
        }
        for (uint256 i; i < w; i++) {
            holders[n + 10 + i] = handler.walletAt(i);
        }
        holders[n] = OWNER;
        holders[n + 1] = app.POOL_MANAGER();
        holders[n + 2] = app.HOOK();
        holders[n + 3] = address(app);
        holders[n + 4] = app.FACTORY();
        holders[n + 5] = DEAD;
        holders[n + 6] = protocolRecipient;
        holders[n + 7] = app.IMD_ETH_HOOK();
        holders[n + 8] = address(handler);
        holders[n + 9] = handler.launched() ? app.token() : app.IMD();
    }

    function _tokenHeldByTracked(address token) internal view returns (uint256 sum) {
        address[] memory holders = _trackedHolders();
        for (uint256 i; i < holders.length; i++) {
            sum += ITestToken(token).balanceOf(holders[i]);
        }
    }

    function _imdHeldByTracked() internal view returns (uint256 sum) {
        address[] memory holders = _trackedHolders();
        address imd = app.IMD();
        for (uint256 i; i < holders.length; i++) {
            if (holders[i] == imd) continue;
            sum += ITestToken(imd).balanceOf(holders[i]);
        }
        sum += ITestToken(imd).balanceOf(imd);
    }
}
