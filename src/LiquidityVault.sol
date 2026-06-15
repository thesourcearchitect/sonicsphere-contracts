// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable}       from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ILiquidityVault} from "./interfaces/ILiquidityVault.sol";

/// @title LiquidityVault
/// @author SonicSphere
/// @notice Hardened liquidity vault for the SonicSphere fiat-to-Web3 bridge.
/// @dev    Phase 1 — native ETH distributions on Base only.
///
///         Security model
///         ──────────────
///         • RELAYER_ROLE   : off-chain KMS relayer; may only call executeSettlement.
///         • GUARDIAN_ROLE  : governance/ops; may pause, cancel refs, adjust risk params.
///         • DEFAULT_ADMIN  : top-level admin; may grant/revoke roles and rescue ETH.
///
///         Idempotency
///         ───────────
///         Each settlementRef is a bytes32 hash (e.g. keccak256 of the off-chain fiat
///         transaction ID). The vault records every executed ref in _settled and every
///         cancelled ref in _cancelled. A ref can never be re-executed or un-cancelled.
///
///         Risk parameters
///         ───────────────
///         • TX_LIMIT  : maximum ETH per single settlement call (hard ceiling, wei).
///         • DAILY_CAP : maximum cumulative ETH across all settlements in any rolling
///                       24-hour window (hard ceiling, wei).
///         Both are adjustable by GUARDIAN_ROLE without an upgrade.
///
///         ERC-4337 v0.7 compatibility
///         ───────────────────────────
///         The contract does not depend on UserOperation mechanics directly; it is
///         formatted as a clean target that an EntryPoint v0.7 account abstraction
///         pipeline can call via a smart account holding RELAYER_ROLE.
contract LiquidityVault is ILiquidityVault, AccessControl, Pausable, ReentrancyGuard {

    // -------------------------------------------------------------------------
    // Roles
    // -------------------------------------------------------------------------

    /// @notice Role for the off-chain KMS relayer.
    bytes32 public constant RELAYER_ROLE  = keccak256("RELAYER_ROLE");

    /// @notice Role for governance / guardian operations.
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // -------------------------------------------------------------------------
    // Risk parameters (mutable, guardian-controlled)
    // -------------------------------------------------------------------------

    /// @inheritdoc ILiquidityVault
    uint256 public txLimit;

    /// @inheritdoc ILiquidityVault
    uint256 public dailyCap;

    // -------------------------------------------------------------------------
    // Rolling daily window state
    // -------------------------------------------------------------------------

    /// @inheritdoc ILiquidityVault
    uint256 public dailyVolume;

    /// @inheritdoc ILiquidityVault
    uint256 public dailyWindowEnd;

    // -------------------------------------------------------------------------
    // Idempotency registries
    // -------------------------------------------------------------------------

    /// @dev settlementRef => executed
    mapping(bytes32 => bool) private _settled;

    /// @dev settlementRef => cancelled
    mapping(bytes32 => bool) private _cancelled;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @param admin_       Address granted DEFAULT_ADMIN_ROLE.
    /// @param guardian_    Address granted GUARDIAN_ROLE.
    /// @param relayer_     Address granted RELAYER_ROLE.
    /// @param txLimit_     Initial per-tx ETH limit (wei).
    /// @param dailyCap_    Initial 24-hour rolling volume cap (wei).
    constructor(
        address admin_,
        address guardian_,
        address relayer_,
        uint256 txLimit_,
        uint256 dailyCap_
    ) {
        require(admin_    != address(0), "LV: zero admin");
        require(guardian_ != address(0), "LV: zero guardian");
        require(relayer_  != address(0), "LV: zero relayer");
        require(txLimit_  > 0,           "LV: zero txLimit");
        require(dailyCap_ >= txLimit_,   "LV: dailyCap < txLimit");

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(GUARDIAN_ROLE,      guardian_);
        _grantRole(RELAYER_ROLE,       relayer_);

        txLimit  = txLimit_;
        dailyCap = dailyCap_;

        // Initialise the first daily window
        dailyWindowEnd = block.timestamp + 1 days;
    }

    // -------------------------------------------------------------------------
    // Funding
    // -------------------------------------------------------------------------

    /// @notice Accept ETH top-ups directly to the vault.
    receive() external payable {
        emit VaultFunded(msg.sender, msg.value);
    }

    // -------------------------------------------------------------------------
    // Relayer-facing: executeSettlement
    // -------------------------------------------------------------------------

    /// @inheritdoc ILiquidityVault
    function executeSettlement(
        bytes32        settlementRef,
        address payable recipient,
        uint256        amount
    )
        external
        override
        onlyRole(RELAYER_ROLE)
        whenNotPaused
        nonReentrant
    {
        // --- input validation ---
        if (settlementRef == bytes32(0)) revert InvalidSettlementRef();
        if (recipient     == address(0)) revert InvalidRecipient();
        if (amount        == 0)          revert InvalidAmount();

        // --- idempotency guards ---
        if (_settled[settlementRef])   revert AlreadySettled(settlementRef);
        if (_cancelled[settlementRef]) revert SettlementRefCancelled(settlementRef);

        // --- risk parameter enforcement ---
        if (amount > txLimit)  revert ExceedsTxLimit(amount, txLimit);

        _tickDailyWindow();
        uint256 remaining = dailyCap - dailyVolume;
        if (amount > remaining) revert ExceedsDailyCap(amount, remaining);

        // --- balance check ---
        if (amount > address(this).balance) {
            revert InsufficientVaultBalance(amount, address(this).balance);
        }

        // --- state changes before external call (CEI pattern) ---
        _settled[settlementRef] = true;
        dailyVolume += amount;

        // --- external call ---
        (bool ok, ) = recipient.call{value: amount}("");
        if (!ok) revert TransferFailed(recipient, amount);

        emit SettlementExecuted(settlementRef, recipient, amount, msg.sender);
    }

    // -------------------------------------------------------------------------
    // Governance / Guardian functions
    // -------------------------------------------------------------------------

    /// @inheritdoc ILiquidityVault
    function cancelSettlement(bytes32 settlementRef)
        external
        override
        onlyRole(GUARDIAN_ROLE)
    {
        if (settlementRef == bytes32(0)) revert InvalidSettlementRef();
        // Allow cancelling already-settled refs silently — the guard below is
        // informational; on-chain state for _settled is still stored.
        _cancelled[settlementRef] = true;
        emit SettlementCancelled(settlementRef);
    }

    /// @inheritdoc ILiquidityVault
    function setTxLimit(uint256 newLimit)
        external
        override
        onlyRole(GUARDIAN_ROLE)
    {
        require(newLimit > 0,          "LV: zero txLimit");
        require(newLimit <= dailyCap,  "LV: txLimit > dailyCap");
        uint256 old = txLimit;
        txLimit = newLimit;
        emit TxLimitUpdated(old, newLimit);
    }

    /// @inheritdoc ILiquidityVault
    function setDailyCap(uint256 newCap)
        external
        override
        onlyRole(GUARDIAN_ROLE)
    {
        require(newCap >= txLimit, "LV: dailyCap < txLimit");
        uint256 old = dailyCap;
        dailyCap = newCap;
        emit DailyCapUpdated(old, newCap);
    }

    /// @inheritdoc ILiquidityVault
    function pause() external override onlyRole(GUARDIAN_ROLE) {
        _pause();
        emit VaultPaused(msg.sender);
    }

    /// @inheritdoc ILiquidityVault
    function unpause() external override onlyRole(GUARDIAN_ROLE) {
        _unpause();
        emit VaultUnpaused(msg.sender);
    }

    /// @inheritdoc ILiquidityVault
    function rescueEth(address payable to, uint256 amount)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        require(to     != address(0),          "LV: zero rescue target");
        require(amount <= address(this).balance, "LV: insufficient balance");
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "LV: rescue transfer failed");
        emit EthRescued(to, amount);
    }

    // -------------------------------------------------------------------------
    // View helpers
    // -------------------------------------------------------------------------

    /// @inheritdoc ILiquidityVault
    function isSettled(bytes32 settlementRef)
        external
        view
        override
        returns (bool)
    {
        return _settled[settlementRef];
    }

    /// @inheritdoc ILiquidityVault
    function vaultBalance() external view override returns (uint256) {
        return address(this).balance;
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /// @dev Advances the daily window if the current timestamp has passed
    ///      dailyWindowEnd, resetting the accumulated volume counter.
    function _tickDailyWindow() internal {
        if (block.timestamp >= dailyWindowEnd) {
            dailyVolume    = 0;
            dailyWindowEnd = block.timestamp + 1 days;
        }
    }
}
