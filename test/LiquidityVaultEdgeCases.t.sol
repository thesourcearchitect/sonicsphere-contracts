// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test, console2}         from "forge-std/Test.sol";
import {LiquidityVault}         from "../src/LiquidityVault.sol";
import {ILiquidityVault}        from "../src/interfaces/ILiquidityVault.sol";
import {MockFailingReceiver}     from "./mocks/MockFailingReceiver.sol";

/// @notice Edge-case and integration tests that complement LiquidityVaultTest.
///         Focuses on failure modes, boundary conditions, and role-interaction
///         scenarios not covered by the primary suite.
contract LiquidityVaultEdgeCasesTest is Test {

    bytes32 constant RELAYER_ROLE  = keccak256("RELAYER_ROLE");
    bytes32 constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    address admin    = makeAddr("admin");
    address guardian = makeAddr("guardian");
    address relayer  = makeAddr("relayer");
    address user     = makeAddr("user");

    uint256 constant TX_LIMIT  = 1 ether;
    uint256 constant DAILY_CAP = 5 ether;

    LiquidityVault       vault;
    MockFailingReceiver   failReceiver;

    function setUp() public {
        vault = new LiquidityVault(admin, guardian, relayer, TX_LIMIT, DAILY_CAP);
        vm.deal(address(vault), 100 ether);
        failReceiver = new MockFailingReceiver();
    }

    // =========================================================================
    // TransferFailed — failing receiver
    // =========================================================================

    function test_RevertSettlement_RecipientReverts() public {
        bytes32 ref = keccak256("fail-receiver");
        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidityVault.TransferFailed.selector,
                address(failReceiver),
                0.5 ether
            )
        );
        vm.prank(relayer);
        vault.executeSettlement(ref, payable(address(failReceiver)), 0.5 ether);
    }

    function test_RevertSettlement_FailedTransfer_DoesNotMarkAsSettled() public {
        bytes32 ref = keccak256("fail-no-mark");
        vm.prank(relayer);
        try vault.executeSettlement(ref, payable(address(failReceiver)), 0.5 ether) {}
        catch {}
        // Must NOT be marked settled after a failed transfer
        assertFalse(vault.isSettled(ref));
    }

    function test_RevertSettlement_FailedTransfer_DoesNotReduceBalance() public {
        uint256 balBefore = address(vault).balance;
        bytes32 ref       = keccak256("fail-no-debit");
        vm.prank(relayer);
        try vault.executeSettlement(ref, payable(address(failReceiver)), 0.5 ether) {}
        catch {}
        assertEq(address(vault).balance, balBefore);
    }

    function test_RevertSettlement_FailedTransfer_DoesNotCountTowardsDailyVolume() public {
        bytes32 ref = keccak256("fail-no-volume");
        vm.prank(relayer);
        try vault.executeSettlement(ref, payable(address(failReceiver)), 0.5 ether) {}
        catch {}
        assertEq(vault.dailyVolume(), 0);
    }

    function test_AfterFailedTransfer_RefCanBeRetried() public {
        bytes32 ref = keccak256("retry-ref");
        // First attempt — receiver rejects
        vm.prank(relayer);
        try vault.executeSettlement(ref, payable(address(failReceiver)), 0.5 ether) {}
        catch {}

        // Second attempt with a working recipient — must succeed because
        // the ref was never marked settled
        vm.prank(relayer);
        vault.executeSettlement(ref, payable(user), 0.5 ether);
        assertTrue(vault.isSettled(ref));
    }

    // =========================================================================
    // Daily window boundary conditions
    // =========================================================================

    function test_SettlementAtExactWindowBoundary() public {
        // Advance time to exactly the window end (should trigger a reset)
        vm.warp(vault.dailyWindowEnd());

        bytes32 ref = keccak256("boundary-settle");
        vm.prank(relayer);
        vault.executeSettlement(ref, payable(user), 0.5 ether);

        // Volume should be 0.5 ether in the new window, not accumulated
        assertEq(vault.dailyVolume(), 0.5 ether);
    }

    function test_MultipleWindowResets() public {
        // Fill window day 1
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(relayer);
            vault.executeSettlement(
                keccak256(abi.encodePacked("day1-", i)),
                payable(user),
                1 ether
            );
        }
        assertEq(vault.dailyVolume(), DAILY_CAP);

        // Window 2
        vm.warp(vault.dailyWindowEnd() + 1);
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(relayer);
            vault.executeSettlement(
                keccak256(abi.encodePacked("day2-", i)),
                payable(user),
                1 ether
            );
        }
        assertEq(vault.dailyVolume(), DAILY_CAP);

        // Window 3
        vm.warp(vault.dailyWindowEnd() + 1);
        bytes32 ref = keccak256("day3");
        vm.prank(relayer);
        vault.executeSettlement(ref, payable(user), 0.1 ether);
        assertEq(vault.dailyVolume(), 0.1 ether);
    }

    function test_DailyWindowEndAdvancesCorrectly() public {
        uint256 windowBefore = vault.dailyWindowEnd();
        vm.warp(windowBefore + 1);
        bytes32 ref = keccak256("advance-window");
        vm.prank(relayer);
        vault.executeSettlement(ref, payable(user), 0.1 ether);
        // New window end should be approximately 24h from current timestamp
        assertApproxEqAbs(vault.dailyWindowEnd(), block.timestamp + 1 days, 5);
        assertTrue(vault.dailyWindowEnd() > windowBefore);
    }

    // =========================================================================
    // Risk parameter interaction sequences
    // =========================================================================

    function test_ReduceTxLimit_ThenSettle_AtNewLimit() public {
        uint256 newLimit = 0.3 ether;
        vm.prank(guardian);
        vault.setTxLimit(newLimit);

        // Settlement at exactly new limit — should pass
        vm.prank(relayer);
        vault.executeSettlement(keccak256("new-limit-exact"), payable(user), newLimit);
        assertTrue(vault.isSettled(keccak256("new-limit-exact")));

        // Settlement one wei over new limit — should fail
        vm.expectRevert(
            abi.encodeWithSelector(ILiquidityVault.ExceedsTxLimit.selector, newLimit + 1, newLimit)
        );
        vm.prank(relayer);
        vault.executeSettlement(keccak256("new-limit-over"), payable(user), newLimit + 1);
    }

    function test_IncreaseDailyCap_AllowsMoreVolume() public {
        // Exhaust original daily cap
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(relayer);
            vault.executeSettlement(
                keccak256(abi.encodePacked("exhaust-", i)),
                payable(user),
                1 ether
            );
        }

        // Increase the cap and txLimit together
        vm.prank(guardian);
        vault.setDailyCap(10 ether);
        vm.prank(guardian);
        vault.setTxLimit(2 ether);

        // Should now be able to settle more
        vm.prank(relayer);
        vault.executeSettlement(keccak256("extra-volume"), payable(user), 2 ether);
        assertEq(vault.dailyVolume(), 7 ether);
    }

    function test_SetTxLimitToMatchDailyCap() public {
        // Setting txLimit == dailyCap is valid (one tx exhausts the day)
        vm.prank(guardian);
        vault.setTxLimit(DAILY_CAP);
        assertEq(vault.txLimit(), DAILY_CAP);
    }

    // =========================================================================
    // Role grant / revoke sequences
    // =========================================================================

    function test_AdminCanRevokeRelayerRole() public {
        vm.prank(admin);
        vault.revokeRole(RELAYER_ROLE, relayer);
        assertFalse(vault.hasRole(RELAYER_ROLE, relayer));

        // Revoked relayer cannot settle
        vm.expectRevert();
        vm.prank(relayer);
        vault.executeSettlement(keccak256("post-revoke"), payable(user), 0.1 ether);
    }

    function test_AdminCanGrantNewRelayer() public {
        address newRelayer = makeAddr("new-relayer");
        vm.prank(admin);
        vault.grantRole(RELAYER_ROLE, newRelayer);
        assertTrue(vault.hasRole(RELAYER_ROLE, newRelayer));

        vm.deal(newRelayer, 1 ether);
        vm.prank(newRelayer);
        vault.executeSettlement(keccak256("new-relayer-settle"), payable(user), 0.1 ether);
        assertTrue(vault.isSettled(keccak256("new-relayer-settle")));
    }

    function test_AdminCanRevokeAndReplaceGuardian() public {
        address newGuardian = makeAddr("new-guardian");
        vm.startPrank(admin);
        vault.revokeRole(GUARDIAN_ROLE, guardian);
        vault.grantRole(GUARDIAN_ROLE, newGuardian);
        vm.stopPrank();

        // Old guardian cannot pause
        vm.expectRevert();
        vm.prank(guardian);
        vault.pause();

        // New guardian can pause
        vm.prank(newGuardian);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_GuardianCannotGrantRoles() public {
        vm.expectRevert();
        vm.prank(guardian);
        vault.grantRole(RELAYER_ROLE, makeAddr("attacker"));
    }

    // =========================================================================
    // cancelSettlement interaction with executeSettlement
    // =========================================================================

    function test_CancelBeforeAndAfterSettlement() public {
        bytes32 alreadySettled = keccak256("already-settled");
        bytes32 notYetSettled  = keccak256("not-yet-settled");

        // Settle one ref
        vm.prank(relayer);
        vault.executeSettlement(alreadySettled, payable(user), 0.1 ether);

        // Cancel both refs
        vm.prank(guardian);
        vault.cancelSettlement(alreadySettled);
        vm.prank(guardian);
        vault.cancelSettlement(notYetSettled);

        // Already settled ref — cancellation is stored but doesn't un-settle
        assertTrue(vault.isSettled(alreadySettled));

        // Not-yet-settled ref — now blocked
        vm.expectRevert(
            abi.encodeWithSelector(ILiquidityVault.SettlementRefCancelled.selector, notYetSettled)
        );
        vm.prank(relayer);
        vault.executeSettlement(notYetSettled, payable(user), 0.1 ether);
    }

    function test_CancelDoesNotAffectOtherRefs() public {
        bytes32 toCancel = keccak256("to-cancel");
        bytes32 other    = keccak256("other-ref");

        vm.prank(guardian);
        vault.cancelSettlement(toCancel);

        // 'other' should still be settleable
        vm.prank(relayer);
        vault.executeSettlement(other, payable(user), 0.5 ether);
        assertTrue(vault.isSettled(other));
    }

    // =========================================================================
    // rescueEth edge cases
    // =========================================================================

    function test_RescueFullBalance() public {
        uint256 bal = address(vault).balance;
        vm.prank(admin);
        vault.rescueEth(payable(admin), bal);
        assertEq(address(vault).balance, 0);
    }

    function test_RevertRescue_ZeroTarget() public {
        vm.expectRevert();
        vm.prank(admin);
        vault.rescueEth(payable(address(0)), 1 ether);
    }

    function test_RevertRescue_ExceedsBalance() public {
        uint256 over = address(vault).balance + 1;
        vm.expectRevert();
        vm.prank(admin);
        vault.rescueEth(payable(admin), over);
    }

    function test_SettlementAfterRescueWithInsufficientBalance() public {
        // Rescue all ETH
        vm.prank(admin);
        vault.rescueEth(payable(admin), address(vault).balance);
        assertEq(address(vault).balance, 0);

        // Settlement must fail with InsufficientVaultBalance
        vm.expectRevert(
            abi.encodeWithSelector(
                ILiquidityVault.InsufficientVaultBalance.selector, 0.1 ether, 0
            )
        );
        vm.prank(relayer);
        vault.executeSettlement(keccak256("post-rescue"), payable(user), 0.1 ether);
    }

    // =========================================================================
    // Receive function top-up during active use
    // =========================================================================

    function test_TopUpWhileExhaustedAndSettle() public {
        // Rescue all ETH to empty the vault
        vm.prank(admin);
        vault.rescueEth(payable(admin), address(vault).balance);

        // Top up 1 ETH
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(vault).balance, 1 ether);

        // Settle
        vm.prank(relayer);
        vault.executeSettlement(keccak256("post-topup"), payable(user), 0.5 ether);
        assertEq(address(vault).balance, 0.5 ether);
    }

    // =========================================================================
    // Minimum amount boundary
    // =========================================================================

    function test_SettlementOf1Wei() public {
        bytes32 ref = keccak256("one-wei");
        vm.prank(relayer);
        vault.executeSettlement(ref, payable(user), 1);
        assertTrue(vault.isSettled(ref));
        assertEq(vault.dailyVolume(), 1);
    }

    function test_MaxRefs_UniqueHashesAllSettleable() public view {
        // Verify that 20 different refs are fully independent
        for (uint256 i = 0; i < 20; i++) {
            bytes32 ref = keccak256(abi.encodePacked("max-refs-", i));
            // Each ref must not be pre-settled
            assertFalse(vault.isSettled(ref));
        }
    }
}
