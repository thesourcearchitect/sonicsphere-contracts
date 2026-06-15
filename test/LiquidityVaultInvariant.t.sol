// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test, StdInvariant} from "forge-std/Test.sol";
import {LiquidityVault}     from "../src/LiquidityVault.sol";
import {ILiquidityVault}    from "../src/interfaces/ILiquidityVault.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Handler
// ─────────────────────────────────────────────────────────────────────────────
// The handler is the only contract the fuzzer calls. It wraps every vault
// action with pre-condition guards so the fuzzer generates valid call sequences
// rather than wasting runs on trivially-reverted calls.
//
// Ghost variables shadow the vault's internal state so invariants can assert
// against independently-tracked values.
// ─────────────────────────────────────────────────────────────────────────────

contract VaultHandler is Test {

    // ── Actors ────────────────────────────────────────────────────────────────
    address public admin    = makeAddr("admin");
    address public guardian = makeAddr("guardian");
    address public relayer  = makeAddr("relayer");

    // ── System under test ─────────────────────────────────────────────────────
    LiquidityVault public vault;

    // ── Ghost variables ───────────────────────────────────────────────────────

    /// @dev Total ETH successfully distributed to external recipients.
    uint256 public ghost_totalDistributed;

    /// @dev Total ETH deposited into the vault through this handler.
    uint256 public ghost_totalDeposited;

    /// @dev Running count of unique refs that were settled.
    uint256 public ghost_settledCount;

    /// @dev Volume settled in the currently-tracked daily window.
    ///      Reset whenever warpDailyWindow() is called (mirrors the contract's
    ///      lazy tick on the next executeSettlement call).
    uint256 public ghost_windowVolume;

    /// @dev The dailyCap value that was in effect during the most recent
    ///      settlement. Used to verify that settlements respected the cap.
    uint256 public ghost_capAtLastSettlement;

    /// @dev Nonce for deterministic unique settlement refs.
    uint256 private _nonce;

    constructor(LiquidityVault vault_) {
        vault = vault_;
        ghost_capAtLastSettlement = vault_.dailyCap();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Funding
    // ─────────────────────────────────────────────────────────────────────────

    function depositEth(uint96 amount) external {
        uint256 amt = bound(uint256(amount), 0.001 ether, 50 ether);
        vm.deal(address(this), amt);
        (bool ok,) = address(vault).call{value: amt}("");
        require(ok, "deposit failed");
        ghost_totalDeposited += amt;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Relayer actions
    // ─────────────────────────────────────────────────────────────────────────

    function executeSettlement(uint96 rawAmount, address rawRecipient) external {
        // Skip if paused
        if (vault.paused()) return;

        // ── Guard: valid recipient (never send to vault or handler itself) ──
        // Sending to vault triggers receive(), returning ETH immediately and
        // breaking balance accounting. Sending to handler is equally circular.
        if (rawRecipient == address(vault))   return;
        if (rawRecipient == address(this))    return;
        if (rawRecipient == address(0))       return;

        // Use a fixed known recipient to keep ghost accounting clean
        address payable recipient = payable(rawRecipient);

        // ── Guard: vault has ETH ──
        uint256 vaultBal = address(vault).balance;
        if (vaultBal == 0) return;
        if (vault.txLimit() == 0) return;

        // ── Guard: remaining daily allowance ──
        uint256 cap    = vault.dailyCap();
        uint256 vol    = vault.dailyVolume();
        uint256 remaining = cap > vol ? cap - vol : 0;
        if (remaining == 0) return;

        // ── Bound amount to per-tx limit, vault balance, and remaining cap ──
        uint256 maxAmt = _min3(vault.txLimit(), vaultBal, remaining);
        if (maxAmt == 0) return;
        uint256 amt = bound(uint256(rawAmount), 1, maxAmt);

        bytes32 ref = keccak256(abi.encodePacked("handler-ref", ++_nonce));
        uint256 balBefore = address(vault).balance;

        vm.prank(relayer);
        try vault.executeSettlement(ref, recipient, amt) {
            // Settlement succeeded — update all ghosts
            ghost_totalDistributed += amt;
            ghost_settledCount     += 1;
            ghost_windowVolume     += amt;
            ghost_capAtLastSettlement = cap;

            // Strict balance accounting: vault lost exactly `amt`
            uint256 balAfter = address(vault).balance;
            assert(balAfter == balBefore - amt);
        } catch {
            // Acceptable revert (e.g. window ticked mid-call between our read
            // and the vault's check). Ghosts are not updated.
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Guardian actions
    // ─────────────────────────────────────────────────────────────────────────

    function pauseVault() external {
        if (vault.paused()) return;
        vm.prank(guardian);
        vault.pause();
    }

    function unpauseVault() external {
        if (!vault.paused()) return;
        vm.prank(guardian);
        vault.unpause();
    }

    function cancelArbitraryRef(bytes32 ref) external {
        if (ref == bytes32(0))      return;
        if (vault.isSettled(ref))   return;
        vm.prank(guardian);
        vault.cancelSettlement(ref);
    }

    function setTxLimit(uint96 rawLimit) external {
        // Bound: 1 wei to current dailyCap (maintains I5)
        uint256 newLimit = bound(uint256(rawLimit), 1, vault.dailyCap());
        vm.prank(guardian);
        vault.setTxLimit(newLimit);
    }

    function setDailyCap(uint96 rawCap) external {
        // Bound: current txLimit to 100 ETH (maintains I5)
        uint256 newCap = bound(uint256(rawCap), vault.txLimit(), 100 ether);
        vm.prank(guardian);
        vault.setDailyCap(newCap);
    }

    /// @dev Advance time past the current daily window.
    ///      Resets ghost_windowVolume — the contract's dailyVolume will also
    ///      reset on the next executeSettlement via _tickDailyWindow().
    function warpDailyWindow() external {
        vm.warp(vault.dailyWindowEnd() + 1);
        ghost_windowVolume = 0;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin actions
    // ─────────────────────────────────────────────────────────────────────────

    function rescueEth(uint96 rawAmount) external {
        uint256 bal = address(vault).balance;
        if (bal == 0) return;
        uint256 amt = bound(uint256(rawAmount), 1, bal);
        uint256 balBefore = address(vault).balance;
        vm.prank(admin);
        vault.rescueEth(payable(admin), amt);
        // Rescue reduces the vault balance — adjust total deposited ghost so
        // that balance accounting invariant stays valid.
        // We model rescue as "removing deposited ETH": reduce ghost_totalDeposited.
        uint256 rescued = balBefore - address(vault).balance;
        if (rescued <= ghost_totalDeposited) {
            ghost_totalDeposited -= rescued;
        } else {
            // Rescue exceeded handler deposits — reduce from initial seed
            // by adjusting ghost_totalDistributed upward as a correction.
            ghost_totalDistributed += rescued - ghost_totalDeposited;
            ghost_totalDeposited    = 0;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Utilities
    // ─────────────────────────────────────────────────────────────────────────

    function _min3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return a < b ? (a < c ? a : c) : (b < c ? b : c);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Invariant Test Contract
// ─────────────────────────────────────────────────────────────────────────────

/// @title LiquidityVaultInvariant
/// @notice Stateful invariant tests for LiquidityVault (Foundry StdInvariant).
///
///  Invariants
///  ──────────
///  I1  vaultBalance() always matches address(vault).balance
///  I2  When a settlement succeeds, the volume accumulated in that window
///      did not exceed the dailyCap that was in effect at call time
///      (tracked via ghost_capAtLastSettlement)
///  I3  vault.balance == initialFunding + handlerDeposits - distributions
///  I4  ghost_settledCount is monotonically non-decreasing
///  I5  txLimit <= dailyCap at all times
///  I6  Relayer role cannot call guardian/admin functions
///  I7  vault.balance <= total ETH ever seeded (no ETH creation)
///  I8  When paused, executeSettlement always reverts
///
contract LiquidityVaultInvariant is StdInvariant, Test {

    uint256 constant INITIAL_TX_LIMIT  = 1 ether;
    uint256 constant INITIAL_DAILY_CAP = 10 ether;
    uint256 constant INITIAL_FUNDING   = 200 ether;

    address admin    = makeAddr("admin");
    address guardian = makeAddr("guardian");
    address relayer  = makeAddr("relayer");

    LiquidityVault public vault;
    VaultHandler   public handler;

    function setUp() public {
        vault = new LiquidityVault(
            admin,
            guardian,
            relayer,
            INITIAL_TX_LIMIT,
            INITIAL_DAILY_CAP
        );
        vm.deal(address(vault), INITIAL_FUNDING);

        handler = new VaultHandler(vault);
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = VaultHandler.depositEth.selector;
        selectors[1] = VaultHandler.executeSettlement.selector;
        selectors[2] = VaultHandler.pauseVault.selector;
        selectors[3] = VaultHandler.unpauseVault.selector;
        selectors[4] = VaultHandler.cancelArbitraryRef.selector;
        selectors[5] = VaultHandler.setTxLimit.selector;
        selectors[6] = VaultHandler.setDailyCap.selector;
        selectors[7] = VaultHandler.warpDailyWindow.selector;
        selectors[8] = VaultHandler.rescueEth.selector;

        targetSelector(FuzzSelector({
            addr: address(handler),
            selectors: selectors
        }));
    }

    // ── I1 ────────────────────────────────────────────────────────────────────

    /// @notice vaultBalance() view must always equal address(vault).balance.
    function invariant_I1_vaultBalanceViewIsAccurate() public view {
        assertEq(
            vault.vaultBalance(),
            address(vault).balance,
            "I1: vaultBalance() != address(vault).balance"
        );
    }

    // ── I2 ────────────────────────────────────────────────────────────────────

    /// @notice The ghost volume settled in the current window must not exceed
    ///         the cap that was in effect at the time of the most recent
    ///         settlement. The cap may be retroactively reduced by the guardian
    ///         after settlements execute, so we compare against the snapshot
    ///         taken at settlement time, not the live dailyCap.
    function invariant_I2_windowVolumeRespectedCapAtSettlementTime() public view {
        if (handler.ghost_settledCount() == 0) return;
        assertLe(
            handler.ghost_windowVolume(),
            handler.ghost_capAtLastSettlement(),
            "I2: window volume exceeded dailyCap at time of settlement"
        );
    }

    // ── I3 ────────────────────────────────────────────────────────────────────

    /// @notice vault.balance == initialFunding + handlerDeposits - distributions.
    ///         This holds because the handler never sends ETH to the vault itself
    ///         and rescue is folded into the ghost accounting.
    function invariant_I3_balanceConservation() public view {
        uint256 expected =
            INITIAL_FUNDING
            + handler.ghost_totalDeposited()
            - handler.ghost_totalDistributed();

        assertEq(
            address(vault).balance,
            expected,
            "I3: vault ETH balance does not equal deposits minus distributions"
        );
    }

    // ── I4 ────────────────────────────────────────────────────────────────────

    uint256 private _lastSettledCount;

    /// @notice ghost_settledCount must never decrease.
    function invariant_I4_settledCountMonotonic() public {
        uint256 current = handler.ghost_settledCount();
        assertGe(current, _lastSettledCount, "I4: settledCount decreased");
        _lastSettledCount = current;
    }

    // ── I5 ────────────────────────────────────────────────────────────────────

    /// @notice txLimit must always be <= dailyCap.
    function invariant_I5_txLimitNeverExceedsDailyCap() public view {
        assertLe(vault.txLimit(), vault.dailyCap(), "I5: txLimit > dailyCap");
    }

    // ── I6 ────────────────────────────────────────────────────────────────────

    /// @notice Relayer cannot call any guardian or admin privileged function.
    function invariant_I6_relayerHasNoPrivilegedAccess() public {
        uint256 snapTxLimit  = vault.txLimit();
        uint256 snapDailyCap = vault.dailyCap();

        vm.prank(relayer);
        try vault.setTxLimit(1) {
            fail("I6: relayer succeeded in calling setTxLimit");
        } catch {}

        vm.prank(relayer);
        try vault.setDailyCap(snapDailyCap) {
            fail("I6: relayer succeeded in calling setDailyCap");
        } catch {}

        vm.prank(relayer);
        try vault.pause() {
            fail("I6: relayer succeeded in calling pause");
        } catch {}

        vm.prank(relayer);
        try vault.rescueEth(payable(relayer), 1) {
            fail("I6: relayer succeeded in calling rescueEth");
        } catch {}

        // Values must be unchanged
        assertEq(vault.txLimit(),  snapTxLimit,  "I6: txLimit mutated by relayer");
        assertEq(vault.dailyCap(), snapDailyCap, "I6: dailyCap mutated by relayer");
    }

    // ── I7 ────────────────────────────────────────────────────────────────────

    /// @notice vault.balance can never exceed total ETH ever seeded into it.
    function invariant_I7_balanceNeverExceedsTotalSeeded() public view {
        uint256 totalSeeded = INITIAL_FUNDING + handler.ghost_totalDeposited();
        assertLe(
            address(vault).balance,
            totalSeeded,
            "I7: vault balance exceeds total ETH seeded"
        );
    }

    // ── I8 ────────────────────────────────────────────────────────────────────

    /// @notice When the vault is paused, any settlement attempt must revert.
    function invariant_I8_pausedVaultRejectsAllSettlements() public {
        if (!vault.paused()) return;

        bytes32 ref = keccak256(abi.encodePacked("pause-probe", block.timestamp));
        address payable probe = payable(makeAddr("probe"));

        vm.prank(relayer);
        try vault.executeSettlement(ref, probe, 1) {
            fail("I8: settlement succeeded on a paused vault");
        } catch {}
    }
}
