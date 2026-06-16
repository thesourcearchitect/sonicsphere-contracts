# ──────────────────────────────────────────────────────────────────────────────
# SonicSphere Contracts — Makefile
# Usage: make <target>
# ──────────────────────────────────────────────────────────────────────────────

# Load .env if it exists (never committed — see .env.example)
-include .env

# Foundry binary (overridable: FORGE=/path/to/forge make build)
FORGE   ?= forge
CAST    ?= cast
ANVIL   ?= anvil

# Default verbosity for test output (override: make test V=-vvvv)
V ?= -vvv

# ──────────────────────────────────────────────────────────────────────────────
# Help (default target)
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
          awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}' | \
          sort

# ──────────────────────────────────────────────────────────────────────────────
# Dependencies
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: install
install: ## Install Foundry lib dependencies (forge-std + openzeppelin)
	$(FORGE) install foundry-rs/forge-std
	$(FORGE) install OpenZeppelin/openzeppelin-contracts

.PHONY: update
update: ## Update all Foundry lib dependencies to latest
	$(FORGE) update

# ──────────────────────────────────────────────────────────────────────────────
# Build
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: build
build: ## Compile all contracts
	$(FORGE) build

.PHONY: clean
clean: ## Remove build artefacts and cache
	$(FORGE) clean

.PHONY: remappings
remappings: ## Regenerate remappings.txt from installed libs
	$(FORGE) remappings > remappings.txt

# ──────────────────────────────────────────────────────────────────────────────
# Test
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: test
test: ## Run full test suite (unit + fuzz + invariant)
	$(FORGE) test $(V)

.PHONY: test-unit
test-unit: ## Run unit + edge-case tests (fast, no invariants)
	$(FORGE) test --match-contract "LiquidityVaultTest|LiquidityVaultEdgeCases" $(V)

.PHONY: test-edge
test-edge: ## Run edge-case tests only (LiquidityVaultEdgeCasesTest)
	$(FORGE) test --match-contract LiquidityVaultEdgeCases $(V)

.PHONY: test-invariant
test-invariant: ## Run stateful invariant tests only (LiquidityVaultInvariant)
	$(FORGE) test --match-contract LiquidityVaultInvariant $(V)

.PHONY: test-fuzz
test-fuzz: ## Run fuzz tests only (testFuzz_* functions)
	$(FORGE) test --match-test "testFuzz_" $(V)

.PHONY: test-gas
test-gas: ## Run tests and emit a full gas report
	$(FORGE) test --gas-report

.PHONY: snapshot
snapshot: ## Create / update a gas snapshot (.gas-snapshot)
	$(FORGE) snapshot

.PHONY: snapshot-check
snapshot-check: ## Fail if gas has regressed vs the committed snapshot
	$(FORGE) snapshot --check

# ──────────────────────────────────────────────────────────────────────────────
# Coverage
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: coverage
coverage: ## Run coverage and print a summary to stdout
	$(FORGE) coverage --report summary

.PHONY: coverage-lcov
coverage-lcov: ## Generate coverage/lcov.info (for CI / Codecov)
	$(FORGE) coverage --report lcov --report-file coverage/lcov.info
	@echo "LCOV report written to coverage/lcov.info"

.PHONY: coverage-html
coverage-html: ## Generate an HTML coverage report (requires genhtml / lcov)
	$(FORGE) coverage --report lcov --report-file coverage/lcov.info
	@command -v genhtml >/dev/null 2>&1 || { echo "genhtml not found — install lcov"; exit 1; }
	genhtml coverage/lcov.info --output-directory coverage/html --quiet
	@echo "HTML report: coverage/html/index.html"

# ──────────────────────────────────────────────────────────────────────────────
# Lint / Format
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: fmt
fmt: ## Format Solidity source with forge fmt
	$(FORGE) fmt

.PHONY: fmt-check
fmt-check: ## Check formatting without writing (for CI)
	$(FORGE) fmt --check

.PHONY: lint
lint: ## Run forge lint on the src directory
	$(FORGE) lint src/

# ──────────────────────────────────────────────────────────────────────────────
# Local node
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: anvil
anvil: ## Start a local Anvil fork of Base Sepolia
	$(ANVIL) \
          --fork-url $(BASE_SEPOLIA_RPC_URL) \
          --chain-id 84532 \
          --block-time 2

.PHONY: anvil-mainnet
anvil-mainnet: ## Start a local Anvil fork of Base mainnet
	$(ANVIL) \
          --fork-url $(BASE_MAINNET_RPC_URL) \
          --chain-id 8453 \
          --block-time 2

# ──────────────────────────────────────────────────────────────────────────────
# Post-deployment verification
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: verify-sepolia
verify-sepolia: ## Verify deployed vault on Base Sepolia (requires VAULT_ADDRESS in .env)
	$(FORGE) script script/VerifyDeployment.s.sol \
          --rpc-url $(BASE_SEPOLIA_RPC_URL) \
          --sig "run(address)" $(VAULT_ADDRESS) \
          $(V)

