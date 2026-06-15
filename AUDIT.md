# Audit Preparation — LiquidityVault

This document provides a structured reference for external auditors reviewing the SonicSphere Phase 1 smart contract. It covers scope, known design decisions, invariants the code is intended to uphold, and recommended audit focus areas.

---

## Repository structure

```
src/
  LiquidityVault.sol            <- sole auditable contract (252 lines)
  interfaces/
    ILiquidityVault.sol         <- full ABI (events, custom errors, functions)

script/
  Deploy.s.sol                  <- deployment constructor args
  VerifyDeployment.s.sol        <- post-deploy assertions
  SetRiskParams.s.sol           <- guardian parameter update
  EmergencyPause.s.sol          <- pause / unpause / status

test/
  LiquidityVault.t.sol          <- 48 unit + fuzz tests
  LiquidityVaultEdgeCases.t.sol <- 24 targeted edge-case tests
  LiquidityVaultInvariant.t.sol <- 8 stateful invariants (128k calls each)
  mocks/
    MockFailingReceiver.sol     <- ETH rejection mock
```

---

## Audit scope

| In scope | Out of scope |
|---|---|
| `src/LiquidityVault.sol` | Off-chain KMS relayer (private repo) |
| `src/interfaces/ILiquidityVault.sol` | Frontend / dashboard |
| `script/Deploy.s.sol` | `lib/` (report upstream) |
| All files in `script/` | Future Phase 2 ERC-20 logic |

---

## External dependencies

| Library | Version | Usage |
|---|---|---|
| `openzeppelin-contracts` | v5.6.1 | `AccessControl`, `Pausable`, `ReentrancyGuard` |
| `forge-std` | v1.16.1 | Test infrastructure only (not in production bytecode) |

No external protocol integrations, oracles, or price feeds are used.

---

## Constructor parameters

```solidity
constructor(
    address admin,      // receives DEFAULT_ADMIN_ROLE
    address guardian,   // receives GUARDIAN_ROLE
    address relayer,    // receives RELAYER_ROLE
    uint256 txLimit,    // per-tx ETH cap (wei), must be > 0
    uint256 dailyCap    // 24h rolling ETH cap (wei), must be >= txLimit
)
```

None of the addresses are validated beyond the zero-address check. The deployer is responsible for ensuring correct role separation.

---

## Intended invariants

The following properties must hold at all times. The invariant test suite (`LiquidityVaultInvariant.t.sol`) verifies these across 128,000 randomised calls each:

| ID | Invariant |
|---|---|
| I1 | `address(vault).balance >= 0` (ETH is never spontaneously created) |
| I2 | A `settlementRef` can only be marked settled once |
| I3 | A cancelled `settlementRef` can never be executed |
| I4 | `dailyVolume` never exceeds `dailyCap` at the moment of any `executeSettlement` call |
| I5 | `txLimit` is always > 0 |
| I6 | `dailyCap` is always >= `txLimit` |
| I7 | A paused vault cannot execute settlements |
| I8 | `vaultBalance()` always equals `address(vault).balance` |

---

## Security properties and rationale

### Double-spend prevention

`settlementRef` hashes are stored in `_settled` (bytes32 => bool) before the ETH transfer. The settlement check comes before any state change (CEI). A ref that is marked settled can never pass the `if (_settled[ref]) revert AlreadySettled(ref)` guard again.

### Cancelled ref isolation

Cancelled refs are tracked in a separate mapping `_cancelled`. The guard checks both mappings:
1. Is it cancelled? Revert immediately.
2. Is it already settled? Revert.
Only then does execution proceed.

### CEI compliance

In `executeSettlement`, the order is:
1. Check role, params, balance, idempotency
2. Effect: `_settled[ref] = true`, `dailyVolume += amount`
3. Interact: `.call{value: amount}(recipient)`

If the `.call` fails, the entire transaction reverts, unwinding both state changes.

### Reentrancy

`ReentrancyGuard` (`nonReentrant` modifier) prevents reentrant calls. Combined with CEI, even a malicious recipient contract that calls back into `executeSettlement` during the `.call` will be blocked by both the reentrancy lock and the settled-ref check.

### Daily cap window reset

The window resets lazily on the first settlement after `dailyWindowEnd`. This means a window that has expired but hasn't been reset yet does not accumulate volume from the previous window. A new window always starts fresh at `volume = 0`.

### Risk parameter safety

`setTxLimit` enforces `txLimit <= dailyCap` (reverts otherwise). `setDailyCap` enforces `dailyCap >= txLimit`. These together ensure the invariant `txLimit <= dailyCap` is never violated. However, the guardian may reduce `dailyCap` below the current `dailyVolume` — this is intentional (it soft-blocks new settlements without requiring a full pause).

---

## Known limitations / out-of-scope risks

| Item | Notes |
|---|---|
| No upgradeability | Intentional. A critical vulnerability requires a new deployment and liquidity migration. |
| Guardian private key compromise | Guardian can pause and change risk params, but cannot steal funds. Only `DEFAULT_ADMIN_ROLE` can `rescueEth`. |
| Relayer private key compromise | Attacker bounded by `txLimit` per tx and `dailyCap` per 24h. Guardian can pause immediately. |
| Admin private key compromise | Admin can `rescueEth` all funds. Intended to be a hardware-wallet multisig. |
| 24h window manipulation | `block.timestamp` used for the window. Validator manipulation is bounded to ~15 seconds on Base and cannot meaningfully affect the 24-hour window. |
| ETH sent directly to vault | The `receive()` function accepts ETH to enable liquidity top-up. Emits `VaultFunded` event. No accounting risk since vault balance is tracked via `address(this).balance`. |

---

## Recommended audit focus areas

1. **Idempotency registry** — confirm `_settled` and `_cancelled` mappings cannot be bypassed in any call sequence.
2. **CEI ordering** — verify that no state read or write after the `.call` can create a reentrancy path.
3. **Daily cap window arithmetic** — look for off-by-one errors at `dailyWindowEnd` boundary; confirm the lazy reset is safe across multiple expired windows.
4. **Role cross-contamination** — confirm that no action available to `RELAYER_ROLE` or `GUARDIAN_ROLE` allows escalation to `DEFAULT_ADMIN_ROLE` powers.
5. **`rescueEth` access** — confirm that only `DEFAULT_ADMIN_ROLE` can call it, and that it cannot leave the vault in a state that silently breaks future settlements.
6. **Transfer failure handling** — verify the `TransferFailed` revert path correctly unwinds all state changes and leaves the ref re-settleable.
7. **Constructor zero-address checks** — confirm no role is granted to `address(0)`.
8. **`setTxLimit` / `setDailyCap` ordering** — if both are being updated, confirm no intermediate invalid state is reachable within a single block.

---

## Test coverage baseline

Run before starting the review to establish a baseline:

```bash
# Install Foundry 1.7+
git clone --recurse-submodules https://github.com/thesourcearchitect/sonicsphere-contracts
cd sonicsphere-contracts
forge test                              # should be 80/80 passing
forge coverage --report summary         # should show 100% lines/statements/functions
forge snapshot --check                  # should pass with no gas regression
```

---

## Contact

For questions during the audit, use GitHub Security Advisories (private channel). See [SECURITY.md](./SECURITY.md).
