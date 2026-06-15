#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# SonicSphere Contracts — git init, Foundry submodules, build, test, single push
# Creates a brand-new git repo INSIDE sonicsphere-contracts/ (so it never touches
# the parent monorepo's git) and FORCE-pushes the contracts-only tree to GitHub as
# one clean initial commit on `main`, overwriting any incorrect history already
# there (an earlier task accidentally pushed the whole monorepo).
# Run from the workspace root: bash sonicsphere-contracts/setup-and-push.sh
# Requires: GITHUB_PAT (write access) in the environment.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

export PATH="/home/runner/workspace/.config/.foundry/bin:$PATH"
REPO_DIR="/home/runner/workspace/sonicsphere-contracts"
GITHUB_USER="thesourcearchitect"
REPO_NAME="sonicsphere-contracts"
PAT="${GITHUB_PAT:?GITHUB_PAT must be set in the environment}"

cd "$REPO_DIR"

echo "==> Initialising git repository..."
git init -q
git branch -M main 2>/dev/null || git checkout -q -b main
git config user.email "deploy@sonicsphere.io"
git config user.name "SonicSphere"

echo "==> Installing Foundry submodules (pinned to foundry.lock)..."
# The workspace ships unpacked lib/ dirs; remove them so forge can add clean submodules.
rm -rf lib/forge-std lib/openzeppelin-contracts
forge install foundry-rs/forge-std@v1.16.1
forge install OpenZeppelin/openzeppelin-contracts@v5.6.1

echo "==> Building contracts..."
forge build

echo "==> Running test suite (fork tests excluded — they need a live Base Sepolia RPC)..."
forge test -vvv --no-match-path "test/LiquidityVaultFork.t.sol"

echo "==> Staging all files..."
git add -A

echo "==> Creating single initial commit..."
git commit -q -m "feat: SonicSphere LiquidityVault — fiat-to-Web3 liquidity bridge on Base (Phase 1, native ETH)

Enterprise-grade Foundry smart contract repository for the SonicSphere
fiat-to-Web3 liquidity bridge. Phase 1 supports native ETH on Base.

Contracts
- ILiquidityVault.sol: full external ABI (events, custom errors, functions)
- LiquidityVault.sol: hardened ETH vault — RELAYER_ROLE settlement execution,
  settlementRef idempotency registry (replay / double-spend protection),
  per-tx limit + rolling 24h volume cap, AccessControl, Pausable, ReentrancyGuard

Tooling & scripts
- Deploy, FundVault, SetRiskParams, EmergencyPause, CancelRefs, RescueEth,
  TransferAdmin, CheckReadiness, MonitorVault, VerifyDeployment
- foundry.toml (Etherscan V2 verification), Makefile, CI workflows, Slither config

Tests
- Unit + fuzz, edge-case, invariant, and live-fork suites

Deployment
- LiquidityVault live on Base Sepolia (84532) at
  0x75d56B48b3aF6d2DD1D0B15C04e166ed852A8f26 — verified on Basescan
- broadcast/Deploy.s.sol/84532/run-latest.json included

Dependencies: forge-std v1.16.1 | openzeppelin-contracts v5.6.1 | solc 0.8.25"

echo "==> Configuring remote and force-pushing (overwrites incorrect prior history)..."
git remote remove origin 2>/dev/null || true
git remote add origin "https://${PAT}@github.com/${GITHUB_USER}/${REPO_NAME}.git"
git push -u origin main --force

echo ""
echo "✓ Done — https://github.com/${GITHUB_USER}/${REPO_NAME}"
