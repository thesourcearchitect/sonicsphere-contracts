# Operational Runbook — LiquidityVault

This document is the step-by-step reference for everyone who operates the SonicSphere on-chain settlement layer. Keep it current with every operational change.

---

## Prerequisites

Before any operation:

```bash
# Verify Foundry is installed
forge --version

# Load env (copy .env.example, fill in values)
cp .env.example .env
source .env   # or: set -a && . .env && set +a

# Confirm VAULT_ADDRESS, ADMIN_ADDRESS, GUARDIAN_ADDRESS, RELAYER_ADDRESS are set
echo $VAULT_ADDRESS
```

All scripts run from the `sonicsphere-contracts/` directory.

---

## Deployed addresses (Base Sepolia, chainId 84532)

| Contract | Address | Verified on Basescan |
| --- | --- | --- |
| `LiquidityVault` | `0x75d56B48b3aF6d2DD1D0B15C04e166ed852A8f26` | yes |
| `ProtocolAccount` (ERC-4337 v0.7) | `0x58d291a766Ae60D47FAb33686C51853F5020967A` | yes |
| Canonical EntryPoint v0.7 | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` | n/a (standard singleton) |

- **Public KMS signer** (authorized UserOp signer, `ProtocolAccount.kmsSigner()`): `0x726ee8188e4FC685d849EEC7ba56879F92234C85`. Public address only — the private key is held in the operator's KMS and never leaves it; it is never used for admin actions.
- **ABIs:** run `forge build`, then read the `abi` field of `out/LiquidityVault.sol/LiquidityVault.json` and `out/ProtocolAccount.sol/ProtocolAccount.json`. Both contracts are source-verified on Basescan, so the ABI is also downloadable from the explorer.
- The `ProtocolAccount` is the **sole** holder of the vault's `RELAYER_ROLE`. The deploy-time bootstrap relayer — the KMS signer EOA `0x726ee8188e4FC685d849EEC7ba56879F92234C85`, set as the vault's initial `relayer` in the constructor — initially also held `RELAYER_ROLE`, but the admin has since **revoked** it (tx `0x981e3d1294e543f8e65d7e9dc329e29667820d47fc38786f3b316fb6493fabc8`); `hasRole(RELAYER_ROLE, 0x726ee8…)` is now `false`. See §4.1 for the rotation/revoke procedure.

### Smoke-test infrastructure (Alto local bundler)

`e2e/smoke-testnet.mjs` runs a local Alto bundler against live Base Sepolia. It needs four standard Pimlico/EntryPoint **simulation** helper contracts, pre-deployed once via the canonical CREATE2 factory (`0x4e59b44847b379578588920cA78FbF26c0B4956C`); they persist on-chain, so re-runs detect and skip them:

| Helper | Address |
| --- | --- |
| `PimlicoSimulations` | `0x2451358f0D2eaE6e3a5398FD8519736c120D36D1` |
| `EntryPointSimulations` 0.7 | `0x862859BCB9bAF6413D90b34C7807241A8380FfC4` |
| `EntryPointSimulations` 0.8 | `0x58b519eaEb079ED23dfAA29D6a367b968fe51272` |
| `EntryPointSimulations` 0.9 | `0x5b5A936AD8F0467f1a20260a9462C887B7F8C07B` |

These are bundler infrastructure, **not** SonicSphere protocol contracts. The smoke test reuses a persisted utility key (`e2e/.alto-utility-key`, gitignored) so the CREATE2 salt — and therefore these addresses — stay stable across runs.

---

## 1. Initial deployment

### 1.1 Deploy to Base Sepolia (testnet)

```bash
# Dry run first (no --broadcast)
make deploy-sepolia

# Review the output, then broadcast
make deploy-sepolia-broadcast
```

After broadcasting, record the deployed vault address:

```bash
# In .env:
VAULT_ADDRESS=0x<deployed-address>
```

### 1.2 Verify the deployment

```bash
make verify-sepolia
```

All checks must print `[PASS]`. If any print `[FAIL]`, do not proceed to funding.

### 1.3 Fund the vault

```bash
FUND_AMOUNT=5000000000000000000  make fund-sepolia   # 5 ETH
```

Confirm the balance via `status-sepolia`:

```bash
make status-sepolia
```

### 1.4 Enable the relayer

For a fresh deploy the constructor grants `RELAYER_ROLE` to the address passed as `relayer`. In the **Phase 2 / live Base Sepolia** setup the on-chain relayer is the **`ProtocolAccount`** smart account (`0x58d291a766Ae60D47FAb33686C51853F5020967A`), granted via `GrantRelayer.s.sol`; the KMS owner key only **signs** UserOps — it is not itself the relayer.

```bash
# Confirm the ProtocolAccount holds RELAYER_ROLE
cast call $VAULT_ADDRESS "hasRole(bytes32,address)(bool)" \
  $(cast keccak "RELAYER_ROLE") 0x58d291a766Ae60D47FAb33686C51853F5020967A \
  --rpc-url $BASE_SEPOLIA_RPC_URL
