// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {LiquidityVault}   from "../src/LiquidityVault.sol";

/// @notice Post-deployment verification script for LiquidityVault.
/// @dev    Run immediately after Deploy.s.sol to confirm every role, risk
///         parameter, and contract state is configured correctly before
///         funding the vault or granting live relayer access.
///
///         Usage (read-only, no broadcast needed):
///           forge script script/VerifyDeployment.s.sol \
///             --rpc-url base_sepolia \
///             --sig "run(address)" <DEPLOYED_VAULT_ADDRESS>
///
///         Each check prints PASS/FAIL. A revert at the end signals failure.
contract VerifyDeployment is Script {

    bytes32 constant RELAYER_ROLE  = keccak256("RELAYER_ROLE");
    bytes32 constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 constant DEFAULT_ADMIN = 0x00;

    uint256 private _failures;

    function run(address vaultAddress) external {
        LiquidityVault vault = LiquidityVault(payable(vaultAddress));

        console2.log("========================================");
        console2.log("  LiquidityVault - Deployment Verify");
        console2.log("  vault:", vaultAddress);
        console2.log("========================================");

        _verifyCode(vaultAddress);
        _verifyRoles(vault);
        _verifyRiskParams(vault);
        _verifyOperationalState(vault);
        _verifyInterface(vault);

        console2.log("----------------------------------------");
        if (_failures == 0) {
            console2.log("  RESULT: ALL CHECKS PASSED");
        } else {
            console2.log("  RESULT: FAILED (%d checks)", _failures);
            revert("VerifyDeployment: one or more checks failed");
        }
        console2.log("========================================");
    }

    // -------------------------------------------------------------------------
    // Check groups
    // -------------------------------------------------------------------------

    function _verifyCode(address addr) internal {
        console2.log("\n[1] Contract existence");
        uint256 size;
        assembly { size := extcodesize(addr) }
        _check("Contract has deployed bytecode", size > 0);
    }

    function _verifyRoles(LiquidityVault vault) internal {
        console2.log("\n[2] Role assignments");

        address admin    = vm.envAddress("ADMIN_ADDRESS");
        address guardian = vm.envAddress("GUARDIAN_ADDRESS");
        address relayer  = vm.envAddress("RELAYER_ADDRESS");

        _check("ADMIN holds DEFAULT_ADMIN_ROLE",            vault.hasRole(DEFAULT_ADMIN,  admin));
        _check("GUARDIAN holds GUARDIAN_ROLE",              vault.hasRole(GUARDIAN_ROLE,  guardian));
        _check("RELAYER holds RELAYER_ROLE",                vault.hasRole(RELAYER_ROLE,   relayer));
        _check("RELAYER does not hold GUARDIAN_ROLE",      !vault.hasRole(GUARDIAN_ROLE,  relayer));
        _check("RELAYER does not hold DEFAULT_ADMIN_ROLE", !vault.hasRole(DEFAULT_ADMIN,  relayer));
        _check("GUARDIAN does not hold RELAYER_ROLE",      !vault.hasRole(RELAYER_ROLE,   guardian));
        _check("GUARDIAN does not hold DEFAULT_ADMIN_ROLE",!vault.hasRole(DEFAULT_ADMIN,  guardian));

        console2.log("  admin    : %s", admin);
        console2.log("  guardian : %s", guardian);
        console2.log("  relayer  : %s", relayer);
    }

    function _verifyRiskParams(LiquidityVault vault) internal {
        console2.log("\n[3] Risk parameters");

        uint256 expectedTxLimit  = vm.envUint("TX_LIMIT");
        uint256 expectedDailyCap = vm.envUint("DAILY_CAP");

        uint256 actualTxLimit  = vault.txLimit();
        uint256 actualDailyCap = vault.dailyCap();

        _check("txLimit matches expected",   actualTxLimit  == expectedTxLimit);
        _check("dailyCap matches expected",  actualDailyCap == expectedDailyCap);
        _check("txLimit <= dailyCap",        actualTxLimit  <= actualDailyCap);
        _check("txLimit > 0",               actualTxLimit  > 0);
        _check("dailyCap > 0",              actualDailyCap > 0);

        console2.log("  txLimit  : %d wei", actualTxLimit);
        console2.log("  dailyCap : %d wei", actualDailyCap);
    }

    function _verifyOperationalState(LiquidityVault vault) internal {
        console2.log("\n[4] Operational state");

        _check("Vault is NOT paused",                  !vault.paused());
        _check("dailyVolume is 0",                      vault.dailyVolume() == 0);
        _check("dailyWindowEnd is in the future",       vault.dailyWindowEnd() > block.timestamp);
        _check("Daily window is approx 24h",
            vault.dailyWindowEnd() > block.timestamp + 23 hours &&
            vault.dailyWindowEnd() < block.timestamp + 25 hours
        );

        uint256 balance = vault.vaultBalance();
        console2.log("  paused       : false");
        console2.log("  dailyVolume  : 0");
        console2.log("  vaultBalance : %d wei", balance);
        console2.log("  windowEnd    : %d", vault.dailyWindowEnd());

        if (balance == 0) {
            console2.log("  NOTE: vault has no ETH yet - fund before enabling relayer");
        }
    }

    function _verifyInterface(LiquidityVault vault) internal {
        console2.log("\n[5] Interface smoke tests");

        bytes32 novelRef = keccak256(abi.encodePacked("verify-probe", block.timestamp));

        _check("isSettled(novelRef) == false",        !vault.isSettled(novelRef));
        _check("vaultBalance() == address.balance",    vault.vaultBalance() == address(vault).balance);
        _check("RELAYER_ROLE admin is DEFAULT_ADMIN",  vault.getRoleAdmin(RELAYER_ROLE)  == DEFAULT_ADMIN);
        _check("GUARDIAN_ROLE admin is DEFAULT_ADMIN", vault.getRoleAdmin(GUARDIAN_ROLE) == DEFAULT_ADMIN);
    }

    // -------------------------------------------------------------------------
    // Internal helper
    // -------------------------------------------------------------------------

    function _check(string memory description, bool condition) internal {
        if (condition) {
            console2.log("  [PASS] %s", description);
        } else {
            console2.log("  [FAIL] %s", description);
            _failures++;
        }
    }
}
