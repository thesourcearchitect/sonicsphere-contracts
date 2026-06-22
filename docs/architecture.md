# Architecture — SonicSphere (Phase 1 & Phase 2)

## Overview

SonicSphere enables fiat-to-Web3 settlement: a user pays in fiat (card, bank transfer, etc.) and receives native ETH on Base. The on-chain component is deliberately minimal — a single `LiquidityVault.sol` contract that holds pooled ETH and releases it when a trusted off-chain relayer presents a valid settlement reference.

```
                    +-------------------+
   Fiat payment --->|  Payment Gateway  |  (Stripe / Adyen / etc.)
                    +-------------------+
                             |
                             | webhook / event
                             v
                    +-------------------+
                    |   KMS Relayer     |  (off-chain, private repo)
                    |  (RELAYER_ROLE)   |
                    +-------------------+
                             |
                             | executeSettlement(ref, recipient, amount)
                             v
                    +-------------------+
                    |  LiquidityVault   |  (on-chain, Base)
                    |  (this repo)      |
                    +-------------------+
                             |
                             | ETH transfer
                             v
                    +-------------------+
                    |   User Wallet     |
                    +-------------------+
```

---

## Contract design

### Why a single contract?

The Phase 1 scope is narrow: receive ETH (pooled liquidity), and pay it out one settlement at a time. A single contract minimises:
- Attack surface (no cross-contract calls in the hot path)
- Deployment complexity (one address to verify and monitor)
- Gas overhead (no proxy, no delegate-call indirection)

### Why non-upgradeable?

Upgradeability requires either a proxy pattern (delegatecall complexity) or a beacon/UUPS pattern (admin-key risk). For a financial settlement contract, the risk of a compromised upgrade key is worse than the inconvenience of redeployment. If a critical bug is found, a new vault is deployed and liquidity migrated under admin control.

### Why OpenZeppelin base contracts?

`AccessControl`, `Pausable`, and `ReentrancyGuard` are battle-tested, audited, and well-understood by the Solidity community. Rolling custom implementations would introduce unnecessary risk.

---

## Storage layout

```
slot 0:  _roles (AccessControl internal mapping — OZ layout)
...
slot n:  _settled      (bytes32 => bool) — idempotency registry
slot n+1: _cancelled   (bytes32 => bool) — guardian cancel registry
slot n+2: _paused      (bool)            — from Pausable
slot n+3: _status      (uint256)         — reentrancy guard status
slot n+4: txLimit      (uint256)         — per-tx cap (wei)
slot n+5: dailyCap     (uint256)         — 24h cap (wei)
slot n+6: dailyVolume  (uint256)         — accumulated volume in window
slot n+7: dailyWindowEnd (uint256)       — timestamp of current window end
```

Run `make storage` to get the exact Foundry-generated layout.

---

## Settlement execution flow

```
executeSettlement(ref, recipient, amount)
│
├─ [1] onlyRole(RELAYER_ROLE)             <- access control
├─ [2] whenNotPaused                      <- emergency brake
├─ [3] nonReentrant                       <- reentrancy lock
│
├─ [4] require ref != bytes32(0)          <- sanity
├─ [5] require amount > 0                 <- sanity
├─ [6] require recipient != address(0)    <- sanity
│
├─ [7] require !_cancelled[ref]           <- guardian veto check
├─ [8] require !_settled[ref]             <- idempotency check
│
├─ [9] require amount <= txLimit          <- per-tx cap
├─ [10] _resetWindowIfExpired()           <- lazy window reset
├─ [11] require dailyVolume+amount <= dailyCap  <- daily cap
├─ [12] require address(this).balance >= amount <- liquidity check
│
├─ [13] _settled[ref] = true              <- EFFECT: mark settled
├─ [14] dailyVolume += amount             <- EFFECT: accumulate volume
│
└─ [15] (bool ok,) = recipient.call{value:amount}("")   <- INTERACT
         ├─ ok == true  -> emit SettlementExecuted(ref, recipient, amount)
         └─ ok == false -> revert TransferFailed(recipient, amount)
                           (all state changes revert with the tx)
```

Steps 13-14 precede step 15 (CEI pattern). If step 15 fails, EVM reverts all changes from steps 13 and 14 — the ref is never marked settled and the volume is never accumulated.

---

## Daily rolling cap: lazy reset

The daily cap window is not time-locked. Instead, the first `executeSettlement` call after `dailyWindowEnd` triggers a lazy reset:

```solidity
function _resetWindowIfExpired() internal {
    if (block.timestamp >= dailyWindowEnd) {
        dailyVolume    = 0;
        dailyWindowEnd = block.timestamp + 1 days;
    }
}
```

**Why lazy?** On-chain cron jobs don't exist. A keeper/bot that calls a reset function would add operational complexity and attack surface. Lazy reset is atomic, gas-efficient, and requires no external trigger.