# Expected: true
```

> **Cleanup note (resolved):** the deploy-time bootstrap relayer (the KMS signer EOA `0x726ee8188e4FC685d849EEC7ba56879F92234C85`) initially held `RELAYER_ROLE` because `GrantRelayer.s.sol` was first run without `OLD_RELAYER_ADDRESS`. The admin has since revoked it (tx `0x981e3d1294e543f8e65d7e9dc329e29667820d47fc38786f3b316fb6493fabc8`), so the `ProtocolAccount` is now the only authorized relayer.

### 1.5 Smoke-test a settlement

Send a small test settlement via the relayer. Verify:
- `isSettled(ref)` returns `true`
- User wallet balance increased
- `dailyVolume` increased

---

## 2. Day-to-day operations

### 2.1 Check vault status

```bash
make status-sepolia      # Base Sepolia
make status-mainnet      # Base Mainnet
```

Key fields to monitor:
- `paused` — must be `no` for settlements to work
- `vaultBalance` — alert if below 3x `dailyCap`
- `dailyVolume` — approaching `dailyCap` = top up soon
- `windowEnd` — when the daily window resets

### 2.1a Full health snapshot (recommended before/after each batch)

`MonitorVault.s.sol` produces a single consolidated health report: liquidity vs
risk parameters, daily-window utilisation (with lazy-reset handling), remaining
settlement capacity, and per-ref status.

```bash
# Uses VAULT_ADDRESS from env
make monitor             # Base Sepolia
make monitor-mainnet     # Base Mainnet

# Classify specific refs and/or set a custom alert floor:
MONITOR_REFS=0xref1,0xref2 \
MIN_VAULT_BALANCE=2000000000000000000 \
  make monitor

# Strict mode: non-zero exit if ANY [ALERT] fires (incl. the balance
# floor) - use for cron/CI alerting
MONITOR_STRICT=true make monitor
```

What each alert means:
- `[ALERT] balance < txLimit` — vault cannot fund even one max settlement (CRITICAL)
- `[ALERT] balance below configured alert floor` — top up now (default floor = 2x `dailyCap`)
- `[WARN] balance < dailyCap` — cannot sustain a full capped day
- `[WARN] daily utilisation >= 80%` — approaching the cap; expect throttling

Historical executed/cancelled counts come from event logs. Defaults to Base
Sepolia; set `RPC_URL` to target another network:

```bash
VAULT_ADDRESS=0x... DEPLOY_BLOCK=<block> make monitor-events
# mainnet:
VAULT_ADDRESS=0x... DEPLOY_BLOCK=<block> RPC_URL=$BASE_MAINNET_RPC_URL make monitor-events
```

### 2.2 Top up vault liquidity

```bash
FUND_AMOUNT=<amount_in_wei>  make fund-mainnet
```

### 2.3 Adjust risk parameters

```bash
# Update both in one transaction
TX_LIMIT=1000000000000000000 DAILY_CAP=5000000000000000000 make set-risk-mainnet
```

Must be called by a signer holding `GUARDIAN_ROLE`.

---

## 3. Incident response

### 3.1 Pause the vault (immediate)

Use this when suspicious settlement activity is detected.

```bash
make pause-sepolia      # testnet
# or
forge script script/EmergencyPause.s.sol \
  --rpc-url $BASE_MAINNET_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  --sig "pause(address)" $VAULT_ADDRESS
```

Verify pause took effect:

```bash
make status-mainnet
# paused: YES
```

### 3.2 Cancel suspicious settlement refs

While paused (or while investigating), cancel any refs that may have been double-submitted or are part of an attack:

```bash
# Single ref
CANCEL_REFS=0xabc...def  make cancel-refs-sepolia

# Multiple refs (comma-separated)
CANCEL_REFS=0xabc...def,0x123...456  make cancel-refs-sepolia
```

A cancelled ref can never be executed — even after unpause.

### 3.3 Reduce risk parameters

If the threat is a compromised relayer, reduce the caps before unpausing:

```bash
TX_LIMIT=100000000000000000 DAILY_CAP=500000000000000000 make set-risk-mainnet
# 0.1 ETH per tx, 0.5 ETH per day
```

### 3.4 Unpause after incident is resolved

```bash
make unpause-sepolia
# or for mainnet:
forge script script/EmergencyPause.s.sol \
  --rpc-url $BASE_MAINNET_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  --sig "unpause(address)" $VAULT_ADDRESS
