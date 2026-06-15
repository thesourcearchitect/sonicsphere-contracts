// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {LiquidityVault}   from "../src/LiquidityVault.sol";

/// @notice Live operational monitor for a deployed LiquidityVault.
/// @dev    Read-only health snapshot. Run before/after each settlement batch,
///         on a cron, or in CI to alert on liquidity and risk-window pressure.
///
///         Reports:
///           - Live vault balance and solvency vs risk parameters
///           - Daily rolling-window usage (mirrors the contract's lazy reset)
///           - Settlement capacity remaining (how many max-size payouts fit)
///           - Status of a supplied list of settlement references
///
///         Usage:
///           # Address from VAULT_ADDRESS env:
///           forge script script/MonitorVault.s.sol --rpc-url base_sepolia
///
///           # Explicit address:
///           forge script script/MonitorVault.s.sol \
///             --rpc-url base_sepolia \
///             --sig "runAt(address)" 0xVault...
///
///         Optional env vars:
///           VAULT_ADDRESS      address of the deployed vault (for no-arg run)
///           MIN_VAULT_BALANCE  alert floor in wei (default: 2 * dailyCap)
///           MONITOR_REFS       comma-separated bytes32 refs to classify
///           MONITOR_STRICT     "true" => revert (non-zero exit) if any [ALERT]
///                              is raised (includes the balance alert floor)
///
///         NOTE: per-ref classification here is on-chain settled vs open only.
///         The vault stores cancellations in a private mapping with no getter,
///         so historical executed/cancelled COUNTS come from event logs - see
///         `make monitor-events` (cast logs) for that aggregate view.
contract MonitorVault is Script {

    uint256 private constant DAY = 1 days;

    function run() external view {
        _monitor(vm.envAddress("VAULT_ADDRESS"));
    }

    function runAt(address vaultAddress) external view {
        _monitor(vaultAddress);
    }

    // -------------------------------------------------------------------------
    // Core
    // -------------------------------------------------------------------------

    function _monitor(address vaultAddress) internal view {
        LiquidityVault vault = LiquidityVault(payable(vaultAddress));

        console2.log("");
        console2.log("====================================================");
        console2.log("  SonicSphere - LiquidityVault Monitor");
        console2.log("  vault : %s", vaultAddress);
        console2.log("  time  : %d", block.timestamp);
        console2.log("====================================================");

        uint256 alerts = 0;

        // --- snapshot on-chain state ---
        uint256 balance     = vault.vaultBalance();
        uint256 txLimit     = vault.txLimit();
        uint256 dailyCap    = vault.dailyCap();
        uint256 storedVol   = vault.dailyVolume();
        uint256 windowEnd   = vault.dailyWindowEnd();
        bool    paused      = vault.paused();

        // The contract resets dailyVolume lazily (only on the next settlement),
        // so once the window has elapsed the effective in-window volume is 0.
        bool    windowExpired  = block.timestamp >= windowEnd;
        uint256 effectiveVol   = windowExpired ? 0 : storedVol;
        uint256 remainingDaily = dailyCap > effectiveVol ? dailyCap - effectiveVol : 0;

        alerts += _reportPauseState(paused);
        alerts += _reportLiquidity(balance, txLimit, dailyCap);
        _reportDailyWindow(effectiveVol, dailyCap, remainingDaily, windowEnd, windowExpired);
        alerts += _reportCapacity(balance, remainingDaily, txLimit);
        _reportReferences(vault);

        // --- summary ---
        console2.log("");
        console2.log("----------------------------------------------------");
        if (alerts == 0) {
            console2.log("  STATUS: HEALTHY (0 alerts)");
        } else {
            console2.log("  STATUS: ATTENTION (%d alert(s))", alerts);
            if (vm.envOr("MONITOR_STRICT", false)) {
                revert("MonitorVault: critical alert(s) raised (strict mode)");
            }
        }
        console2.log("====================================================");
        console2.log("");
    }

    // -------------------------------------------------------------------------
    // Report sections (return number of CRITICAL alerts raised)
    // -------------------------------------------------------------------------

    function _reportPauseState(bool paused) internal pure returns (uint256) {
        console2.log("");
        console2.log("[1] Operational state");
        if (paused) {
            console2.log("  [ALERT] vault is PAUSED - settlements are halted");
            return 1;
        }
        console2.log("  [OK] vault is active (not paused)");
        return 0;
    }

    function _reportLiquidity(
        uint256 balance,
        uint256 txLimit,
        uint256 dailyCap
    ) internal view returns (uint256) {
        console2.log("");
        console2.log("[2] Liquidity");
        console2.log("  vault balance : %d wei (%s ETH)", balance, _eth(balance));
        console2.log("  tx limit      : %d wei (%s ETH)", txLimit, _eth(txLimit));
        console2.log("  daily cap     : %d wei (%s ETH)", dailyCap, _eth(dailyCap));

        // Alert floor: default 2x dailyCap, overridable.
        uint256 floor = vm.envOr("MIN_VAULT_BALANCE", dailyCap * 2);
        console2.log("  alert floor   : %d wei (%s ETH)", floor, _eth(floor));

        uint256 alerts = 0;

        if (balance < txLimit) {
            console2.log("  [ALERT] balance < txLimit - cannot fund even one max settlement");
            alerts++;
        } else if (balance < dailyCap) {
            console2.log("  [WARN] balance < dailyCap - cannot sustain a full capped day");
        } else {
            console2.log("  [OK] balance covers a full day at cap");
        }

        if (balance < floor) {
            console2.log("  [ALERT] balance below configured alert floor - top up the vault");
            alerts++;
        }

        return alerts;
    }

    function _reportDailyWindow(
        uint256 effectiveVol,
        uint256 dailyCap,
        uint256 remainingDaily,
        uint256 windowEnd,
        bool    windowExpired
    ) internal view returns (uint256) {
        console2.log("");
        console2.log("[3] Daily window usage");
        console2.log("  used this window : %d wei (%s ETH)", effectiveVol, _eth(effectiveVol));
        console2.log("  remaining        : %d wei (%s ETH)", remainingDaily, _eth(remainingDaily));
        console2.log("  utilisation      : %d %%", dailyCap == 0 ? 0 : (effectiveVol * 100) / dailyCap);

        if (windowExpired) {
            console2.log("  window           : ELAPSED - resets to 0 on next settlement");
        } else {
            uint256 secsLeft = windowEnd - block.timestamp;
            console2.log("  window ends at   : %d (in %d min)", windowEnd, secsLeft / 60);
        }

        if (dailyCap > 0 && (effectiveVol * 100) / dailyCap >= 80) {
            console2.log("  [WARN] daily utilisation >= 80%% - approaching cap");
        }
        return 0;
    }

    function _reportCapacity(
        uint256 balance,
        uint256 remainingDaily,
        uint256 txLimit
    ) internal pure returns (uint256) {
        console2.log("");
        console2.log("[4] Settlement capacity (at current txLimit)");

        if (txLimit == 0) {
            console2.log("  [ALERT] txLimit is 0 - no settlements possible");
            return 1;
        }

        uint256 byCap     = remainingDaily / txLimit; // slots left in daily window
        uint256 byBalance = balance / txLimit;        // slots fundable by balance
        uint256 effective = byCap < byBalance ? byCap : byBalance;

        console2.log("  max payouts left this window (cap)     : %d", byCap);
        console2.log("  max payouts fundable now (balance)     : %d", byBalance);
        console2.log("  effective remaining payout slots       : %d", effective);

        if (effective == 0) {
            console2.log("  [WARN] no full-size payout slots available right now");
        }
        return 0;
    }

    function _reportReferences(LiquidityVault vault) internal view returns (uint256) {
        console2.log("");
        console2.log("[5] Settlement references");

        bytes32[] memory empty;
        bytes32[] memory refs = vm.envOr("MONITOR_REFS", ",", empty);

        if (refs.length == 0) {
            console2.log("  (no MONITOR_REFS supplied - skipping per-ref check)");
            console2.log("  tip: set MONITOR_REFS=0xref1,0xref2 to classify specific refs");
            console2.log("  tip: run `make monitor-events` for executed/cancelled counts");
            return 0;
        }

        uint256 settled    = 0;
        uint256 notSettled = 0;
        for (uint256 i = 0; i < refs.length; i++) {
            bool isSettled = vault.isSettled(refs[i]);
            if (isSettled) {
                settled++;
                console2.log("  [SETTLED]     %s", vm.toString(refs[i]));
            } else {
                notSettled++;
                console2.log("  [NOT SETTLED] %s", vm.toString(refs[i]));
            }
        }
        console2.log("  ---");
        console2.log("  total refs checked : %d", refs.length);
        console2.log("  settled            : %d", settled);
        console2.log("  not settled        : %d", notSettled);
        console2.log("  note: NOT SETTLED means never executed - it may still be");
        console2.log("        pending OR guardian-cancelled (cancelled refs can");
        console2.log("        never execute). Confirm via `make monitor-events`.");
        return 0;
    }

    // -------------------------------------------------------------------------
    // Formatting helpers
    // -------------------------------------------------------------------------

    /// @dev Rough "X.XX" ETH string from wei (2 decimal places).
    function _eth(uint256 amountWei) internal pure returns (string memory) {
        uint256 whole     = amountWei / 1 ether;
        uint256 remainder = (amountWei % 1 ether) / 0.01 ether;
        return string(abi.encodePacked(
            _uintToString(whole),
            ".",
            remainder < 10 ? "0" : "",
            _uintToString(remainder)
        ));
    }

    function _uintToString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 tmp = v;
        uint256 len;
        while (tmp != 0) { len++; tmp /= 10; }
        bytes memory buf = new bytes(len);
        for (uint256 i = len; i > 0; i--) {
            buf[i - 1] = bytes1(uint8(48 + v % 10));
            v /= 10;
        }
        return string(buf);
    }
}
