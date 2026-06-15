// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {LiquidityVault}   from "../src/LiquidityVault.sol";

/// @notice Emergency script to recover ETH from a deployed LiquidityVault.
/// @dev    The broadcaster must hold DEFAULT_ADMIN_ROLE on the target vault.
///         Intended for emergency use only (contract decommission, critical bug).
///
///         Rescue all ETH:
///           VAULT_ADDRESS=0x... RESCUE_TARGET=0x... \
///             forge script script/RescueEth.s.sol \
///             --rpc-url base --broadcast
///
///         Rescue a specific amount:
///           VAULT_ADDRESS=0x... RESCUE_TARGET=0x... RESCUE_AMOUNT=1000000000000000000 \
///             forge script script/RescueEth.s.sol \
///             --rpc-url base --broadcast
///
///         Dry-run (no broadcast, just prints what would happen):
///           VAULT_ADDRESS=0x... RESCUE_TARGET=0x... \
///             forge script script/RescueEth.s.sol --rpc-url base
///
///         NOTE: If the vault is not paused, consider pausing it first with
///         EmergencyPause.s.sol to prevent settlements during the rescue.
contract RescueEth is Script {

    function run() external {
        address vaultAddr   = vm.envAddress("VAULT_ADDRESS");
        address target      = vm.envAddress("RESCUE_TARGET");
        // 0 means "rescue all"
        uint256 amount      = vm.envOr("RESCUE_AMOUNT", uint256(0));
        _execute(vaultAddr, target, amount);
    }

    function run(address vaultAddr, address payable target, uint256 amount) external {
        _execute(vaultAddr, target, amount);
    }

    // -------------------------------------------------------------------------

    function _execute(address vaultAddr, address target, uint256 requestedAmount) internal {
        require(target != address(0), "RescueEth: target cannot be zero address");

        LiquidityVault vault = LiquidityVault(payable(vaultAddr));
        uint256 vaultBalance = address(vault).balance;
        uint256 amount       = requestedAmount == 0 ? vaultBalance : requestedAmount;

        console2.log("================================================");
        console2.log("  RescueEth");
        console2.log("  vault         :", vaultAddr);
        console2.log("  target        :", target);
        console2.log("  amount (wei)  :", amount);
        console2.log("  vault balance :", vaultBalance);
        console2.log("  paused        :", vault.paused() ? "YES" : "no");
        console2.log("================================================");

        require(amount > 0,            "RescueEth: nothing to rescue (vault is empty)");
        require(amount <= vaultBalance, "RescueEth: amount exceeds vault balance");

        if (!vault.paused()) {
            console2.log("\n  WARNING: vault is NOT paused.");
            console2.log("           Settlements may occur concurrently with this rescue.");
            console2.log("           Consider pausing first with EmergencyPause.s.sol.");
        }

        uint256 targetBefore = target.balance;

        vm.broadcast();
        vault.rescueEth(payable(target), amount);

        uint256 targetAfter = target.balance;

        console2.log("\n  Result:");
        console2.log("    vault balance (after) : %d wei", address(vault).balance);
        console2.log("    target received       : %d wei", targetAfter - targetBefore);
        console2.log("\n================================================");
        console2.log("  Done.");
        console2.log("================================================");
    }
}
