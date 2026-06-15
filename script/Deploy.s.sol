// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {LiquidityVault}   from "../src/LiquidityVault.sol";

/// @notice Deployment script for LiquidityVault.
/// @dev    Reads all constructor parameters from environment variables.
///         Run on Base Sepolia (testnet):
///           forge script script/Deploy.s.sol \
///             --rpc-url base_sepolia \
///             --broadcast \
///             --verify \
///             -vvvv
///
///         Run on Base mainnet:
///           forge script script/Deploy.s.sol \
///             --rpc-url base \
///             --broadcast \
///             --verify \
///             -vvvv
contract DeployLiquidityVault is Script {

    function run() external returns (LiquidityVault vault) {
        // ── Load parameters from environment ─────────────────────────────────
        address admin    = vm.envAddress("ADMIN_ADDRESS");
        address guardian = vm.envAddress("GUARDIAN_ADDRESS");
        address relayer  = vm.envAddress("RELAYER_ADDRESS");
        uint256 txLimit  = vm.envUint("TX_LIMIT");
        uint256 dailyCap = vm.envUint("DAILY_CAP");

        console2.log("Deploying LiquidityVault");
        console2.log("  admin    :", admin);
        console2.log("  guardian :", guardian);
        console2.log("  relayer  :", relayer);
        console2.log("  txLimit  :", txLimit);
        console2.log("  dailyCap :", dailyCap);

        // ── Deploy ────────────────────────────────────────────────────────────
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        vault = new LiquidityVault(admin, guardian, relayer, txLimit, dailyCap);

        vm.stopBroadcast();

        console2.log("LiquidityVault deployed at:", address(vault));
    }
}
