# SonicSphere Contracts

> **Phase 1 — Native ETH Liquidity Vault** · **Phase 2 — ERC-4337 Settlement Account** · on Base

Isolated, auditable Foundry repository for the SonicSphere fiat-to-Web3 liquidity bridge settlement layer. This repository contains only the on-chain Solidity architecture; off-chain KMS relayer infrastructure lives in a separate private repository.

---

## Architecture

```
src/
├── interfaces/
│   └── ILiquidityVault.sol   <- full external ABI (events, errors, functions)
├── LiquidityVault.sol        <- Phase 1 implementation (UNCHANGED)
└── ProtocolAccount.sol       <- Phase 2 ERC-4337 v0.7 settlement account

script/
├── Deploy.s.sol                  <- Phase 1 initial deployment
├── VerifyDeployment.s.sol        <- Phase 1 post-deploy verification (5-group check)
├── SetRiskParams.s.sol           <- guardian: update txLimit / dailyCap
├── EmergencyPause.s.sol          <- guardian: pause / unpause / status
├── DeployProtocolAccount.s.sol   <- Phase 2: deploy the settlement account
└── GrantRelayer.s.sol            <- Phase 2: grant RELAYER_ROLE to the account

test/
├── LiquidityVault.t.sol          <- 48 unit + fuzz tests
├── LiquidityVaultEdgeCases.t.sol <- 24 edge-case tests
├── LiquidityVaultFork.t.sol      <- fork tests (skip without RPC)
├── LiquidityVaultInvariant.t.sol <- 8 stateful invariant tests
├── ProtocolAccount.t.sol         <- 7 Phase 2 unit tests (local EntryPoint)
├── ProtocolAccountFork.t.sol     <- 2 Phase 2 fork tests vs real EntryPoint (skip without RPC)
└── mocks/
    └── MockFailingReceiver.sol   <- revert/gas-burning ETH rejection mock

lib/
└── account-abstraction/          <- vendored eth-infinitism v0.7.0 (Phase 2)
```

### Settlement flow

```
Fiat payment event
      |
      | (off-chain KMS relayer)
      v
LiquidityVault.executeSettlement(ref, recipient, amount)
      |
      |-- [1] RELAYER_ROLE check
      |-- [2] ref not settled + not cancelled
      |-- [3] amount <= txLimit
      |-- [4] amount <= remainingDailyCap
      |-- [5] vault balance >= amount
      |-- [6] mark ref as settled   <-- state change before transfer (CEI)
      |-- [7] update dailyVolume    <-- state change before transfer (CEI)
      |-- [8] ETH .call transfer
      |         |-- success -> emit SettlementExecuted
      |         +-- failure -> revert TransferFailed (all state rolls back)
      v
User's wallet receives ETH
```

### Role model

| Role | Holder | Capabilities |
|---|---|---|
| `RELAYER_ROLE` | Off-chain KMS relayer | `executeSettlement` only |
| `GUARDIAN_ROLE` | Governance / ops | Pause, cancel refs, adjust risk parameters |
| `DEFAULT_ADMIN_ROLE` | Multisig / timelock | Grant/revoke roles, `rescueEth` |

### Idempotency

Each `settlementRef` is a `bytes32` hash (e.g. `keccak256` of the off-chain fiat transaction ID). The vault stores every executed ref and every cancelled ref independently. A ref can never be re-executed or un-cancelled — double-spend and replay attacks are blocked natively at the contract level.

### Risk parameters

Both parameters are mutable by `GUARDIAN_ROLE` without an upgrade:

- **`txLimit`** — maximum ETH (wei) releasable in a single `executeSettlement` call.
- **`dailyCap`** — maximum cumulative ETH (wei) releasable across all settlements in any rolling 24-hour window. The window resets lazily on the first settlement after it expires.

---

## Phase 2 — ERC-4337 Settlement Account

