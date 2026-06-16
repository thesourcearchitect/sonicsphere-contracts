// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {LiquidityVault}   from "../src/LiquidityVault.sol";

/// @notice Operational script for updating risk parameters on a deployed vault.
/// @dev    The broadcaster must hold GUARDIAN_ROLE on the target vault.
///
///         Usage:
///           forge script script/SetRiskParams.s.sol \
///             --rpc-url <rpc>                        \
///             --broadcast                            \
///             --sig "runAt(address,uint256,uint256)"   \
///             <VAULT_ADDRESS> <TX_LIMIT_WEI> <DAILY_CAP_WEI>
///
///         Or use the env-var variant:
///           VAULT_ADDRESS=0x... TX_LIMIT=1000000000000000000 DAILY_CAP=5000000000000000000 \
///             forge script script/SetRiskParams.s.sol --rpc-url <rpc> --broadcast
///
/// @dev    Constraints (enforced by LiquidityVault):
///           txLimit > 0
///           dailyCap >= txLimit
contract SetRiskParams is Script {

    // Entry point A: pass values via env vars
    function run() external {
        address vault    = vm.envAddress("VAULT_ADDRESS");
        uint256 txLimit  = vm.envUint("TX_LIMIT");
        uint256 dailyCap = vm.envUint("DAILY_CAP");
        _execute(vault, txLimit, dailyCap);
    }

    // Entry point B: pass values as script args
    function runAt(address vault, uint256 txLimit, uint256 dailyCap) external {
        _execute(vault, txLimit, dailyCap);
    }

    // -------------------------------------------------------------------------

    function _execute(address vaultAddr, uint256 txLimit, uint256 dailyCap) internal {
        LiquidityVault vault = LiquidityVault(payable(vaultAddr));

        // Pre-flight validation
        require(txLimit  > 0,           "SetRiskParams: txLimit must be > 0");
        require(dailyCap >= txLimit,    "SetRiskParams: dailyCap must be >= txLimit");

        console2.log("================================================");
        console2.log("  SetRiskParams");
        console2.log("  vault    :", vaultAddr);
        console2.log("  txLimit  :", txLimit, "wei");
        console2.log("  dailyCap :", dailyCap, "wei");
        console2.log("================================================");

        // Read current values for comparison
        uint256 oldTxLimit  = vault.txLimit();
        uint256 oldDailyCap = vault.dailyCap();
        bool    paused      = vault.paused();

        console2.log("\n  Current state:");
        console2.log("    txLimit  : %d wei", oldTxLimit);
        console2.log("    dailyCap : %d wei", oldDailyCap);
        console2.log("    paused   : %s", paused ? "true" : "false");

        if (paused) {
            console2.log("\n  WARNING: vault is paused - params will update but settlements remain blocked");
        }

        vm.startBroadcast();

        if (txLimit != oldTxLimit) {
            vault.setTxLimit(txLimit);
            console2.log("\n  [OK] setTxLimit(%d)", txLimit);
        } else {
            console2.log("\n  [--] txLimit unchanged (%d)", txLimit);
        }

        if (dailyCap != oldDailyCap) {
            vault.setDailyCap(dailyCap);
            console2.log("  [OK] setDailyCap(%d)", dailyCap);
        } else {
            console2.log("  [--] dailyCap unchanged (%d)", dailyCap);
        }

        vm.stopBroadcast();

        console2.log("\n================================================");
        console2.log("  Done.");
        console2.log("================================================");
    }
}
