# Security Policy

## Scope

This repository contains the on-chain smart contract layer of the SonicSphere fiat-to-Web3 liquidity bridge. Vulnerabilities in the following files are in scope for responsible disclosure:

| File | Description |
|---|---|
| `src/LiquidityVault.sol` | Core settlement vault |
| `src/interfaces/ILiquidityVault.sol` | External ABI |
| `script/Deploy.s.sol` | Deployment script |
| `script/VerifyDeployment.s.sol` | Post-deployment verification |

**Out of scope:**
- Off-chain KMS relayer infrastructure (private repository)
- Frontend / dashboard (private repository)
- Theoretical attacks that require compromising `DEFAULT_ADMIN_ROLE` (treated as a trusted multisig)
- Gas optimisation suggestions (use GitHub Issues instead)
- Third-party library vulnerabilities in `lib/` (report upstream)

---

## Severity Classification

| Severity | Description |
|---|---|
| **Critical** | Direct loss of funds, bypass of `settlementRef` idempotency, unauthorised role escalation |
| **High** | Denial-of-service on `executeSettlement`, permanent vault lock, risk-parameter bypass |
| **Medium** | Griefing, precision loss, event integrity issues |
| **Low** | Code quality, best-practice deviations, informational |

---

## Reporting a Vulnerability

**Do not open a public GitHub Issue for security vulnerabilities.**

Please report security vulnerabilities via **private disclosure only**:

1. Go to the repository's **Security** tab → **Report a vulnerability** (GitHub private advisory).
2. Include a clear description of the vulnerability, the affected contract and function, a proof-of-concept (Foundry test preferred), and your severity assessment.
3. We will acknowledge receipt within **48 hours** and aim to provide a remediation timeline within **5 business days**.

For urgent critical findings, include `[CRITICAL]` in the advisory title.

---

## Disclosure Policy

- We follow a **90-day coordinated disclosure** timeline from first report to public disclosure.
- We will credit researchers in the advisory (unless you request anonymity).
- We do not operate a paid bug bounty programme at this stage.

---

## Security Architecture

The vault is designed with defence-in-depth across multiple independent layers:

### On-chain controls

| Control | Mechanism |
|---|---|
| Double-spend prevention | `settlementRef` hash registry (bytes32 → bool), checked before any ETH transfer |
| Replay attack prevention | Same idempotency registry; cancelled refs are also blocked |
| Access control | OpenZeppelin `AccessControl` with three isolated roles |
| Per-tx exposure cap | `txLimit` (wei) enforced before every transfer |
| Daily rolling exposure cap | 24-hour `dailyCap` window with lazy reset |
| Reentrancy protection | OpenZeppelin `ReentrancyGuard` + CEI pattern in `executeSettlement` |
| Emergency halt | `pause()` / `unpause()` callable by `GUARDIAN_ROLE` |
| Emergency recovery | `rescueEth()` callable by `DEFAULT_ADMIN_ROLE` only |
| Transfer failure | Native `.call` return value checked; reverts with `TransferFailed` on failure |

### Role isolation

| Role | Can do | Cannot do |
|---|---|---|
| `RELAYER_ROLE` | `executeSettlement` | Pause, cancel refs, change risk params, rescue ETH |
| `GUARDIAN_ROLE` | Pause, cancel refs, `setTxLimit`, `setDailyCap` | Execute settlements, rescue ETH |
| `DEFAULT_ADMIN_ROLE` | Grant/revoke all roles, `rescueEth` | Execute settlements (directly) |

### Known limitations (by design)

- **Non-upgradeable** — the contract is intentionally immutable. A critical vulnerability requires deploying a new vault and migrating liquidity.
- **Native ETH only (Phase 1)** — no ERC-20 logic exists, minimising the attack surface.
- **Guardian can reduce `dailyCap` below accumulated `dailyVolume`** — this is intentional; it soft-blocks new settlements as an emergency throttle without requiring a pause.

---

## Audit Status

| Date | Auditor | Scope | Report |
|---|---|---|---|
| — | — | Pre-launch | Pending |

A formal third-party audit is planned prior to mainnet deployment and liquidity funding.
