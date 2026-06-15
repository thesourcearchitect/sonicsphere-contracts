// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {LiquidityVault}   from "../src/LiquidityVault.sol";

/// @notice Fund a deployed LiquidityVault with native ETH.
/// @dev    The broadcaster must be a funded EOA. No special role is required
///         to fund the vault (the receive() function accepts ETH from anyone).
///
///         Usage:
///           VAULT_ADDRESS=0x... FUND_AMOUNT=1000000000000000000 \
///             forge script script/FundVault.s.sol \
///             --rpc-url base_sepolia --broadcast
///
///         Or pass values as args:
///           forge script script/FundVault.s.sol \
///             --rpc-url base_sepolia --broadcast \
///             --sig "run(address,uint256)" <VAULT_ADDRESS> <AMOUNT_WEI>
///
///         Security note: ensure the target vault address and amount are
///         confirmed via VerifyDeployment.s.sol before funding production.
contract FundVault is Script {

    // Entry point A: env vars
    function run() external {
        address vault  = vm.envAddress("VAULT_ADDRESS");
        uint256 amount = vm.envUint("FUND_AMOUNT");
        _execute(vault, amount);
    }

    // Entry point B: script args
    function run(address vault, uint256 amount) external {
        _execute(vault, amount);
    }

    // -------------------------------------------------------------------------

    function _execute(address vaultAddr, uint256 amount) internal {
        require(amount > 0, "FundVault: amount must be > 0");

        LiquidityVault vault = LiquidityVault(payable(vaultAddr));

        uint256 balanceBefore = address(vault).balance;
        uint256 senderBalance = address(msg.sender).balance;

        console2.log("================================================");
        console2.log("  FundVault");
        console2.log("  vault  :", vaultAddr);
        console2.log("  amount : %d wei", amount);
        console2.log("================================================");
        console2.log("\n  Pre-flight:");
        console2.log("    vault balance (before) : %d wei", balanceBefore);
        console2.log("    sender balance         : %d wei", senderBalance);
        console2.log("    vault paused           : %s", vault.paused() ? "YES" : "no");
        console2.log("    txLimit                : %d wei", vault.txLimit());
        console2.log("    dailyCap               : %d wei", vault.dailyCap());

        require(senderBalance >= amount, "FundVault: sender has insufficient ETH");

        if (vault.paused()) {
            console2.log("\n  WARNING: vault is currently paused");
        }

        vm.broadcast();
        (bool ok,) = vaultAddr.call{value: amount}("");
        require(ok, "FundVault: ETH transfer to vault failed");

        uint256 balanceAfter = address(vault).balance;

        console2.log("\n  Result:");
        console2.log("    vault balance (after)  : %d wei", balanceAfter);
        console2.log("    net funded             : %d wei", balanceAfter - balanceBefore);
        console2.log("\n================================================");
        console2.log("  Done. Vault is funded and ready for settlements.");
        console2.log("================================================");
    }
}
