# Changelog

All notable changes to this project are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

> Changes staged for the next release but not yet tagged.

### Added

- `script/CheckReadiness.s.sol` — pre-deployment wallet + environment readiness
  check (env vars, deployer balance vs estimated gas + vault seed, risk params,
  role-address isolation)
- `script/MonitorVault.s.sol` — live operational monitor: liquidity vs risk
  parameters, daily-window utilisation (mirrors the contract's lazy reset),
  remaining settlement capacity, and per-ref settled / not-settled classification.
  Supports `MIN_VAULT_BALANCE`, `MONITOR_REFS`, and `MONITOR_STRICT` env vars.
- `docs/wallet-setup.md` — step-by-step Base Sepolia wallet funding guide
- `Makefile` — `check-readiness`, `check-readiness-mainnet`, `monitor`,
  `monitor-mainnet`, and `monitor-events` targets

### Fixed

- `foundry.toml` — point contract verification at the Etherscan V2 unified API
  (`https://api.etherscan.io/v2/api?chainid=<id>`); the legacy
  `*.basescan.org/api` V1 endpoints are deprecated and now reject verification.

### Deployed

- `LiquidityVault` deployed and verified on Base Sepolia at
  `0x75d56B48b3aF6d2DD1D0B15C04e166ed852A8f26` (see README → Deployed contracts).

---

## [0.1.0] — 2026-06-13

Initial Phase 1 release: native ETH liquidity vault on Base.

### Added

**Contracts**
- `ILiquidityVault.sol` — full external ABI (events, custom errors, functions)
- `LiquidityVault.sol` — Phase 1 settlement vault with:
  - Three-role access control (`RELAYER_ROLE`, `GUARDIAN_ROLE`, `DEFAULT_ADMIN_ROLE`)
  - `settlementRef` idempotency registry (double-spend and replay protection)
  - Guardian-controlled ref cancellation
  - Per-tx ETH limit (`txLimit`)
  - Rolling 24-hour volume cap (`dailyCap`) with lazy window reset
  - CEI pattern + `ReentrancyGuard` for reentrancy protection
  - `pause()` / `unpause()` emergency halt
  - `rescueEth()` admin-only emergency recovery
  - `receive()` for liquidity top-up

**Scripts** (Foundry)
- `Deploy.s.sol` — initial deployment with constructor arg validation
- `VerifyDeployment.s.sol` — 5-group post-deploy assertion script
- `SetRiskParams.s.sol` — guardian risk parameter update
- `EmergencyPause.s.sol` — pause / unpause / status
- `CancelRefs.s.sol` — batch guardian ref cancellation
- `FundVault.s.sol` — vault ETH top-up
- `TransferAdmin.s.sol` — atomic two-step admin transfer
- `RescueEth.s.sol` — emergency ETH rescue

**Tests**
- `LiquidityVault.t.sol` — 48 unit + fuzz tests (100% line coverage)
- `LiquidityVaultEdgeCases.t.sol` — 24 edge-case tests (failing receiver, window boundaries, role sequences, rescue edge cases)
- `LiquidityVaultInvariant.t.sol` — 8 stateful invariants (128k calls each)
- `LiquidityVaultFork.t.sol` — Base Sepolia fork tests (auto-skipped without RPC)
- `mocks/MockFailingReceiver.sol` — revert/gas-consuming ETH rejection mock

**Documentation**
- `README.md` — comprehensive project overview, scripts, and quickstart
- `SECURITY.md` — responsible disclosure, severity table, security architecture
- `CONTRIBUTING.md` — PR checklist, branching model, coding standards
- `AUDIT.md` — auditor reference: scope, invariants, security properties, focus areas
- `docs/architecture.md` — settlement flow, CEI walkthrough, role rationale, Phase 2 notes
- `docs/runbook.md` — operational procedures: deploy, monitor, incident response, key rotation

**Tooling**
- `Makefile` — 35+ targets covering build, test, coverage, lint, deployment, and operational scripts
- `foundry.toml` — default + coverage profiles
- `.env.example` — documented environment template
- `.slither.toml` — static analysis configuration
- `.github/workflows/ci.yml` — GitHub Actions CI (format, build, test, invariant, coverage)
- `.github/workflows/fork-tests.yml` — nightly Base Sepolia fork tests
- `.github/ISSUE_TEMPLATE/bug_report.md` — structured bug report template
- `.github/ISSUE_TEMPLATE/feature_request.md` — feature request template
- `.github/pull_request_template.md` — PR checklist

### Security

- 100% line, statement, and function coverage on `LiquidityVault.sol`
- 8 stateful invariants verified across 128,000 randomised call sequences each
- CEI pattern verified by invariant fuzzer (no reentrancy path found)
- Formal audit pending (scheduled pre-mainnet)

---

[Unreleased]: https://github.com/thesourcearchitect/sonicsphere-contracts/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/thesourcearchitect/sonicsphere-contracts/releases/tag/v0.1.0
