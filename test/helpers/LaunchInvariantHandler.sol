// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20TLaunch} from "../../src/ERC20TLaunch.sol";
import {IERC20T, IPositionManager, PoolKey} from "../../src/interfaces/IERC20T.sol";
import {SwapHarness, ITestToken} from "./SwapHarness.sol";

interface IBurnableTaxToken {
    function burn(uint256 amount) external;
    function setTaxBps(uint16 bps) external;
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @dev Invariant handler: drives the one-use launch adapter and, once a token exists, the real
///      captured factory/hook/Uniswap runtimes with bounded trades, transfers, burns, time and
///      owner tax edits from several actors. Ghost variables record what must be true afterwards.
contract LaunchInvariantHandler is Test {
    ERC20TLaunch public immutable app;
    address public immutable owner;
    address public immutable imd;
    address public immutable poolManager;
    SwapHarness[] public actors;
    // Code-free holders. They receive tokens only from the owner, which the transfer policy allows.
    address[] public wallets;

    // Ghost state
    uint256 public launchCalls;
    uint256 public launchSuccesses;
    uint256 public unauthorizedSuccesses;
    uint256 public invalidInputSuccesses;
    uint256 public requireFirstSuccesses;
    address public ghostToken;
    uint256 public ghostPositionId;
    uint128 public liquidityAtLaunch;
    uint64 public ghostLaunchedAt;
    uint256 public burned;
    uint256 public imdDealt;
    uint256 public buys;
    uint256 public sells;
    uint256 public transfers;
    uint256 public transferRejections;
    uint256 public taxEdits;
    uint256 public ownerGifted;
    uint256 public ownerGiftFailures;
    uint256 public walletTransfers;
    uint256 public walletTransferFailures;
    uint256 public relayedRejections;
    uint256 public relayedSuccesses;
    uint256 public walletToCodeRejections;
    uint256 public walletToCodeSuccesses;
    uint256 public contractTransferSuccesses;
    bool public sawLaunchingStatus;

    constructor(ERC20TLaunch app_, uint256 actors_) {
        app = app_;
        owner = app_.owner();
        imd = app_.IMD();
        poolManager = app_.POOL_MANAGER();
        for (uint256 i; i < actors_; i++) {
            actors.push(new SwapHarness(poolManager));
            wallets.push(makeAddr(string(abi.encodePacked("wallet", vm.toString(i)))));
        }
    }

    function walletCount() external view returns (uint256) {
        return wallets.length;
    }

    function walletAt(uint256 i) external view returns (address) {
        return wallets[i];
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return address(actors[i]);
    }

    function launched() public view returns (bool) {
        return ghostToken != address(0);
    }

    // ---------------------------------------------------------------- launch attempts

    function launch(uint256 callerSeed, uint256 priceSeed, uint256 delaySeed, bool requireFirst) external {
        launchCalls++;
        bool asOwner = callerSeed % 3 == 0;
        address caller = asOwner ? owner : _actor(callerSeed / 3);
        uint256 price = bound(priceSeed, 0, 2e18);
        // Mostly valid deadlines, sometimes expired, sometimes too distant.
        uint256 delay = bound(delaySeed, 0, 2400);
        uint256 deadline = delay % 7 == 6 ? block.timestamp - 1 : block.timestamp + delay;
        bool validInputs = price != 0 && price <= app.MAX_PRICE_X18() && deadline >= block.timestamp
            && deadline - block.timestamp <= app.MAX_DEADLINE_DELAY();
        bool wasReady = app.status() == ERC20TLaunch.Status.Ready;
        uint256 nextId = IPositionManager(app.POSITION_MANAGER()).nextTokenId();

        vm.prank(caller);
        try app.launch(price, deadline, requireFirst) returns (address created) {
            launchSuccesses++;
            if (!asOwner) unauthorizedSuccesses++;
            if (!validInputs || !wasReady) invalidInputSuccesses++;
            if (requireFirst) requireFirstSuccesses++;
            ghostToken = created;
            ghostPositionId = nextId;
            liquidityAtLaunch = IPositionManager(app.POSITION_MANAGER()).getPositionLiquidity(nextId);
            ghostLaunchedAt = uint64(block.timestamp);
        } catch {
            // Every failure must leave the adapter exactly where it was.
            assertEq(uint256(app.status()), wasReady ? 0 : 2, "failed launch changed status");
        }
        if (app.status() == ERC20TLaunch.Status.Launching) sawLaunchingStatus = true;
    }

    // ---------------------------------------------------------------- trading

    function buy(uint256 actorSeed, uint256 amountSeed) external {
        if (!launched()) return;
        SwapHarness router = actors[actorSeed % actors.length];
        uint256 amount = bound(amountSeed, 1, 5 ether);
        deal(imd, address(router), ITestToken(imd).balanceOf(address(router)) + amount);
        imdDealt += amount;
        PoolKey memory key = IERC20T(ghostToken).poolKey();
        try router.trade(key, imd < ghostToken, amount, 1) {
            buys++;
        } catch {}
    }

    function sell(uint256 actorSeed, uint256 fractionSeed) external {
        if (!launched()) return;
        SwapHarness router = actors[actorSeed % actors.length];
        uint256 held = ITestToken(ghostToken).balanceOf(address(router));
        if (held == 0) return;
        uint256 amount = bound(fractionSeed, 1, held);
        PoolKey memory key = IERC20T(ghostToken).poolKey();
        try router.trade(key, ghostToken < imd, amount, 1) {
            sells++;
        } catch {}
    }

    function transferTokens(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        if (!launched()) return;
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = ITestToken(ghostToken).balanceOf(from);
        if (held == 0) return;
        uint256 amount = bound(amountSeed, 0, held);
        vm.prank(from);
        try IBurnableTaxToken(ghostToken).transfer(to, amount) {
            transfers++;
            // The implementation's documented policy rejects a holder with code sending to anyone but
            // the owner, the pool or a distributor; actors are none of those to each other.
            contractTransferSuccesses++;
        } catch {
            transferRejections++;
        }
    }

    /// @dev Owner hands part of the creator allocation to a wallet. Owner-side transfers always pass.
    function ownerGift(uint256 walletSeed, uint256 amountSeed) external {
        if (!launched()) return;
        uint256 held = ITestToken(ghostToken).balanceOf(owner);
        if (held == 0) return;
        uint256 amount = bound(amountSeed, 1, held < 1_000_000 ether ? held : 1_000_000 ether);
        vm.prank(owner);
        try IBurnableTaxToken(ghostToken).transfer(_wallet(walletSeed), amount) {
            ownerGifted += amount;
        } catch {
            ownerGiftFailures++;
        }
    }

    /// @dev A wallet moves its own balance. Directly (msg.sender == from == tx.origin) to another
    ///      wallet it must pass untaxed; relayed (tx.origin differs) or to code it must be rejected.
    function walletTransfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed, uint8 mode) external {
        if (!launched()) return;
        address from = _wallet(fromSeed);
        uint256 held = ITestToken(ghostToken).balanceOf(from);
        if (held == 0) return;
        uint256 amount = bound(amountSeed, 1, held);
        mode = mode % 3;
        if (mode == 0) {
            vm.prank(from, from);
            try IBurnableTaxToken(ghostToken).transfer(_wallet(toSeed), amount) {
                walletTransfers++;
            } catch {
                walletTransferFailures++;
            }
        } else if (mode == 1) {
            vm.prank(from);
            try IBurnableTaxToken(ghostToken).transfer(_wallet(toSeed), amount) {
                relayedSuccesses++;
            } catch {
                relayedRejections++;
            }
        } else {
            vm.prank(from, from);
            try IBurnableTaxToken(ghostToken).transfer(_actor(toSeed), amount) {
                walletToCodeSuccesses++;
            } catch {
                walletToCodeRejections++;
            }
        }
    }

