# Wallet Setup — Base Sepolia Deployment

This guide walks you through setting up and funding the deployer wallet before running `Deploy.s.sol` on Base Sepolia.

---

## How much ETH do you need?

| Purpose | Estimated amount |
|---|---|
| Deployment gas (LiquidityVault contract) | ~0.002 ETH |
| Gas buffer (verification, scripts) | ~0.003 ETH |
| Initial vault seed liquidity | 0.1–1 ETH (your choice) |
| **Minimum recommended (testnet)** | **0.11 ETH** |
| **Comfortable buffer** | **0.5 ETH** |

Run the readiness check at any time to see your exact numbers:

```bash
forge script script/CheckReadiness.s.sol --rpc-url base_sepolia
```

---

## Step 1 — Create a deployer wallet

You need a fresh EOA (externally owned account) for deployment. **Do not reuse a hot wallet or any wallet with real mainnet funds.**

### Option A: Generate with `cast`

```bash
cast wallet new
```

Output:
```
Successfully created new keypair.
Address:     0xABCDEF...
Private key: 0x1234...
```

Save the private key somewhere secure (password manager or hardware wallet backup). You will add it to Replit Secrets as `DEPLOYER_PRIVATE_KEY`.

### Option B: Use an existing wallet

If you already have a dedicated testnet EOA, use that. Export the private key from MetaMask:
**Account Details → Export Private Key**.

---

## Step 2 — Fund the wallet on Base Sepolia

Base Sepolia ETH (testnet ETH) has no real-world value and is free to obtain.

### Faucets (pick one)

| Faucet | Amount | Notes |
|---|---|---|
| [Coinbase Base Sepolia Faucet](https://www.coinbase.com/faucets/base-ethereum-goerli-faucet) | 0.02–0.05 ETH | Requires Coinbase account |
| [QuickNode Base Sepolia Faucet](https://faucet.quicknode.com/base/sepolia) | 0.05 ETH | Requires QuickNode account |
| [Alchemy Base Sepolia Faucet](https://www.alchemy.com/faucets/base-sepolia) | 0.05–0.1 ETH | Requires Alchemy account |
| [Superchain Faucet](https://app.optimism.io/faucet) | 0.05 ETH | OP Superchain, includes Base |

Request from 2–3 faucets to reach the 0.5 ETH target.

### Verify your balance

```bash
cast balance <YOUR_DEPLOYER_ADDRESS> --rpc-url https://sepolia.base.org
```

---

## Step 3 — Set Replit Secrets

Go to the Replit **Secrets** panel and add these:

| Secret name | Value |
|---|---|
| `DEPLOYER_PRIVATE_KEY` | `0x<your-private-key>` |
| `ADMIN_ADDRESS` | Address that will hold DEFAULT_ADMIN_ROLE (can be the deployer initially) |
| `GUARDIAN_ADDRESS` | Address that will hold GUARDIAN_ROLE |
| `RELAYER_ADDRESS` | Your KMS relayer EOA address |
| `BASE_SEPOLIA_RPC_URL` | `https://sepolia.base.org` (or your own RPC) |
| `BASESCAN_API_KEY` | From [basescan.org/apis](https://basescan.org/myapikey) (for contract verification) |
| `TX_LIMIT` | `100000000000000000` (0.1 ETH in wei — start conservative) |
| `DAILY_CAP` | `500000000000000000` (0.5 ETH in wei) |
| `INITIAL_VAULT_FUND` | `100000000000000000` (0.1 ETH in wei) |

> **Security note:** the deployer private key is only needed for deployment. After deploying and confirming roles, you should revoke it from all role positions and move to a hardware wallet or multisig for `ADMIN_ADDRESS`.

---

## Step 4 — Verify readiness

```bash
source .env   # if using a .env file locally
forge script script/CheckReadiness.s.sol --rpc-url base_sepolia
```

All checks should print `[OK]`. Fix any `[FAIL]` or `[MISSING]` entries before proceeding.

---

## Step 5 — Deploy

Once readiness checks pass:

```bash
# Dry run (no broadcast — review output first)
make deploy-sepolia

# Broadcast + verify on-chain
make deploy-sepolia-broadcast
```

After deployment, record the vault address:

```bash
# In .env or Replit Secrets:
VAULT_ADDRESS=0x<deployed-address>
```

---

## Step 6 — Verify and fund the vault

```bash
# Confirm all roles, params, and state are correct
make verify-sepolia

# Fund the vault with initial liquidity
make fund-sepolia   # uses FUND_AMOUNT from .env (or INITIAL_VAULT_FUND)
```

---

## Role address recommendations (testnet)

For testnet, it's fine to use one wallet for all three roles initially. For production, use isolated addresses:

| Role | Testnet | Production |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | Deployer EOA (temporary) | Hardware wallet or 2-of-3 multisig |
| `GUARDIAN_ROLE` | Separate testnet EOA | Dedicated ops wallet |
| `RELAYER_ROLE` | KMS-generated EOA | KMS-managed (never hot wallet) |

---

## Getting a Basescan API key (for contract verification)

1. Go to [https://basescan.org](https://basescan.org) and create a free account.
2. Navigate to **My Account → API Keys**.
3. Create a new API key and copy it.
4. Add it to Replit Secrets as `BASESCAN_API_KEY`.

Contract verification is optional but strongly recommended — it lets anyone read your source code on the explorer and confirms there's no hidden logic.

---

## Troubleshooting

**"insufficient funds for gas"**
Your deployer wallet doesn't have enough ETH. Check balance and request more from a faucet.

**"nonce too high" / "nonce too low"**
The private key was used for another deployment. Reset nonce with:
```bash
cast nonce <DEPLOYER_ADDRESS> --rpc-url https://sepolia.base.org
```

**"deployment failed to verify"**
Basescan can be slow. Wait 30–60 seconds and re-run:
```bash
forge verify-contract <ADDRESS> src/LiquidityVault.sol:LiquidityVault \
  --chain base-sepolia \
  --etherscan-api-key $BASESCAN_API_KEY
```

**"CheckReadiness fails: DAILY_CAP < TX_LIMIT"**
Your `TX_LIMIT` is larger than `DAILY_CAP`. Reduce `TX_LIMIT` or increase `DAILY_CAP`.