**Edge case: multiple expired windows.** If the vault is inactive for 3 days, the first settlement after re-activation resets the window to `now + 1 day` — not to `expiry + 1 day`. This is intentional: stale windows don't carry forward credit.

---

## Role model rationale

### Why three roles (not two)?

Separating `GUARDIAN_ROLE` from `DEFAULT_ADMIN_ROLE` limits blast radius:

| Scenario | GUARDIAN can handle | ADMIN needed? |
|---|---|---|
| Suspicious relayer activity | pause, cancel refs, reduce cap | No |
| Compromised relayer key | pause, cancel refs, reduce cap to 0 | Only for role revoke |
| Found contract bug | pause | Yes (for rescue + migration) |
| Routine parameter adjustment | setTxLimit, setDailyCap | No |

A two-role model (RELAYER + ADMIN) would require the multisig to sign every routine parameter change, slowing operations. A single-role model is too coarse.

### Why is RELAYER_ROLE isolated?

If the KMS relayer key is compromised, the attacker can only call `executeSettlement`. They cannot:
- Change risk parameters (no GUARDIAN_ROLE)
- Pause the vault (no GUARDIAN_ROLE)
- Rescue ETH (no DEFAULT_ADMIN_ROLE)
- Grant themselves a higher role (no DEFAULT_ADMIN_ROLE)

Maximum damage: `txLimit` ETH per transaction, `dailyCap` ETH per 24 hours — bounded by the risk parameters set by the guardian.

---

## Gas profile (selected operations)

| Operation | Gas (approx) |
|---|---|
| `executeSettlement` (warm, no window reset) | ~55,000 |
| `executeSettlement` (warm, with window reset) | ~60,000 |
| `executeSettlement` (cold first call) | ~75,000 |
| `pause()` | ~25,000 |
| `cancelSettlement()` | ~25,000 |
| `setTxLimit()` | ~22,000 |

Run `make test-gas` for the current full gas report.

---

## Phase 2 — ERC-4337 settlement account

Phase 2 introduces `ProtocolAccount.sol`, a minimal ERC-4337 v0.7 smart account that holds the Vault's `RELAYER_ROLE`. **The Phase 1 Vault is unchanged**; the account is integrated solely by a role grant.

### Why account abstraction for the relayer?

The off-chain KMS relayer previously had to be an EOA that managed its own gas and nonce. Routing settlements through a smart account + the canonical EntryPoint:
- Separates the **signing** key (KMS) from on-chain gas/nonce bookkeeping (the EntryPoint handles nonces, prefund and batching).
- Gives the relayer a single, auditable on-chain identity whose authorization on the Vault can be rotated without changing the Vault.
- Keeps the hot path's authorization model intact: the account is just another `RELAYER_ROLE` holder, bounded by the same `txLimit` / `dailyCap`.

### Minimal-surface design

`ProtocolAccount` extends eth-infinitism's audited `BaseAccount` and overrides only `_validateSignature`:
- One immutable signer (`kmsSigner`, a public address). No factory, proxy, or owner machinery — there is exactly one account.
- `execute(dest, value, func)` is callable **only** by the EntryPoint and bubbles the target's revert verbatim, so the Vault's idempotency/cap/pause errors remain legible to the off-chain reconciler.
- The contract is non-custodial: it never holds or requests any user key.

### Validation & replay safety

`_validateSignature` recovers the signer from `userOpHash` (which the EntryPoint already binds to the chain id and its own address), so a signed op cannot be replayed on another chain or EntryPoint. A wrong signer returns the AA `SIG_VALIDATION_FAILED` sentinel (no revert), as required for clean bundler simulation.

### Key rotation = redeploy

`kmsSigner` is immutable. Rotating the KMS key means deploying a fresh `ProtocolAccount` and, under `DEFAULT_ADMIN_ROLE` (timelock/multisig — never the KMS key), granting `RELAYER_ROLE` to the new account and revoking the old one. This mirrors the Phase 1 "redeploy rather than upgrade" philosophy.

### Staged testing & the bundler caveat

Tests run in stages: (1) local-EntryPoint unit tests, (2) a fork test against the real EntryPoint singleton, (3) bundler-in-the-loop (external infra), (4) testnet deploy. Stages 1–2 drive `handleOps()` directly and therefore **skip the ERC-7562 op-validation rules** a real bundler enforces — a green local run is necessary but not sufficient for bundler acceptance; stage 3 closes that gap.

---

## Later phases — ERC-20 support (out of scope here)

A later phase will add ERC-20 support (USDC, ETH-pegged stablecoins). Key decisions deferred:
- Whether to use a single vault with a token whitelist or separate per-token vaults
- Whether to add a fee capture mechanism
- Whether to introduce a Chainlink price feed for fiat-to-token conversion
- Whether to use OpenZeppelin's `SafeERC20` (expected: yes)

The Phase 1 contract is intentionally incompatible with the ERC-20 logic. A new contract will be deployed rather than upgrading.
