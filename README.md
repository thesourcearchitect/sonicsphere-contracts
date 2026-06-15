# SonicSphere Contracts

> **Phase 1 — Native ETH Liquidity Vault on Base**

Isolated, auditable Foundry repository for the SonicSphere fiat-to-Web3 liquidity bridge settlement layer. This repository contains only the on-chain Solidity architecture; off-chain KMS relayer infrastructure lives in a separate private repository.

---

## Architecture

```
src/
├── interfaces/
│   └── ILiquidityVault.sol   <- full external ABI (events, errors, functions)
└── LiquidityVault.sol        <- Phase 1 implementation

script/
├── Deploy.s.sol              <- initial deployment
├── VerifyDeployment.s.sol    <- post-deploy verification (5-group check)
├── SetRiskParams.s.sol       <- guardian: update txLimit / dailyCap
└── EmergencyPause.s.sol      <- guardian: pause / unpause / status

test/
├── LiquidityVault.t.sol          <- 48 unit + fuzz tests
├── LiquidityVaultEdgeCases.t.sol <- 24 edge-case tests
├── LiquidityVaultInvariant.t.sol <- 8 stateful invariant tests
└── mocks/
    └── MockFailingReceiver.sol   <- revert/gas-burning ETH rejection mock
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

---

## Test coverage

| File | Lines | Statements | Functions | Branches |
|---|---|---|---|---|
| `LiquidityVault.sol` | 100% | 100% | 100% | 90.9% |

**80 total tests** — 48 unit + fuzz, 24 edge-case, 8 stateful invariant (128k calls each)

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

- Deploy tx: [`0xed8608d91d0b02d6842fff9552ea2f7adfb157e5bdad7e09501239c20e7edd80`](https://sepolia.basescan.org/tx/0xed8608d91d0b02d6842fff9552ea2f7adfb157e5bdad7e09501239c20e7edd80) (block 42863641), deployer `0x5ffA1ec08b735a1cE25E7b65800091fa3eE3D6b0`
- Constructor args: admin `0x1d435baC917AEC8209f9eA46F99C42A375be696A`, guardian `0xA4C4B29E9F6B385134706fBfb181FAAf84b90854`, relayer `0x726ee8188e4FC685d849EEC7ba56879F92234C85`, `txLimit` 0.1 ETH, `dailyCap` 0.5 ETH
- The vault is deployed but **unfunded** — top it up (`make fund-vault`) before it can process settlements.

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