.PHONY: verify-mainnet
verify-mainnet: ## Verify deployed vault on Base mainnet (requires VAULT_ADDRESS in .env)
	$(FORGE) script script/VerifyDeployment.s.sol \
          --rpc-url $(BASE_MAINNET_RPC_URL) \
          --sig "run(address)" $(VAULT_ADDRESS) \
          $(V)

# ──────────────────────────────────────────────────────────────────────────────
# Operational scripts (require GUARDIAN_ADDRESS / DEPLOYER_PRIVATE_KEY in .env)
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: set-risk-sepolia
set-risk-sepolia: ## Update txLimit + dailyCap on Base Sepolia (requires VAULT_ADDRESS, TX_LIMIT, DAILY_CAP)
	@$(FORGE) script script/SetRiskParams.s.sol \
          --rpc-url $(BASE_SEPOLIA_RPC_URL) \
          --private-key $(DEPLOYER_PRIVATE_KEY) \
          --broadcast \
          $(V)

.PHONY: set-risk-mainnet
set-risk-mainnet: ## Update txLimit + dailyCap on Base mainnet (requires VAULT_ADDRESS, TX_LIMIT, DAILY_CAP)
	@$(FORGE) script script/SetRiskParams.s.sol \
          --rpc-url $(BASE_MAINNET_RPC_URL) \
          --private-key $(DEPLOYER_PRIVATE_KEY) \
          --broadcast \
          $(V)

.PHONY: pause-sepolia
pause-sepolia: ## Emergency pause on Base Sepolia (requires VAULT_ADDRESS)
	@$(FORGE) script script/EmergencyPause.s.sol \
          --rpc-url $(BASE_SEPOLIA_RPC_URL) \
          --private-key $(DEPLOYER_PRIVATE_KEY) \
          --broadcast \
          --sig "pause(address)" $(VAULT_ADDRESS) \
          $(V)

.PHONY: unpause-sepolia
unpause-sepolia: ## Unpause on Base Sepolia (requires VAULT_ADDRESS)
	@$(FORGE) script script/EmergencyPause.s.sol \
          --rpc-url $(BASE_SEPOLIA_RPC_URL) \
          --private-key $(DEPLOYER_PRIVATE_KEY) \
          --broadcast \
          --sig "unpause(address)" $(VAULT_ADDRESS) \
          $(V)

.PHONY: status-sepolia
status-sepolia: ## Print vault status on Base Sepolia (read-only, requires VAULT_ADDRESS)
	$(FORGE) script script/EmergencyPause.s.sol \
          --rpc-url $(BASE_SEPOLIA_RPC_URL) \
          --sig "status(address)" $(VAULT_ADDRESS) \
          $(V)

.PHONY: status-mainnet
status-mainnet: ## Print vault status on Base mainnet (read-only, requires VAULT_ADDRESS)
	$(FORGE) script script/EmergencyPause.s.sol \
          --rpc-url $(BASE_MAINNET_RPC_URL) \
          --sig "status(address)" $(VAULT_ADDRESS) \
          $(V)

.PHONY: fund-sepolia
fund-sepolia: ## Fund the vault on Base Sepolia (requires VAULT_ADDRESS, FUND_AMOUNT)
	@$(FORGE) script script/FundVault.s.sol \
          --rpc-url $(BASE_SEPOLIA_RPC_URL) \
          --private-key $(DEPLOYER_PRIVATE_KEY) \
          --broadcast \
          $(V)

.PHONY: fund-mainnet
fund-mainnet: ## Fund the vault on Base mainnet (requires VAULT_ADDRESS, FUND_AMOUNT)
	@$(FORGE) script script/FundVault.s.sol \
          --rpc-url $(BASE_MAINNET_RPC_URL) \
          --private-key $(DEPLOYER_PRIVATE_KEY) \
          --broadcast \
          $(V)

.PHONY: cancel-refs-sepolia
cancel-refs-sepolia: ## Cancel refs on Base Sepolia (requires VAULT_ADDRESS, CANCEL_REFS)
	@$(FORGE) script script/CancelRefs.s.sol \
          --rpc-url $(BASE_SEPOLIA_RPC_URL) \
          --private-key $(DEPLOYER_PRIVATE_KEY) \
          --broadcast \
          $(V)

.PHONY: rescue-sepolia
rescue-sepolia: ## Emergency ETH rescue on Base Sepolia (requires VAULT_ADDRESS, RESCUE_TARGET)
	@$(FORGE) script script/RescueEth.s.sol \
          --rpc-url $(BASE_SEPOLIA_RPC_URL) \
          --private-key $(DEPLOYER_PRIVATE_KEY) \
          --broadcast \
          $(V)

