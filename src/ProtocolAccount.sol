// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {BaseAccount}          from "@account-abstraction/contracts/core/BaseAccount.sol";
import {PackedUserOperation}  from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {IEntryPoint}          from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {SIG_VALIDATION_FAILED, SIG_VALIDATION_SUCCESS}
    from "@account-abstraction/contracts/core/Helpers.sol";

import {ECDSA}            from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title  ProtocolAccount
/// @author SonicSphere
/// @notice Phase 2 — minimal hardened ERC-4337 v0.7 smart account for the
///         SonicSphere fiat-to-Web3 settlement bridge.
/// @dev    Design (see handoff brief §4):
///
///         • Extends the audited eth-infinitism `BaseAccount`; overrides ONLY
///           `_validateSignature`, inheriting the battle-tested EntryPoint guard,
///           nonce handling and prefund logic.
///         • Exactly ONE automated signer (the relayer's KMS owner key). No
///           threshold/owner machinery, no factory and no proxy — there is a
///           single account, so it is deployed directly with immutables.
///         • `kmsSigner` is immutable: KEY ROTATION = REDEPLOY. Deploy a fresh
///           ProtocolAccount, then on the Vault grant RELAYER_ROLE to the new
///           account and revoke it from the old one via DEFAULT_ADMIN_ROLE
///           (a timelock/multisig — NEVER the KMS key).
///
///         Wiring to Phase 1: the deployed LiquidityVault grants its
///         `RELAYER_ROLE` to this account's address. The relayer drives the
///         account through the EntryPoint with a UserOperation whose callData is
///         `execute(vault, 0, executeSettlement(ref, recipient, amount))`.
///
///         Non-custodial: this contract never holds, requests or stores any
///         user private key or seed phrase. `signer` is a PUBLIC address only.
contract ProtocolAccount is BaseAccount {
    using ECDSA            for bytes32;
    using MessageHashUtils for bytes32;

    /// @notice The canonical ERC-4337 v0.7 EntryPoint this account trusts.
    IEntryPoint private immutable _entryPoint;

    /// @notice Public address of the relayer's KMS owner key.
    /// @dev    Immutable — distinct from any paymaster-verifying key. Rotate by
    ///         redeploying the account (there is intentionally no setter).
    address public immutable kmsSigner;

    /// @param ep     Canonical EntryPoint v0.7 singleton
    ///               (0x0000000071727De22E5E9d8BAf0edAc6f37da032 on Base + Base Sepolia).
    /// @param signer Public address of the KMS owner key (NEVER a private key).
    constructor(IEntryPoint ep, address signer) {
        require(address(ep) != address(0), "PA: zero entryPoint");
        require(signer      != address(0), "PA: zero signer");
        _entryPoint = ep;
        kmsSigner   = signer;
    }

    /// @inheritdoc BaseAccount
    function entryPoint() public view override returns (IEntryPoint) {
        return _entryPoint;
    }

    /// @notice Validate that a UserOperation was signed by the KMS owner key.
    /// @dev    `userOpHash` already binds the chainId and the EntryPoint address,
    ///         so a signature is not replayable across chains or EntryPoints.
    ///         Returns the AA sentinel values (no revert) so the EntryPoint can
    ///         surface signature failures cleanly during simulation.
    function _validateSignature(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    )
        internal
        view
        override
        returns (uint256)
    {
        // `tryRecover` (not `recover`) so a MALFORMED signature returns the AA
        // sentinel rather than reverting: a revert inside validation surfaces as
        // an AA23 error and breaks clean bundler simulation. On any recover
        // error `recovered` is address(0), which never equals the non-zero
        // `kmsSigner`, so it correctly maps to SIG_VALIDATION_FAILED.
        (address recovered, , ) = userOpHash.toEthSignedMessageHash().tryRecover(userOp.signature);
        if (recovered != kmsSigner) {
            return SIG_VALIDATION_FAILED;
        }
        return SIG_VALIDATION_SUCCESS; // 0
    }

    /// @notice Execute a single call from the account. EntryPoint-only.
    /// @dev    Bubbles the inner revert verbatim so the LiquidityVault's
    ///         idempotency / cap / pause reverts stay legible to the off-chain
    ///         reconciler (handoff brief §6). For settlements `value` is 0 — the
    ///         Vault releases its own ETH; the account holds none.
    /// @param dest   Target contract (the LiquidityVault for settlements).
    /// @param value  Wei to forward from the account's own balance (0 for settlements).
    /// @param func   Encoded calldata for the target (e.g. `executeSettlement(...)`).
    function execute(address dest, uint256 value, bytes calldata func) external {
        _requireFromEntryPoint();
        (bool ok, bytes memory ret) = dest.call{value: value}(func);
        if (!ok) {
            // bubble the original revert reason
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// @notice Accept ETH (e.g. to top up the account's EntryPoint prefund path).
    receive() external payable {}
}
