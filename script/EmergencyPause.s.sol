// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {LiquidityVault}   from "../src/LiquidityVault.sol";

/// @notice Emergency script to pause or unpause a deployed LiquidityVault.
/// @dev    The broadcaster must hold GUARDIAN_ROLE.
///
///         Pause:
///           forge script script/EmergencyPause.s.sol \
///             --rpc-url <rpc> --broadcast             \
///             --sig "pause(address)" <VAULT_ADDRESS>
///
///         Unpause:
///           forge script script/EmergencyPause.s.sol \
///             --rpc-url <rpc> --broadcast             \
///             --sig "unpause(address)" <VAULT_ADDRESS>
///
///         Status check (no broadcast needed):
///           forge script script/EmergencyPause.s.sol \
///             --rpc-url <rpc>                         \
///             --sig "status(address)" <VAULT_ADDRESS>
contract EmergencyPause is Script {

    function pause(address vaultAddr) external {
        LiquidityVault vault = LiquidityVault(payable(vaultAddr));
        require(!vault.paused(), "EmergencyPause: vault is already paused");

        console2.log("Pausing vault:", vaultAddr);
        vm.broadcast();
        vault.pause();
        console2.log("[OK] Vault paused.");
        console2.log("     dailyVolume at pause : %d wei", vault.dailyVolume());
        console2.log("     vaultBalance         : %d wei", address(vault).balance);
    }

    function unpause(address vaultAddr) external {
        LiquidityVault vault = LiquidityVault(payable(vaultAddr));
        require(vault.paused(), "EmergencyPause: vault is not paused");

        console2.log("Unpausing vault:", vaultAddr);
        vm.broadcast();
        vault.unpause();
        console2.log("[OK] Vault unpaused.");
        console2.log("     txLimit  : %d wei", vault.txLimit());
        console2.log("     dailyCap : %d wei", vault.dailyCap());
    }

    function status(address vaultAddr) external view {
        LiquidityVault vault = LiquidityVault(payable(vaultAddr));
        console2.log("============================================");
        console2.log("  Vault Status:", vaultAddr);
        console2.log("============================================");
        console2.log("  paused       :", vault.paused() ? "YES (settlements blocked)" : "no");
        console2.log("  vaultBalance : %d wei", address(vault).balance);
        console2.log("  txLimit      : %d wei", vault.txLimit());
        console2.log("  dailyCap     : %d wei", vault.dailyCap());
        console2.log("  dailyVolume  : %d wei", vault.dailyVolume());
        console2.log("  windowEnd    : %d", vault.dailyWindowEnd());
        console2.log("  now          : %d", block.timestamp);
        uint256 remaining = 0;
        if (vault.dailyWindowEnd() > block.timestamp) {
            remaining = vault.dailyWindowEnd() - block.timestamp;
        }
        console2.log("  window resets in : %d seconds", remaining);
        console2.log("============================================");
    }
}
