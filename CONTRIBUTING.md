# Contributing to SonicSphere Contracts

Thank you for your interest. This is an early-stage repository under active development — contributions are welcome but please read these guidelines first.

## Getting started

### Prerequisites

- [Foundry](https://getfoundry.sh/) 1.7 or later
- Git with submodule support

### Setup

```bash
git clone --recurse-submodules https://github.com/thesourcearchitect/sonicsphere-contracts
cd sonicsphere-contracts
make install          # installs forge-std and openzeppelin-contracts
make build            # compiles all contracts
make test             # runs unit + fuzz + invariant suite
```

---

## Development workflow

```bash
make test             # full test suite (unit + fuzz + invariant)
make test-unit        # unit + fuzz only (fast)
make test-invariant   # stateful invariant suite (~2 minutes)
make coverage         # LCOV coverage report
make snapshot         # update .gas-snapshot
make lint             # forge fmt --check
make fmt              # auto-format with forge fmt
```

---

## Coding standards

### Solidity

- **Version**: `^0.8.25` with `cancun` EVM target
- **Formatting**: `forge fmt` (two-space indent, 100-char line limit)
- **Natspec**: all public/external functions must have complete `@notice` and `@dev` annotations
- **Error handling**: use custom errors, not `revert("string")` or `require(cond, "string")`
- **Access control**: all privileged functions must check role before any state mutation
- **Reentrancy**: follow CEI (checks-effects-interactions) strictly; use `nonReentrant` as a second layer
- **Events**: every state-changing function must emit an event

### Tests

- New features require matching unit tests, fuzz tests, and invariant handlers
- Tests live in `test/` and follow the `ContractName.t.sol` naming convention
- Mocks live in `test/mocks/` and are named `Mock<Name>.sol`
- Avoid `vm.assume` filters wider than necessary in fuzz tests
- Do not `console.log` in tests (remove before opening a PR)

### Gas

After any change that modifies gas behaviour:

```bash
make snapshot
```

Commit the updated `.gas-snapshot`. PRs that regress gas by more than 2% without justification will not be merged.

---

## Branching model

| Branch | Purpose |
|---|---|
| `main` | Production-ready; protected |
| `dev` | Integration branch for feature work |
| `feat/<name>` | Individual feature branches off `dev` |
| `fix/<name>` | Bug-fix branches off `main` or `dev` |

---

## Pull requests

1. Branch from `dev` (or `main` for hotfixes).
2. Keep PRs focused — one concern per PR.
3. Ensure `make test` and `make lint` pass locally before opening.
4. Update `.gas-snapshot` if gas changes.
5. Add a brief description of what changed and why.
6. For security-sensitive changes, tag a reviewer explicitly.

### PR checklist

- [ ] `forge build` passes with no errors
- [ ] `make test` — all tests pass
- [ ] `make lint` — no formatting issues
- [ ] `.gas-snapshot` updated if gas changed
- [ ] Natspec added/updated for any new/modified functions
- [ ] Events emitted for all state changes
- [ ] Custom errors added for all new revert conditions

---

## Security issues

**Do not open a public issue for vulnerabilities.**

See [SECURITY.md](./SECURITY.md) for the responsible disclosure process.

---

## License

By contributing, you agree your contributions will be licensed under the [MIT License](./LICENSE).
