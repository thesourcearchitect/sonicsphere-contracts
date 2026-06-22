// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {LiquidityVault}   from "../src/LiquidityVault.sol";

/// @notice Wire a deployed ProtocolAccount to the Phase 1 LiquidityVault by
///         granting it RELAYER_ROLE (and optionally revoking a placeholder).
/// @dev    MUST be broadcast by the holder of the vault's DEFAULT_ADMIN_ROLE —
///         a timelock/multisig, NEVER the KMS key. The broadcasting key here is
///         only the admin's gas-payer.
///
///         Environment:
///           • VAULT_ADDRESS            — deployed LiquidityVault.
///           • PROTOCOL_ACCOUNT_ADDRESS — deployed ProtocolAccount to authorize.
///           • OLD_RELAYER_ADDRESS      — optional; placeholder/previous relayer
///                                        to revoke (skipped if unset / zero).
///           • DEPLOYER_PRIVATE_KEY     — the admin's gas-paying key.
///
///         Run:
///           forge script script/GrantRelayer.s.sol --rpc-url base_sepolia --broadcast -vvvv
contract GrantRelayer is Script {
    function run() external {
        LiquidityVault vault = LiquidityVault(payable(vm.envAddress("VAULT_ADDRESS")));
        address newRelayer   = vm.envAddress("PROTOCOL_ACCOUNT_ADDRESS");
        address oldRelayer   = vm.envOr("OLD_RELAYER_ADDRESS", address(0));

        bytes32 role = vault.RELAYER_ROLE();

        console2.log("Granting RELAYER_ROLE");
        console2.log("  vault          :", address(vault));
        console2.log("  protocolAccount:", newRelayer);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        vault.grantRole(role, newRelayer);
        if (oldRelayer != address(0)) {
            console2.log("  revoking old   :", oldRelayer);
            vault.revokeRole(role, oldRelayer);
        }
        vm.stopBroadcast();

        require(vault.hasRole(role, newRelayer), "grant failed");
        console2.log("RELAYER_ROLE granted to ProtocolAccount");
    }
}