```

---

## 4. Key rotation

### 4.1 Rotate the relayer (KMS key)

The relayer is the `ProtocolAccount` smart account, and its `kmsSigner` is **immutable** — there is no setter. Rotating the KMS key therefore means **redeploying** the account and re-pointing the vault at it. Every admin step is signed by `DEFAULT_ADMIN_ROLE` (the timelock/multisig) — **never** the KMS key.

1. Provision the new KMS key (off-chain) and note its **public** address.
2. Deploy a new `ProtocolAccount` with the new signer:

```bash
KMS_SIGNER_ADDRESS=0x<new-public-address> \
  forge script script/DeployProtocolAccount.s.sol \
  --rpc-url base_sepolia --broadcast --verify -vvvv
```

3. Grant `RELAYER_ROLE` to the new account **and revoke the old one** in a single run:

```bash
VAULT_ADDRESS=0x... \
PROTOCOL_ACCOUNT_ADDRESS=0x<new-account> \
OLD_RELAYER_ADDRESS=0x<old-account> \
  forge script script/GrantRelayer.s.sol \
  --rpc-url base_sepolia --broadcast -vvvv
```

4. Confirm: the new account has `RELAYER_ROLE` and the old account does not.

> If a raw EOA was ever granted `RELAYER_ROLE` directly (e.g. the deploy-time bootstrap relayer `0x726ee8188e4FC685d849EEC7ba56879F92234C85`), revoke it the same way — set `OLD_RELAYER_ADDRESS` to that EOA, or call `revokeRole(RELAYER_ROLE, <eoa>)` from the admin.

### 4.2 Rotate guardian key

Same pattern as relayer rotation, using `GUARDIAN_ROLE`.

### 4.3 Transfer admin to a new multisig

```bash
NEW_ADMIN=0x<new-multisig> make transfer-admin-sepolia
# review output, then:
NEW_ADMIN=0x<new-multisig> \
  forge script script/TransferAdmin.s.sol \
  --rpc-url $BASE_MAINNET_RPC_URL \
  --private-key $ADMIN_PRIVATE_KEY \
  --broadcast
```

**This is irreversible.** Verify the new multisig address three times before broadcasting.

---

## 5. Emergency ETH rescue

Use only when the contract must be decommissioned or a critical bug requires evacuating funds.

```bash
# Pause first
make pause-mainnet

# Rescue all ETH to the admin multisig
RESCUE_TARGET=$ADMIN_ADDRESS make rescue-mainnet

# Or partial rescue
RESCUE_TARGET=$ADMIN_ADDRESS RESCUE_AMOUNT=<wei> make rescue-mainnet
```

After rescue, the vault balance will be 0. Do not unpause — deploy a new vault.

---

## 6. Decommissioning

1. Pause the vault.
2. Revoke `RELAYER_ROLE` from all relayer EOAs.
3. Wait for all in-flight settlements to either execute or expire.
4. Rescue remaining ETH to the admin multisig.
5. Announce decommission via the appropriate channel.
6. Do not redeploy to the same address (contracts are non-upgradeable and the address is tombstoned once empty).

---

## 7. Monitoring checklist (daily)

Run `make monitor` first — it covers the first three items automatically.

- [ ] `make monitor` reports `STATUS: HEALTHY`
- [ ] `vaultBalance` > 3x `dailyCap`
- [ ] No unexpected `Paused` or `SettlementCancelled` events in the last 24h
- [ ] `dailyVolume` < 80% of `dailyCap`
- [ ] CI green on `main` branch
- [ ] Relayer uptime > 99.9%
- [ ] No abnormal gas spikes in relayer txns

---

## 8. Useful `cast` one-liners

```bash
# Check vault balance
cast balance $VAULT_ADDRESS --rpc-url $BASE_MAINNET_RPC_URL

# Check if a ref is settled
cast call $VAULT_ADDRESS "isSettled(bytes32)(bool)" 0x<ref> --rpc-url $BASE_MAINNET_RPC_URL

# Check if vault is paused
cast call $VAULT_ADDRESS "paused()(bool)" --rpc-url $BASE_MAINNET_RPC_URL

# Check current txLimit
cast call $VAULT_ADDRESS "txLimit()(uint256)" --rpc-url $BASE_MAINNET_RPC_URL

# Check daily volume
cast call $VAULT_ADDRESS "dailyVolume()(uint256)" --rpc-url $BASE_MAINNET_RPC_URL

# Check daily window end timestamp
cast call $VAULT_ADDRESS "dailyWindowEnd()(uint256)" --rpc-url $BASE_MAINNET_RPC_URL
```
