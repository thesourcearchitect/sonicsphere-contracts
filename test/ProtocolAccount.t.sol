// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";

import {EntryPoint}          from "@account-abstraction/contracts/core/EntryPoint.sol";
import {IEntryPoint}         from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {MessageHashUtils}    from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {ProtocolAccount} from "../src/ProtocolAccount.sol";
import {LiquidityVault}  from "../src/LiquidityVault.sol";
import {ILiquidityVault} from "../src/interfaces/ILiquidityVault.sol";

/// @notice Stage-1 unit tests for ProtocolAccount (Phase 2).
/// @dev    Deploys a local EntryPoint v0.7 in setUp() and drives handleOps
///         directly. NOTE (brief §7): forge calls handleOps() directly and so
///         SKIPS the ERC-7562 bundler rules — a green run here does NOT prove a
///         real bundler will accept the op. That is covered by the staged
///         bundler-in-the-loop tests, not these.
contract ProtocolAccountTest is Test {
    // KMS owner key (test only). kmsSigner = vm.addr(KMS_PK).
    uint256 internal constant KMS_PK = 0xA11CE;

    // Generous gas limits — execution is effectively free here (gasFees = 0).
    uint128 internal constant VERIF_GAS     = 600_000;
    uint128 internal constant CALL_GAS      = 600_000;
    uint256 internal constant PRE_VERIF_GAS = 100_000;

    EntryPoint      internal entryPoint;
    ProtocolAccount internal account;
    LiquidityVault  internal vault;

    address internal kmsSigner;
    address internal admin;
    address internal guardian;
    address internal placeholderRelayer;
    address internal recipient;
    address payable internal beneficiary;

    function setUp() public {
        kmsSigner          = vm.addr(KMS_PK);
        admin              = makeAddr("admin");
        guardian           = makeAddr("guardian");
        placeholderRelayer = makeAddr("placeholderRelayer");
        recipient          = makeAddr("recipient");
        beneficiary        = payable(makeAddr("beneficiary"));

        entryPoint = new EntryPoint();
        account    = new ProtocolAccount(IEntryPoint(address(entryPoint)), kmsSigner);

        // Phase-1 vault deployed with a PLACEHOLDER relayer, then rewired to the
        // ProtocolAccount via DEFAULT_ADMIN_ROLE (mirrors the GrantRelayer script).
        vault = new LiquidityVault(admin, guardian, placeholderRelayer, 0.1 ether, 1 ether);
        vm.startPrank(admin);
        vault.grantRole(vault.RELAYER_ROLE(), address(account));
        vault.revokeRole(vault.RELAYER_ROLE(), placeholderRelayer);
        vm.stopPrank();

        // Fund the vault so it can release ETH.
        vm.deal(address(vault), 10 ether);
    }

    // ------------------------------------------------------------------------
    // Wiring / immutables
    // ------------------------------------------------------------------------

    function test_Wiring_ImmutablesAndRole() public view {
        assertEq(address(account.entryPoint()), address(entryPoint), "entryPoint mismatch");
        assertEq(account.kmsSigner(), kmsSigner, "kmsSigner mismatch");
        assertTrue(vault.hasRole(vault.RELAYER_ROLE(), address(account)), "account missing RELAYER_ROLE");
        assertFalse(
            vault.hasRole(vault.RELAYER_ROLE(), placeholderRelayer),
            "placeholder still has RELAYER_ROLE"
        );
    }

    // ------------------------------------------------------------------------
    // _validateSignature (via validateUserOp, EntryPoint-pranked)
    // ------------------------------------------------------------------------

    function test_ValidateSignature_ValidSigner_Succeeds() public {
        PackedUserOperation memory op = _buildOp("");
        bytes32 opHash = entryPoint.getUserOpHash(op);
        op.signature = _sign(KMS_PK, opHash);

        vm.prank(address(entryPoint));
        uint256 vd = account.validateUserOp(op, opHash, 0);
        assertEq(vd, 0, "valid signer should return SIG_VALIDATION_SUCCESS");
    }

    function test_ValidateSignature_WrongSigner_Fails() public {
        uint256 wrongPk = 0xB0B;
        PackedUserOperation memory op = _buildOp("");
        bytes32 opHash = entryPoint.getUserOpHash(op);
        op.signature = _sign(wrongPk, opHash);

        vm.prank(address(entryPoint));
        uint256 vd = account.validateUserOp(op, opHash, 0);
        assertEq(vd, 1, "wrong signer should return SIG_VALIDATION_FAILED");
    }

    function test_ValidateSignature_MalformedSignature_Fails() public {
        PackedUserOperation memory op = _buildOp("");
        bytes32 opHash = entryPoint.getUserOpHash(op);
        // Garbage signature of the wrong length: tryRecover must NOT revert,
        // it must map cleanly to SIG_VALIDATION_FAILED (clean bundler sim).
        op.signature = hex"deadbeef";

        vm.prank(address(entryPoint));
        uint256 vd = account.validateUserOp(op, opHash, 0);
        assertEq(vd, 1, "malformed signature should return SIG_VALIDATION_FAILED");
    }

    // ------------------------------------------------------------------------
    // execute() access control + revert bubbling
    // ------------------------------------------------------------------------

    function test_Execute_RevertsForNonEntryPoint() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(bytes("account: not from EntryPoint"));
        account.execute(address(vault), 0, "");
    }

    function test_Execute_BubblesVaultRevert() public {
        bytes32 ref = keccak256("dup-ref");
        uint256 amount = 0.01 ether;
        bytes memory inner =
            abi.encodeCall(ILiquidityVault.executeSettlement, (ref, payable(recipient), amount));

        vm.prank(address(entryPoint));
        account.execute(address(vault), 0, inner);
        assertTrue(vault.isSettled(ref), "first settlement should succeed");

        // Replay must bubble the vault's exact custom error through the account.
        vm.prank(address(entryPoint));
        vm.expectRevert(abi.encodeWithSelector(ILiquidityVault.AlreadySettled.selector, ref));
        account.execute(address(vault), 0, inner);
    }

    // ------------------------------------------------------------------------
    // Full pipeline: EntryPoint -> account.execute -> vault.executeSettlement
    // ------------------------------------------------------------------------

    function test_HandleOps_ReleasesFunds() public {
        bytes32 ref = keccak256("settle-1");
        uint256 amount = 0.05 ether;

        PackedUserOperation memory op = _settlementOp(ref, amount);
        op.signature = _sign(KMS_PK, entryPoint.getUserOpHash(op));

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;

        uint256 before = recipient.balance;
        entryPoint.handleOps(ops, beneficiary);

        assertEq(recipient.balance, before + amount, "recipient not paid");
        assertTrue(vault.isSettled(ref), "ref not marked settled");
    }

    function test_HandleOps_IdempotentReplay_NoDoublePay() public {
        bytes32 ref = keccak256("settle-2");
        uint256 amount = 0.05 ether;

        PackedUserOperation memory op1 = _settlementOp(ref, amount);
        op1.signature = _sign(KMS_PK, entryPoint.getUserOpHash(op1));
        PackedUserOperation[] memory ops1 = new PackedUserOperation[](1);
        ops1[0] = op1;
        entryPoint.handleOps(ops1, beneficiary);

        uint256 afterFirst = recipient.balance;
        assertEq(afterFirst, amount, "first settlement should pay once");

        // Same ref, fresh nonce. The vault reverts AlreadySettled in the
        // execution phase; the EntryPoint catches it (handleOps does NOT revert)
        // and no second payment is made.
        PackedUserOperation memory op2 = _settlementOp(ref, amount);
        op2.signature = _sign(KMS_PK, entryPoint.getUserOpHash(op2));
        PackedUserOperation[] memory ops2 = new PackedUserOperation[](1);
        ops2[0] = op2;
        entryPoint.handleOps(ops2, beneficiary);

        assertEq(recipient.balance, afterFirst, "double release occurred");
    }

    // ------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------

    function _settlementOp(bytes32 ref, uint256 amount)
        internal
        view
        returns (PackedUserOperation memory)
    {
        bytes memory inner =
            abi.encodeCall(ILiquidityVault.executeSettlement, (ref, payable(recipient), amount));
        bytes memory callData =
            abi.encodeCall(ProtocolAccount.execute, (address(vault), uint256(0), inner));
        return _buildOp(callData);
    }

    function _buildOp(bytes memory callData)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op = PackedUserOperation({
            sender:             address(account),
            nonce:              entryPoint.getNonce(address(account), 0),
            initCode:           "",
            callData:           callData,
            accountGasLimits:   _pack(VERIF_GAS, CALL_GAS),
            preVerificationGas: PRE_VERIF_GAS,
            gasFees:            bytes32(0), // maxPriorityFee = maxFee = 0 -> zero prefund
            paymasterAndData:   "",
            signature:          ""
        });
    }

    function _sign(uint256 pk, bytes32 opHash) internal pure returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(opHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _pack(uint128 hi, uint128 lo) internal pure returns (bytes32) {
        return bytes32((uint256(hi) << 128) | uint256(lo));
    }
}
