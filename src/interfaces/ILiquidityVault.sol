// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @title ILiquidityVault
/// @notice Interface for the SonicSphere fiat-to-Web3 liquidity bridge vault.
/// @dev Defines the external surface for the relayer, governance admin, and
///      ERC-4337 EntryPoint v0.7 coordination. Phase 1: native ETH only.
interface ILiquidityVault {

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a settlement is successfully executed.
    /// @param settlementRef  Unique reference hash identifying this payout.
    /// @param recipient      Address that received the funds.
    /// @param amount         Native ETH amount transferred (in wei).
    /// @param relayer        Address of the relayer that submitted the call.
    event SettlementExecuted(
        bytes32 indexed settlementRef,
        address indexed recipient,
        uint256 amount,
        address indexed relayer
    );

    /// @notice Emitted when a settlement reference is cancelled by governance.
    /// @param settlementRef  The reference hash that was voided.
    event SettlementCancelled(bytes32 indexed settlementRef);

    /// @notice Emitted when the vault receives a top-up deposit.
    /// @param sender   Address that sent the ETH.
    /// @param amount   Amount deposited (in wei).
    event VaultFunded(address indexed sender, uint256 amount);

    /// @notice Emitted when the daily volume cap is updated.
    /// @param oldCap  Previous cap value (in wei).
    /// @param newCap  New cap value (in wei).
    event DailyCapUpdated(uint256 oldCap, uint256 newCap);

    /// @notice Emitted when the per-release transaction limit is updated.
    /// @param oldLimit  Previous limit (in wei).
    /// @param newLimit  New limit (in wei).
    event TxLimitUpdated(uint256 oldLimit, uint256 newLimit);

    /// @notice Emitted when the vault is paused.
    event VaultPaused(address indexed guardian);

    /// @notice Emitted when the vault is unpaused.
    event VaultUnpaused(address indexed guardian);

    /// @notice Emitted when ETH is rescued by governance.
    /// @param to      Destination address.
    /// @param amount  Amount rescued (in wei).
    event EthRescued(address indexed to, uint256 amount);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when a settlement reference has already been processed.
    error AlreadySettled(bytes32 settlementRef);

    /// @notice Thrown when a settlement reference has been cancelled.
    error SettlementRefCancelled(bytes32 settlementRef);

    /// @notice Thrown when the requested amount exceeds the per-tx limit.
    error ExceedsTxLimit(uint256 requested, uint256 limit);

    /// @notice Thrown when the requested amount would breach the daily volume cap.
    error ExceedsDailyCap(uint256 requested, uint256 remaining);

    /// @notice Thrown when the vault has insufficient ETH balance.
    error InsufficientVaultBalance(uint256 requested, uint256 available);

    /// @notice Thrown when the native ETH transfer to the recipient fails.
    error TransferFailed(address recipient, uint256 amount);

    /// @notice Thrown when an invalid (zero) recipient address is provided.
    error InvalidRecipient();

    /// @notice Thrown when an invalid (zero) amount is provided.
    error InvalidAmount();

    /// @notice Thrown when an invalid (zero-bytes) settlementRef is provided.
    error InvalidSettlementRef();

    // -------------------------------------------------------------------------
    // Relayer-facing functions
    // -------------------------------------------------------------------------

    /// @notice Execute a single native ETH payout identified by a unique reference.
    /// @dev    Only callable by addresses holding RELAYER_ROLE.
    ///         Enforces idempotency (each settlementRef processed exactly once),
    ///         per-tx limit, and daily rolling volume cap.
    /// @param settlementRef  Off-chain unique hash (e.g. keccak256 of fiat txID).
    /// @param recipient      EOA or smart account receiving the ETH.
    /// @param amount         ETH amount to release (in wei).
    function executeSettlement(
        bytes32 settlementRef,
        address payable recipient,
        uint256 amount
    ) external;

    /// @notice Returns whether a given settlementRef has already been processed.
    /// @param settlementRef  The reference hash to query.
    /// @return settled       True if the ref was successfully executed.
    function isSettled(bytes32 settlementRef) external view returns (bool settled);

    // -------------------------------------------------------------------------
    // Governance / Guardian functions
    // -------------------------------------------------------------------------

    /// @notice Cancel a pending settlementRef to prevent future execution.
    /// @dev    Only callable by addresses holding GUARDIAN_ROLE.
    ///         Does not reverse a ref that has already been executed.
    /// @param settlementRef  The reference hash to void.
    function cancelSettlement(bytes32 settlementRef) external;

    /// @notice Update the per-transaction release limit.
    /// @dev    Only callable by addresses holding GUARDIAN_ROLE.
    /// @param newLimit  New maximum ETH per single settlement (in wei).
    function setTxLimit(uint256 newLimit) external;

    /// @notice Update the rolling 24-hour volume cap.
    /// @dev    Only callable by addresses holding GUARDIAN_ROLE.
    /// @param newCap  New maximum ETH releasable within any 24-hour window (in wei).
    function setDailyCap(uint256 newCap) external;

    /// @notice Pause the vault, halting all settlement execution.
    /// @dev    Only callable by addresses holding GUARDIAN_ROLE or DEFAULT_ADMIN_ROLE.
    function pause() external;

    /// @notice Unpause the vault, resuming settlement execution.
    /// @dev    Only callable by addresses holding GUARDIAN_ROLE or DEFAULT_ADMIN_ROLE.
    function unpause() external;

    /// @notice Emergency ETH rescue — sweeps ETH to a target address.
    /// @dev    Only callable by addresses holding DEFAULT_ADMIN_ROLE.
    ///         Intended for catastrophic key-compromise recovery only.
    /// @param to      Destination for rescued ETH.
    /// @param amount  Amount to rescue (in wei).
    function rescueEth(address payable to, uint256 amount) external;

    // -------------------------------------------------------------------------
    // View helpers
    // -------------------------------------------------------------------------

    /// @notice Returns the current per-transaction ETH release limit (in wei).
    function txLimit() external view returns (uint256);

    /// @notice Returns the current rolling 24-hour volume cap (in wei).
    function dailyCap() external view returns (uint256);

    /// @notice Returns the cumulative ETH released in the current 24-hour window.
    function dailyVolume() external view returns (uint256);

    /// @notice Returns the timestamp at which the current daily window resets.
    function dailyWindowEnd() external view returns (uint256);

    /// @notice Returns the current ETH balance held by the vault (in wei).
    function vaultBalance() external view returns (uint256);
}
