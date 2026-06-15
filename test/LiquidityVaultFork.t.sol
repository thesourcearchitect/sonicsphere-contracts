// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test, console2}   from "forge-std/Test.sol";
import {LiquidityVault}   from "../src/LiquidityVault.sol";
import {ILiquidityVault}  from "../src/interfaces/ILiquidityVault.sol";

/// @title LiquidityVaultForkTest
/// @notice Fork tests that run against a real Base Sepolia state.
///         These are skipped in standard CI (no RPC) but can be run locally
///         or in a dedicated fork-test workflow.
///
///         Run:
///           BASE_SEPOLIA_RPC_URL=https://sepolia.base.org \
///             forge test --match-contract LiquidityVaultFork \
///             --fork-url $BASE_SEPOLIA_RPC_URL -vvv
///
///         If VAULT_ADDRESS is set, tests run against the deployed vault.
///         If not set, a fresh vault is deployed on the fork.
contract LiquidityVaultForkTest is Test {

    bytes32 constant RELAYER_ROLE  = keccak256("RELAYER_ROLE");
    bytes32 constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    address admin    = makeAddr("admin");
    address guardian = makeAddr("guardian");
    address relayer  = makeAddr("relayer");
    address user     = makeAddr("user");

    uint256 constant TX_LIMIT  = 1 ether;
    uint256 constant DAILY_CAP = 5 ether;
    uint256 constant FUND_AMT  = 10 ether;

    LiquidityVault vault;
    bool           forkedDeployment; // true if VAULT_ADDRESS env var was set

    // =========================================================================
    // Setup
    // =========================================================================

    function setUp() public {
        // Skip gracefully if no fork URL is provided (plain `forge test`)
        string memory rpc = vm.envOr("BASE_SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
        }

        // Attempt to use a deployed vault address if provided
        address vaultAddr = vm.envOr("VAULT_ADDRESS", address(0));
        if (vaultAddr != address(0)) {
            vault            = LiquidityVault(payable(vaultAddr));
            forkedDeployment = true;
            console2.log("[fork] Using deployed vault:", vaultAddr);
        } else {
            // Deploy a fresh vault on the fork
            vault = new LiquidityVault(admin, guardian, relayer, TX_LIMIT, DAILY_CAP);
            vm.deal(address(vault), FUND_AMT);
            forkedDeployment = false;
            console2.log("[fork] Fresh vault deployed at:", address(vault));
        }
    }

    // =========================================================================
    // Baseline state checks
    // =========================================================================

    function test_Fork_ContractDeployed() public view {
        uint256 size;
        address addr = address(vault);
        assembly { size := extcodesize(addr) }
        assertGt(size, 0, "vault has no bytecode on fork");
        console2.log("[fork] bytecode size:", size);
    }

    function test_Fork_ViewFunctionsRespond() public view {
        // All view functions must return without reverting
        uint256 txLimit  = vault.txLimit();
        uint256 dailyCap = vault.dailyCap();
        uint256 vol      = vault.dailyVolume();
        uint256 windowEnd = vault.dailyWindowEnd();
        uint256 balance  = vault.vaultBalance();
        bool    paused   = vault.paused();

        console2.log("[fork] txLimit     :", txLimit);
        console2.log("[fork] dailyCap    :", dailyCap);
        console2.log("[fork] dailyVolume :", vol);
        console2.log("[fork] windowEnd   :", windowEnd);
        console2.log("[fork] vaultBalance:", balance);
        console2.log("[fork] paused      :", paused);

        assertGt(txLimit,   0, "txLimit must be > 0");
        assertGt(dailyCap,  0, "dailyCap must be > 0");
        assertGe(dailyCap,  txLimit, "dailyCap must be >= txLimit");
    }

    function test_Fork_IsSettledReturnsFalseForNovelRef() public view {
        bytes32 ref = keccak256(abi.encodePacked("fork-novel-ref", block.number));
        assertFalse(vault.isSettled(ref));
    }

    function test_Fork_VaultBalanceEqualsAddressBalance() public view {
        assertEq(vault.vaultBalance(), address(vault).balance);
    }

    // =========================================================================
    // Settlement execution on fork (only on fresh deployments)
    // =========================================================================

    function test_Fork_ExecuteSettlement_FreshDeployment() public {
        if (forkedDeployment) {
            vm.skip(true); // skip against live vault to avoid tx interference
        }

        uint256 amount = 0.1 ether;
        bytes32 ref    = keccak256(abi.encodePacked("fork-settle", block.number));

        uint256 userBefore  = address(user).balance;
        uint256 vaultBefore = address(vault).balance;

        vm.prank(relayer);
        vault.executeSettlement(ref, payable(user), amount);

        assertEq(address(user).balance,  userBefore  + amount);
        assertEq(address(vault).balance, vaultBefore - amount);
        assertTrue(vault.isSettled(ref));
        assertEq(vault.dailyVolume(), amount);

        console2.log("[fork] settlement executed on fork. user received:", amount);
    }

    function test_Fork_Idempotency_OnFork() public {
        if (forkedDeployment) {
            vm.skip(true);
        }

        bytes32 ref = keccak256(abi.encodePacked("fork-idempotent", block.number));

        vm.prank(relayer);
        vault.executeSettlement(ref, payable(user), 0.1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(ILiquidityVault.AlreadySettled.selector, ref)
        );
        vm.prank(relayer);
        vault.executeSettlement(ref, payable(user), 0.1 ether);
    }

    function test_Fork_DailyCapEnforced_OnFork() public {
        if (forkedDeployment) {
            vm.skip(true);
        }

        // Exhaust the cap
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(relayer);
            vault.executeSettlement(
                keccak256(abi.encodePacked("fork-cap-", i)),
                payable(user),
                1 ether
            );
        }

        assertEq(vault.dailyVolume(), DAILY_CAP);

        vm.expectRevert();
        vm.prank(relayer);
        vault.executeSettlement(
            keccak256("fork-over-cap"),
            payable(user),
            0.01 ether
        );
    }

    // =========================================================================
    // Emergency scenarios on fork
    // =========================================================================

    function test_Fork_PauseAndUnpause_FreshDeployment() public {
        if (forkedDeployment) {
            vm.skip(true);
        }

        vm.prank(guardian);
        vault.pause();
        assertTrue(vault.paused());

        bytes32 ref = keccak256("fork-pause-block");
        vm.expectRevert();
        vm.prank(relayer);
        vault.executeSettlement(ref, payable(user), 0.1 ether);

        vm.prank(guardian);
        vault.unpause();
        assertFalse(vault.paused());

        // Should succeed after unpause
        vm.prank(relayer);
        vault.executeSettlement(ref, payable(user), 0.1 ether);
        assertTrue(vault.isSettled(ref));
    }

    function test_Fork_VaultCanReceiveETH() public {
        if (forkedDeployment) {
            vm.skip(true);
        }

        uint256 before = address(vault).balance;
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok, "ETH transfer to vault failed on fork");
        assertEq(address(vault).balance, before + 1 ether);
    }
}