    function burn(uint256 actorSeed, uint256 amountSeed) external {
        if (!launched()) return;
        address from = _actor(actorSeed);
        uint256 held = ITestToken(ghostToken).balanceOf(from);
        if (held == 0) return;
        uint256 amount = bound(amountSeed, 1, held);
        vm.prank(from);
        try IBurnableTaxToken(ghostToken).burn(amount) {
            burned += amount;
        } catch {}
    }

    // ---------------------------------------------------------------- time and owner powers

    function warp(uint256 seed) external {
        vm.warp(block.timestamp + bound(seed, 0, 2 hours));
    }

    function ownerSetTax(uint256 seed) external {
        if (!launched()) return;
        uint16 bps = uint16(bound(seed, 0, 700));
        bool decaying = (block.timestamp - ghostLaunchedAt) / 60 < 98;
        vm.prank(owner);
        try IBurnableTaxToken(ghostToken).setTaxBps(bps) {
            taxEdits++;
            assertFalse(decaying, "tax edited during decay");
            assertTrue(bps >= 30 && bps <= 500, "tax edit outside documented range");
        } catch {}
    }

    function _actor(uint256 seed) internal view returns (address) {
        return address(actors[seed % actors.length]);
    }

    function _wallet(uint256 seed) internal view returns (address) {
        return wallets[seed % wallets.length];
    }
}
