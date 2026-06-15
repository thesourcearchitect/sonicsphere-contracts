// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {LiquidityVault}  from "../src/LiquidityVault.sol";
import {ILiquidityVault} from "../src/interfaces/ILiquidityVault.sol";

/// @notice Comprehensive test suite for LiquidityVault — Phase 1 (native ETH).
contract LiquidityVaultTest is Test {

    // -------------------------------------------------------------------------
    // Roles (mirrors contract constants)
    // -------------------------------------------------------------------------
    bytes32 constant RELAYER_ROLE  = keccak256("RELAYER_ROLE");
    bytes32 constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 constant DEFAULT_ADMIN = 0x00;

    // -------------------------------------------------------------------------
    // Actors
    // -------------------------------------------------------------------------
    address admin    = makeAddr("admin");
    address guardian = makeAddr("guardian");
    address relayer  = makeAddr("relayer");
    address user     = makeAddr("user");
    address attacker = makeAddr("attacker");

    // -------------------------------------------------------------------------
    // Risk params
    // -------------------------------------------------------------------------
    uint256 constant TX_LIMIT  = 1 ether;
    uint256 constant DAILY_CAP = 5 ether;

    LiquidityVault vault;

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------
    function setUp() public {
        vault = new LiquidityVault(admin, guardian, relayer, TX_LIMIT, DAILY_CAP);
        // Fund the vault
        vm.deal(address(vault), 100 ether);
        // Give relayer some gas
        vm.deal(relayer, 1 ether);
    }

    // =========================================================================
    // Constructor & role wiring
    // =========================================================================

    function test_RolesAssignedOnDeploy() public view {
        assertTrue(vault.hasRole(DEFAULT_ADMIN, admin));
        assertTrue(vault.hasRole(GUARDIAN_ROLE, guardian));
        assertTrue(vault.hasRole(RELAYER_ROLE, relayer));
    }

    function test_ConstructorSetsRiskParams() public view {
        assertEq(vault.txLimit(),  TX_LIMIT);
        assertEq(vault.dailyCap(), DAILY_CAP);
    }

    function test_ConstructorInitialisesWindow() public view {
        assertEq(vault.dailyVolume(),    0);
        assertGt(vault.dailyWindowEnd(), block.timestamp);
    }

    function test_RevertConstructor_ZeroAdmin() public {
        vm.expectRevert();
        new LiquidityVault(address(0), guardian, relayer, TX_LIMIT, DAILY_CAP);
    }

    function test_RevertConstructor_ZeroGuardian() public {
        vm.expectRevert();
        new LiquidityVault(admin, address(0), relayer, TX_LIMIT, DAILY_CAP);
    }

    function test_RevertConstructor_ZeroRelayer() public {
        vm.expectRevert();
        new LiquidityVault(admin, guardian, address(0), TX_LIMIT, DAILY_CAP);
    }

    function test_RevertConstructor_ZeroTxLimit() public {
        vm.expectRevert();
        new LiquidityVault(admin, guardian, relayer, 0, DAILY_CAP);
    }

    function test_RevertConstructor_DailyCapLtTxLimit() public {
        vm.expectRevert();
        new LiquidityVault(admin, guardian, relayer, TX_LIMIT, TX_LIMIT - 1);
    }

    // =========================================================================
    // Funding
    // =========================================================================

    function test_ReceiveEthEmitsVaultFunded() public {
        address funder = makeAddr("funder");
        vm.deal(funder, 2 ether);
        vm.expectEmit(true, false, false, true);
        emit ILiquidityVault.VaultFunded(funder, 1 ether);
        vm.prank(funder);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
    }

    function test_VaultBalanceReflectsFunding() public view {
        assertEq(vault.vaultBalance(), 100 ether);
    }

    // =========================================================================
    // executeSettlement — happy path
    // =========================================================================

    function test_ExecuteSettlement_BasicTransfer() public {
        bytes32 ref    = keccak256("fiat-tx-001");
        uint256 amount = 0.5 ether;
        uint256 before = user.balance;

        vm.prank(relayer);
        vault.executeSettlement(ref, payable(user), amount);

        assertEq(user.balance, before + amount);
        assertTrue(vault.isSettled(ref));
        assertEq(vault.dailyVolume(), amount);
    }

    function test_ExecuteSettlement_EmitsEvent() public {
        bytes32 ref    = keccak256("fiat-tx-002");
        uint256 amount = 0.25 ether;

        vm.expectEmit(true, true, true, true);
        emit ILiquidityVault.SettlementExecuted(ref, user, amount, relayer);

        vm.prank(relayer);
        vault.executeSettlement(ref, payable(user), amount);
    }

    function test_ExecuteSettlement_AtExactTxLimit() public {
        bytes32 ref = keccak256("exact-limit");
        vm.prank(relayer);
        vault.executeSettlement(ref, payable(user), TX_LIMIT);
        assertTrue(vault.isSettled(ref));
    }

    function test_ExecuteSettlement_MultipleUnderDailyCap() public {
        for (uint256 i = 0; i < 5; i++) {
            bytes32 ref = keccak256(abi.encodePacked("multi-tx-", i));
            vm.prank(relayer);
            vault.executeSettlement(ref, payable(user), 1 ether);
        }
        assertEq(vault.dailyVolume(), 5 ether);
    }

    // =========================================================================
    // executeSettlement — idempotency
    // =========================================================================

    function test_RevertSettlement_AlreadySettled() public {
        bytes32 ref = keccak256("dup-ref");
        vm.prank(relayer);
        vault.executeSettlement(ref, payable(user), 0.1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(ILiquidityVault.AlreadySettled.selector, ref)
        );
        vm.prank(relayer);
        vault.executeSettlement(ref, payable(user), 0.1 ether);
    }

    function test_RevertSettlement_CancelledRef() public {
        bytes32 ref = keccak256("cancelled-ref");
        vm.prank(guardian);
        vault.cancelSettlement(ref);

        vm.expectRevert(
            abi.encodeWithSelector(ILiquidityVault.SettlementRefCancelled.selector, ref)
        );
        vm.prank(relayer);
        vault.executeSettlement(ref, payable(user), 0.1 ether);
    }

    // =========================================================================
    // executeSettlement — input validation
    // =========================================================================

    function test_RevertSettlement_ZeroRef() public {
        vm.expectRevert(ILiquidityVault.InvalidSettlementRef.selector);
        vm.prank(relayer);
        vault.executeSettlement(bytes32(0), payable(user), 0.1 ether);
    }

    function test_RevertSettlement_ZeroRecipient() public {
        vm.expectRevert(ILiquidityVault.InvalidRecipient.selector);
        vm.prank(relayer);
        vault.executeSettlement(keccak256("ref"), payable(address(0)), 0.1 ether);
    }

    function test_RevertSettlement_ZeroAmount() public {
        vm.expectRevert(ILiquidityVault.InvalidAmount.selector);
        vm.prank(relayer);
        vault.executeSettlement(keccak256("ref"), payable(user), 0);
    }

    // =========================================================================
    // executeSettlement — risk parameter enforcement
    // =========================================================================

    function test_RevertSettlement_ExceedsTxLimit() public {
        uint256 over = TX_LIMIT + 1;
        vm.expectRevert(
            abi.encodeWithSelector(ILiquidityVault.ExceedsTxLimit.selector, over, TX_LIMIT)
        );
        vm.prank(relayer);
        vault.executeSettlement(keccak256("over-limit"), payable(user), over);
    }

    function test_RevertSettlement_ExceedsDailyCap() public {
        // Fill to the daily cap
        for (uint256 i = 0; i < 5; i++) {
            bytes32 ref = keccak256(abi.encodePacked("cap-fill-", i));
            vm.prank(relayer);
            vault.executeSettlement(ref, payable(user), 1 ether);
        }
        // One more should fail
        vm.expectRevert(
            abi.encodeWithSelector(ILiquidityVault.ExceedsDailyCap.selector, 1 ether, 0)
        );
        vm.prank(relayer);
        vault.executeSettlement(keccak256("cap-breach"), payable(user), 1 ether);
    }

    function test_DailyWindowResets() public {
        // Exhaust the daily cap
        for (uint256 i = 0; i < 5; i++) {
            bytes32 ref = keccak256(abi.encodePacked("window-fill-", i));
            vm.prank(relayer);
            vault.executeSettlement(ref, payable(user), 1 ether);
        }
        assertEq(vault.dailyVolume(), DAILY_CAP);

        // Advance time past the window
        vm.warp(vault.dailyWindowEnd() + 1);

        // Should succeed — window has reset
        bytes32 newRef = keccak256("post-reset");
        vm.prank(relayer);
        vault.executeSettlement(newRef, payable(user), 1 ether);
        assertEq(vault.dailyVolume(), 1 ether);
    }

    function test_RevertSettlement_InsufficientBalance() public {
        // Deploy a fresh vault with no ETH
        LiquidityVault emptyVault = new LiquidityVault(
            admin, guardian, relayer, TX_LIMIT, DAILY_CAP
        );
        bytes32 ref = keccak256("no-balance");
        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidityVault.InsufficientVaultBalance.selector, 0.5 ether, 0
            )
        );
        vm.prank(relayer);
        emptyVault.executeSettlement(ref, payable(user), 0.5 ether);
    }

    // =========================================================================
    // executeSettlement — access control
    // =========================================================================

    function test_RevertSettlement_CallerNotRelayer() public {
        vm.expectRevert();
        vm.prank(attacker);
        vault.executeSettlement(keccak256("attack"), payable(attacker), 0.1 ether);
    }

    function test_RevertSettlement_GuardianCannotSettle() public {
        vm.expectRevert();
        vm.prank(guardian);
        vault.executeSettlement(keccak256("guardian-settle"), payable(user), 0.1 ether);
    }

    // =========================================================================
    // Pause / unpause
    // =========================================================================

    function test_PauseBlocksSettlement() public {
        vm.prank(guardian);
        vault.pause();

        vm.expectRevert();
        vm.prank(relayer);
        vault.executeSettlement(keccak256("paused-ref"), payable(user), 0.1 ether);
    }

    function test_UnpauseResumesSettlement() public {
        vm.prank(guardian);
        vault.pause();

        vm.prank(guardian);
        vault.unpause();

        bytes32 ref = keccak256("resumed");
        vm.prank(relayer);
        vault.executeSettlement(ref, payable(user), 0.1 ether);
        assertTrue(vault.isSettled(ref));
    }

    function test_PauseEmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit ILiquidityVault.VaultPaused(guardian);
        vm.prank(guardian);
        vault.pause();
    }

    function test_UnpauseEmitsEvent() public {
        vm.prank(guardian);
        vault.pause();

        vm.expectEmit(true, false, false, false);
        emit ILiquidityVault.VaultUnpaused(guardian);
        vm.prank(guardian);
        vault.unpause();
    }

    function test_RevertPause_NotGuardian() public {
        vm.expectRevert();
        vm.prank(attacker);
        vault.pause();
    }

    // =========================================================================
    // cancelSettlement
    // =========================================================================

    function test_CancelSettlement_EmitsEvent() public {
        bytes32 ref = keccak256("to-cancel");
        vm.expectEmit(true, false, false, false);
        emit ILiquidityVault.SettlementCancelled(ref);
        vm.prank(guardian);
        vault.cancelSettlement(ref);
    }

    function test_RevertCancel_ZeroRef() public {
        vm.expectRevert(ILiquidityVault.InvalidSettlementRef.selector);
        vm.prank(guardian);
        vault.cancelSettlement(bytes32(0));
    }

    function test_RevertCancel_NotGuardian() public {
        vm.expectRevert();
        vm.prank(attacker);
        vault.cancelSettlement(keccak256("cancel-attack"));
    }

    // =========================================================================
    // setTxLimit
    // =========================================================================

    function test_SetTxLimit_UpdatesValue() public {
        uint256 newLimit = 0.5 ether;
        vm.prank(guardian);
        vault.setTxLimit(newLimit);
        assertEq(vault.txLimit(), newLimit);
    }

    function test_SetTxLimit_EmitsEvent() public {
        uint256 newLimit = 0.5 ether;
        vm.expectEmit(false, false, false, true);
        emit ILiquidityVault.TxLimitUpdated(TX_LIMIT, newLimit);
        vm.prank(guardian);
        vault.setTxLimit(newLimit);
    }

    function test_RevertSetTxLimit_Zero() public {
        vm.expectRevert();
        vm.prank(guardian);
        vault.setTxLimit(0);
    }

    function test_RevertSetTxLimit_ExceedsDailyCap() public {
        vm.expectRevert();
        vm.prank(guardian);
        vault.setTxLimit(DAILY_CAP + 1);
    }

    function test_RevertSetTxLimit_NotGuardian() public {
        vm.expectRevert();
        vm.prank(attacker);
        vault.setTxLimit(0.5 ether);
    }

    // =========================================================================
    // setDailyCap
    // =========================================================================

    function test_SetDailyCap_UpdatesValue() public {
        uint256 newCap = 20 ether;
        vm.prank(guardian);
        vault.setDailyCap(newCap);
        assertEq(vault.dailyCap(), newCap);
    }

    function test_SetDailyCap_EmitsEvent() public {
        uint256 newCap = 20 ether;
        vm.expectEmit(false, false, false, true);
        emit ILiquidityVault.DailyCapUpdated(DAILY_CAP, newCap);
        vm.prank(guardian);
        vault.setDailyCap(newCap);
    }

    function test_RevertSetDailyCap_LtTxLimit() public {
        vm.expectRevert();
        vm.prank(guardian);
        vault.setDailyCap(TX_LIMIT - 1);
    }

    function test_RevertSetDailyCap_NotGuardian() public {
        vm.expectRevert();
        vm.prank(attacker);
        vault.setDailyCap(20 ether);
    }

    // =========================================================================
    // rescueEth
    // =========================================================================

    function test_RescueEth_TransfersFunds() public {
        address payable rescueDest = payable(makeAddr("rescue"));
        uint256 vaultBefore = address(vault).balance;
        uint256 rescueAmt   = 10 ether;

        vm.prank(admin);
        vault.rescueEth(rescueDest, rescueAmt);

        assertEq(rescueDest.balance, rescueAmt);
        assertEq(address(vault).balance, vaultBefore - rescueAmt);
    }

    function test_RescueEth_EmitsEvent() public {
        address payable rescueDest = payable(makeAddr("rescue2"));
        vm.expectEmit(true, false, false, true);
        emit ILiquidityVault.EthRescued(rescueDest, 5 ether);
        vm.prank(admin);
        vault.rescueEth(rescueDest, 5 ether);
    }

    function test_RevertRescueEth_NotAdmin() public {
        vm.expectRevert();
        vm.prank(guardian);
        vault.rescueEth(payable(guardian), 1 ether);
    }

    function test_RevertRescueEth_RelayerCannotRescue() public {
        vm.expectRevert();
        vm.prank(relayer);
        vault.rescueEth(payable(relayer), 1 ether);
    }

    // =========================================================================
    // Fuzz tests
    // =========================================================================

    function testFuzz_ExecuteSettlement_AnyValidAmount(uint256 amount) public {
        amount = bound(amount, 1, TX_LIMIT);
        bytes32 ref = keccak256(abi.encodePacked("fuzz", amount));
        vm.prank(relayer);
        vault.executeSettlement(ref, payable(user), amount);
        assertTrue(vault.isSettled(ref));
    }

    function testFuzz_UniqueRefsAreIndependent(bytes32 ref1, bytes32 ref2) public {
        vm.assume(ref1 != ref2);
        vm.assume(ref1 != bytes32(0));
        vm.assume(ref2 != bytes32(0));

        uint256 amount = bound(uint256(ref1), 1, TX_LIMIT / 2);

        vm.prank(relayer);
        vault.executeSettlement(ref1, payable(user), amount);

        assertFalse(vault.isSettled(ref2));
    }
}