.PHONY: transfer-admin-sepolia
transfer-admin-sepolia: ## Transfer admin role on Base Sepolia (requires VAULT_ADDRESS, NEW_ADMIN)
	@$(FORGE) script script/TransferAdmin.s.sol \
          --rpc-url $(BASE_SEPOLIA_RPC_URL) \
          --private-key $(DEPLOYER_PRIVATE_KEY) \
          --broadcast \
          $(V)

# ──────────────────────────────────────────────────────────────────────────────
# Deployment -- Base Sepolia (testnet)
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: deploy-sepolia
deploy-sepolia: ## Deploy LiquidityVault to Base Sepolia (dry run by default)
	@$(FORGE) script script/Deploy.s.sol \
          --rpc-url $(BASE_SEPOLIA_RPC_URL) \
          --private-key $(DEPLOYER_PRIVATE_KEY) \
          $(V)

.PHONY: deploy-sepolia-broadcast
deploy-sepolia-broadcast: ## Deploy + broadcast + verify on Base Sepolia
	@$(FORGE) script script/Deploy.s.sol \
          --rpc-url $(BASE_SEPOLIA_RPC_URL) \
          --private-key $(DEPLOYER_PRIVATE_KEY) \
          --broadcast \
          --verify \
          $(V)

# ──────────────────────────────────────────────────────────────────────────────
# Deployment — Base Mainnet
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: deploy-mainnet
deploy-mainnet: ## Deploy LiquidityVault to Base mainnet (dry run — review first!)
	@$(FORGE) script script/Deploy.s.sol \
          --rpc-url $(BASE_MAINNET_RPC_URL) \
          --private-key $(DEPLOYER_PRIVATE_KEY) \
          $(V)

.PHONY: deploy-mainnet-broadcast
deploy-mainnet-broadcast: ## Deploy + broadcast + verify on Base mainnet (PRODUCTION)
	@echo "⚠  MAINNET DEPLOYMENT — confirm with CTRL-C to abort, ENTER to continue"
	@read _
	@$(FORGE) script script/Deploy.s.sol \
          --rpc-url $(BASE_MAINNET_RPC_URL) \
          --private-key $(DEPLOYER_PRIVATE_KEY) \
          --broadcast \
          --verify \
          $(V)

# ──────────────────────────────────────────────────────────────────────────────
# CI pipeline (run in order)
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: ci
ci: fmt-check build test snapshot-check coverage-lcov ## Full CI pipeline (format → build → test → gas-snapshot → coverage)

# ──────────────────────────────────────────────────────────────────────────────
# Utilities
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: check-readiness
check-readiness: ## Pre-deployment wallet and env readiness check (Base Sepolia)
	$(FORGE) script script/CheckReadiness.s.sol \
          --rpc-url $(BASE_SEPOLIA_RPC_URL) \
          $(V)

.PHONY: check-readiness-mainnet
check-readiness-mainnet: ## Pre-deployment wallet and env readiness check (Base Mainnet)
	$(FORGE) script script/CheckReadiness.s.sol \
          --rpc-url $(BASE_MAINNET_RPC_URL) \
          $(V)

.PHONY: monitor
monitor: ## Live vault health snapshot on Base Sepolia (requires VAULT_ADDRESS)
	$(FORGE) script script/MonitorVault.s.sol \
	  --rpc-url $(BASE_SEPOLIA_RPC_URL) \
	  --sig "runAt(address)" $(VAULT_ADDRESS) \
	  $(V)

.PHONY: monitor-mainnet
monitor-mainnet: ## Live vault health snapshot on Base mainnet (requires VAULT_ADDRESS)
	$(FORGE) script script/MonitorVault.s.sol \
	  --rpc-url $(BASE_MAINNET_RPC_URL) \
	  --sig "runAt(address)" $(VAULT_ADDRESS) \
	  $(V)

.PHONY: monitor-events
monitor-events: ## Count executed/cancelled settlements from logs (set VAULT_ADDRESS, DEPLOY_BLOCK; RPC_URL overrides network)
	@rpc="$(or $(RPC_URL),$(BASE_SEPOLIA_RPC_URL))"; \
	from="$(or $(DEPLOY_BLOCK),0)"; \
	exec_n=$$($(CAST) logs --rpc-url $$rpc --address $(VAULT_ADDRESS) --from-block $$from "SettlementExecuted(bytes32,address,uint256,address)" | grep -c blockHash || true); \
	canc_n=$$($(CAST) logs --rpc-url $$rpc --address $(VAULT_ADDRESS) --from-block $$from "SettlementCancelled(bytes32)" | grep -c blockHash || true); \
	echo "Executed settlements : $$exec_n"; \
	echo "Cancelled settlements: $$canc_n"

.PHONY: sizes
sizes: ## Print compiled contract sizes
	$(FORGE) build --sizes

.PHONY: abi
abi: ## Extract and pretty-print the LiquidityVault ABI
	$(FORGE) inspect LiquidityVault abi | jq .

.PHONY: storage
storage: ## Inspect the LiquidityVault storage layout
	$(FORGE) inspect LiquidityVault storage-layout --pretty