Phase 2 adds `ProtocolAccount.sol`, a minimal, hardened [ERC-4337](https://eips.ethereum.org/EIPS/eip-4337) v0.7 smart account that becomes the Vault's relayer. **Phase 1 is unchanged** — the account is wired in purely by granting it the existing `RELAYER_ROLE`.

### Why

The off-chain KMS relayer no longer calls the Vault as a plain EOA. Instead it signs an ERC-4337 **UserOperation** with its KMS key and submits it to the canonical **EntryPoint**, which drives the account. This separates the relayer's signing key from on-chain gas/nonce management and gives a single, auditable on-chain identity for settlements — without touching the audited Vault. The account is just another `RELAYER_ROLE` holder, bounded by the same `txLimit` / `dailyCap`.

### Design

- Extends the audited eth-infinitism `BaseAccount`; overrides **only** `_validateSignature` (ECDSA over the EntryPoint-supplied `userOpHash`, with the standard Ethereum-signed-message prefix). Nonce handling, prefund and the EntryPoint guard are inherited.
- Exactly **one** immutable signer — the relayer's KMS owner **public** address (`kmsSigner`). No factory, no proxy, no owner/threshold machinery: there is a single account, deployed directly.
- **Non-custodial:** the contract never holds or requests any user key/seed. `kmsSigner` is a public address only.
- `execute(dest, value, func)` is **EntryPoint-only** and bubbles the inner revert verbatim, so the Vault's idempotency / cap / pause reverts stay legible to the off-chain reconciler.

### Settlement flow (Phase 2)

```
Fiat payment event
      |  (off-chain KMS relayer signs a UserOperation)
      v
EntryPoint.handleOps([userOp], beneficiary)        <- canonical v0.7 singleton
      |  validate signature (kmsSigner) + nonce
      v
ProtocolAccount.execute(vault, 0, executeSettlement(ref, recipient, amount))
      v
LiquidityVault.executeSettlement(...)              <- UNCHANGED Phase 1 contract
      v
User's wallet receives ETH
```

The EntryPoint v0.7 singleton is `0x0000000071727De22E5E9d8BAf0edAc6f37da032` (identical on Base and Base Sepolia).

### Key rotation

`kmsSigner` is immutable: **rotating the KMS key means redeploying** `ProtocolAccount`, then (as `DEFAULT_ADMIN_ROLE` — a timelock/multisig, never the KMS key) granting `RELAYER_ROLE` to the new account and revoking it from the old one.

### Dependency

Vendors [`eth-infinitism/account-abstraction`](https://github.com/eth-infinitism/account-abstraction) **v0.7.0** under `lib/account-abstraction/` (remapping `@account-abstraction/contracts/`). No Phase 1 dependency changed.

### Testing stages

| Stage | What | Status |
|---|---|---|
| 1 — unit | Local EntryPoint: signature / access / execute / idempotency (`ProtocolAccount.t.sol`) | Done — 7 tests, run by `make test` |
| 2 — fork | Against the **real** EntryPoint singleton (`ProtocolAccountFork.t.sol`) | Written; skips unless `BASE_MAINNET_RPC_URL` is set |
| 3 — bundler-in-the-loop | A real ERC-4337 bundler simulates & accepts/rejects ops (validation `forge` skips) | Done — `make e2e` (local Anvil fork + Alto bundler), 19 assertions |
| 4 — testnet deploy | Deploy + wire on Base Sepolia; live-bundler smoke | Done — both contracts deployed + **verified on Basescan**; a local Alto bundler against the live network passes (wiring + signature-rejection). The happy-path live settlement needs the KMS owner key, so it is run by the operator's relayer, not this suite. |

> **Note:** `forge` calls `handleOps()` directly, so the unit/fork tests **do not** prove a real bundler will accept the op. Stage 3 covers bundler **acceptance/rejection via simulation**; deep ERC-7562 opcode/storage *trace* enforcement is deferred to Stage 4 (see the E2E caveat below).

---

## Getting started

### Prerequisites

- [Foundry](https://getfoundry.sh/) 1.7+ (`forge`, `cast`, `anvil`)

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### Install

```bash
git clone --recurse-submodules https://github.com/thesourcearchitect/sonicsphere-contracts
cd sonicsphere-contracts
make install      # forge install (installs lib submodules)
make build        # forge build
```

### Test

```bash
make test             # full suite: unit + fuzz + invariant (~2 minutes)
make test-unit        # unit + fuzz only (< 5 seconds)
make test-invariant   # stateful invariant suite only
make coverage         # LCOV + HTML coverage report
```

### Gas snapshot

```bash
make snapshot         # regenerate .gas-snapshot
make check-snapshot   # verify no regression vs committed snapshot
```

### Bundler-in-the-loop E2E (Stage 3)

A self-contained harness drives the **real ERC-4337 stack** locally — no deploys, no
testnet funds spent. It forks Base Sepolia with Anvil, runs the
[Alto](https://github.com/pimlicolabs/alto) bundler against the canonical EntryPoint
v0.7 singleton, deploys `LiquidityVault` + `ProtocolAccount`, wires `RELAYER_ROLE`,
and pushes real `UserOperation`s through `eth_sendUserOperation`:

```bash
export BASE_SEPOLIA_RPC_URL=https://...   # any Base Sepolia RPC (used only to fork)
make e2e
```

It runs 19 assertions: the happy-path settlement lands (`SettlementExecuted`,
recipient paid, ref marked settled); an idempotent replay is bundled but reverts
inside (`success == false`, **no double-release**); and ops with a wrong or malformed
signature are **rejected at simulation** with an **AA24** signature failure (the
harness asserts the *reason*, proving `tryRecover` never reverts into AA23) before
inclusion. Node deps
(`viem`, `@pimlico/alto`) install automatically on first run via `pnpm`, isolated from
the workspace.

> **Caveat:** Anvil exposes no `debug_traceCall`, so Alto runs with `--safe-mode false`
> — the deep ERC-7562 opcode/storage banning rules are **not** trace-enforced here.
> `ProtocolAccount.validateUserOp` only reads immutables and does ECDSA recovery, so it
> is structurally compliant; full opcode-level enforcement is exercised by the real
> hosted bundler in Stage 4 (testnet).

---

## Test coverage

| File | Lines | Statements | Functions | Branches |
|---|---|---|---|---|
| `LiquidityVault.sol` | 100% | 100% | 100% | 90.9% |

**80 total tests** — 48 unit + fuzz, 24 edge-case, 8 stateful invariant (128k calls each)

**Phase 2** — `ProtocolAccount.sol`: 7 unit tests (local EntryPoint) + 2 fork tests (real EntryPoint, skip without RPC).

---

## Deployment

### 1. Configure environment

```bash
cp .env.example .env
# Fill in: ADMIN_ADDRESS, GUARDIAN_ADDRESS, RELAYER_ADDRESS,
#          TX_LIMIT, DAILY_CAP, PRIVATE_KEY, BASESCAN_API_KEY
```

### 2. Deploy

```bash
# Base Sepolia (testnet)
make deploy-sepolia

# Base mainnet
forge script script/Deploy.s.sol \
  --rpc-url base \
  --broadcast \
  --verify \
  --etherscan-api-key $BASESCAN_API_KEY \
  -vvvv
```

### 3. Verify deployment

```bash
make verify-sepolia   # runs VerifyDeployment.s.sol against the deployed vault
```

The verification script checks:
- Bytecode is deployed at the target address
- All three roles assigned to the correct addresses (cross-contamination also checked)
- `txLimit` and `dailyCap` match intended values
- Vault is unpaused, `dailyVolume` is 0, `dailyWindowEnd` is ~24h ahead
- Interface smoke tests (view functions respond correctly)

### Deployed contracts

| Network | Contract | Address | Status |
| --- | --- | --- | --- |
| Base Sepolia (84532) | `LiquidityVault` | [`0x75d56B48b3aF6d2DD1D0B15C04e166ed852A8f26`](https://sepolia.basescan.org/address/0x75d56B48b3aF6d2DD1D0B15C04e166ed852A8f26) | Verified |
| Base Sepolia (84532) | `ProtocolAccount` (ERC-4337 v0.7) | [`0x58d291a766Ae60D47FAb33686C51853F5020967A`](https://sepolia.basescan.org/address/0x58d291a766Ae60D47FAb33686C51853F5020967A) | Verified |

**LiquidityVault**
- Deploy tx: [`0xed8608d91d0b02d6842fff9552ea2f7adfb157e5bdad7e09501239c20e7edd80`](https://sepolia.basescan.org/tx/0xed8608d91d0b02d6842fff9552ea2f7adfb157e5bdad7e09501239c20e7edd80) (block 42863641), deployer `0x5ffA1ec08b735a1cE25E7b65800091fa3eE3D6b0`
- Constructor args: admin `0x1d435baC917AEC8209f9eA46F99C42A375be696A`, guardian `0xA4C4B29E9F6B385134706fBfb181FAAf84b90854`, relayer `0x726ee8188e4FC685d849EEC7ba56879F92234C85`, `txLimit` 0.1 ETH, `dailyCap` 0.5 ETH
- The vault is deployed but **unfunded** — top it up (`make fund-vault`) before it can process settlements.

**ProtocolAccount (ERC-4337 v0.7 settlement account)**
- Deploy tx: [`0x93976a60a5d91c8f6ba67f8986bdb41b6327e2a9e54fc8c0d01eda40d9f253a1`](https://sepolia.basescan.org/tx/0x93976a60a5d91c8f6ba67f8986bdb41b6327e2a9e54fc8c0d01eda40d9f253a1) (block 43136303), deployer `0x5ffA1ec08b735a1cE25E7b65800091fa3eE3D6b0`
- Constructor args: `entryPoint` (canonical v0.7 singleton) `0x0000000071727De22E5E9d8BAf0edAc6f37da032`, `kmsSigner` (public KMS address) `0x726ee8188e4FC685d849EEC7ba56879F92234C85`
- Holds `RELAYER_ROLE` on the vault (granted via `GrantRelayer.s.sol`); it validates UserOps signed by the KMS key and forwards settlements to the vault.
- **A single relayer is authorized.** The `ProtocolAccount` (`0x58d291a766Ae60D47FAb33686C51853F5020967A`) is the only holder of `RELAYER_ROLE`. The deploy-time bootstrap relayer — the KMS signer EOA `0x726ee8188e4FC685d849EEC7ba56879F92234C85`, set as the vault's `relayer` in the constructor — initially also held `RELAYER_ROLE` (the first `GrantRelayer.s.sol` run omitted `OLD_RELAYER_ADDRESS`), but the admin (`DEFAULT_ADMIN_ROLE`, the timelock/multisig `0x1d435baC917AEC8209f9eA46F99C42A375be696A`) has since **revoked** it via `revokeRole(RELAYER_ROLE, 0x726ee8…)` — tx [`0x981e3d1294e543f8e65d7e9dc329e29667820d47fc38786f3b316fb6493fabc8`](https://sepolia.basescan.org/tx/0x981e3d1294e543f8e65d7e9dc329e29667820d47fc38786f3b316fb6493fabc8). `hasRole(RELAYER_ROLE, 0x726ee8…)` is now `false`.

**Public KMS signer** (`ProtocolAccount.kmsSigner()` — the authorized UserOp signer): `0x726ee8188e4FC685d849EEC7ba56879F92234C85`. This is the **public** address of the operator's KMS-held key; the private key never leaves the KMS and is never used for admin actions. ABIs for both contracts are emitted to `out/<Contract>.sol/<Contract>.json` (the `abi` field) after `forge build`; both contracts' source is also verified on Basescan (linked above).

### Phase 2 — deploy & wire the settlement account

```bash
# 1. Deploy the ERC-4337 account (EntryPoint defaults to the v0.7 singleton)
KMS_SIGNER_ADDRESS=0x... \
  forge script script/DeployProtocolAccount.s.sol \
  --rpc-url base_sepolia --broadcast --verify -vvvv

# 2. Wire it to the vault — must be broadcast by DEFAULT_ADMIN_ROLE (timelock/multisig)
VAULT_ADDRESS=0x... PROTOCOL_ACCOUNT_ADDRESS=0x... OLD_RELAYER_ADDRESS=0x... \
  forge script script/GrantRelayer.s.sol \
  --rpc-url base_sepolia --broadcast -vvvv
```

`GrantRelayer.s.sol` grants `RELAYER_ROLE` to the new account and (if `OLD_RELAYER_ADDRESS` is set) revokes the placeholder/previous relayer. The KMS key is **never** used for admin actions.

---

## Operational scripts

### Update risk parameters (Guardian)

```bash
VAULT_ADDRESS=0x... TX_LIMIT=1000000000000000000 DAILY_CAP=5000000000000000000 \
  forge script script/SetRiskParams.s.sol \
  --rpc-url base --broadcast
```

### Emergency pause (Guardian)

```bash
# Pause
forge script script/EmergencyPause.s.sol \
  --rpc-url base --broadcast \
  --sig "pause(address)" <VAULT_ADDRESS>

# Unpause
forge script script/EmergencyPause.s.sol \
  --rpc-url base --broadcast \
  --sig "unpause(address)" <VAULT_ADDRESS>

# Status check (read-only, no broadcast)
forge script script/EmergencyPause.s.sol \
  --rpc-url base \
  --sig "status(address)" <VAULT_ADDRESS>
```

---

## Security

See [SECURITY.md](./SECURITY.md) for:
- Responsible disclosure process
- Severity classification table
- Full on-chain security architecture
- Role isolation details
- Known limitations (by design)

**Do not open a public GitHub Issue for vulnerability reports.**

---

## Security considerations

- **CEI pattern** — all state changes in `executeSettlement` occur before the external `.call`, eliminating reentrancy risk. `ReentrancyGuard` provides an additional belt-and-suspenders lock.
- **Minimal attack surface** — Phase 1 handles only native ETH. No ERC-20 mechanics, no token allowances, no external protocol dependencies beyond OpenZeppelin base contracts.
- **Identity-isolated relayer** — `RELAYER_ROLE` can only call `executeSettlement`. It has no access to risk-parameter changes, pausing, or ETH rescue.
- **Key-compromise containment** — if the relayer key is compromised, the attacker is bounded by `txLimit` per transaction and `dailyCap` per 24-hour window. `GUARDIAN_ROLE` can pause the vault and cancel pending refs independently of `DEFAULT_ADMIN_ROLE`.
- **No upgradability** — the contract is intentionally non-upgradeable to provide an immutable, auditable settlement guarantee.

---

## Audit status

| Date | Auditor | Scope | Report |
|---|---|---|---|
| Pending | TBD | Full contract + scripts | Pre-launch |

A formal third-party audit is planned prior to mainnet deployment and liquidity funding.

---

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for the PR checklist, branching model, and coding standards.

---

## License

MIT — see [LICENSE](./LICENSE)
