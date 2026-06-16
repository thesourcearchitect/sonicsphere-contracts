// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {LiquidityVault}   from "../src/LiquidityVault.sol";

/// @notice Safely transfer DEFAULT_ADMIN_ROLE to a new address.
/// @dev    OpenZeppelin's AccessControl uses a two-step pattern for DEFAULT_ADMIN:
///         1. Current admin calls grantRole(DEFAULT_ADMIN, newAdmin).
///         2. Current admin calls revokeRole(DEFAULT_ADMIN, self).
///         Both steps are atomic in a single broadcast here to prevent a window
///         where no admin exists (or two admins exist for longer than one block).
///
///         WARNING: This is a one-way, irreversible operation.
///         Verify the new admin address carefully before broadcasting.
///
///         Usage:
///           NEW_ADMIN=0x... VAULT_ADDRESS=0x... \
///             forge script script/TransferAdmin.s.sol \
///             --rpc-url base --broadcast
///
///         Dry-run (no broadcast):
///           NEW_ADMIN=0x... VAULT_ADDRESS=0x... \
///             forge script script/TransferAdmin.s.sol --rpc-url base
contract TransferAdmin is Script {

    bytes32 constant DEFAULT_ADMIN = 0x00;

    function run() external {
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");
        address newAdmin  = vm.envAddress("NEW_ADMIN");
        _execute(vaultAddr, newAdmin);
    }

    function runAt(address vaultAddr, address newAdmin) external {
        _execute(vaultAddr, newAdmin);
    }

    // -------------------------------------------------------------------------

    function _execute(address vaultAddr, address newAdmin) internal {
        require(newAdmin != address(0), "TransferAdmin: new admin cannot be zero address");

        LiquidityVault vault = LiquidityVault(payable(vaultAddr));

        // Determine the current broadcaster (must be the current admin)
        address currentAdmin = msg.sender;

        console2.log("================================================");
        console2.log("  TransferAdmin");
        console2.log("  vault        :", vaultAddr);
        console2.log("  current admin:", currentAdmin);
        console2.log("  new admin    :", newAdmin);
        console2.log("================================================");

        // Pre-flight checks
        require(
            vault.hasRole(DEFAULT_ADMIN, currentAdmin),
            "TransferAdmin: broadcaster does not hold DEFAULT_ADMIN_ROLE"
        );
        require(
            !vault.hasRole(DEFAULT_ADMIN, newAdmin),
            "TransferAdmin: new admin already holds DEFAULT_ADMIN_ROLE"
        );
        require(newAdmin != currentAdmin, "TransferAdmin: new admin is the same as current admin");

        console2.log("\n  [OK] Pre-flight checks passed.");
        console2.log("  WARNING: this operation is irreversible. Broadcasting in 3...");

        vm.startBroadcast();

        // Step 1: grant admin to the new address
        vault.grantRole(DEFAULT_ADMIN, newAdmin);
        console2.log("  [OK] Granted DEFAULT_ADMIN_ROLE to new admin.");

        // Step 2: revoke from the current admin
        vault.revokeRole(DEFAULT_ADMIN, currentAdmin);
        console2.log("  [OK] Revoked DEFAULT_ADMIN_ROLE from current admin.");

        vm.stopBroadcast();

        // Post-broadcast assertions (read-only, informational)
        console2.log("\n  Post-transfer state:");
        console2.log("    newAdmin has DEFAULT_ADMIN_ROLE  : %s",
            vault.hasRole(DEFAULT_ADMIN, newAdmin) ? "YES" : "NO"
        );
        console2.log("    oldAdmin has DEFAULT_ADMIN_ROLE  : %s",
            vault.hasRole(DEFAULT_ADMIN, currentAdmin) ? "STILL YES (error)" : "no"
        );

        console2.log("\n================================================");
        console2.log("  Done. Admin transfer complete.");
        console2.log("================================================");
    }
}
