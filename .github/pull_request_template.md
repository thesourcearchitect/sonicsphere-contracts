## Summary

<!-- One paragraph: what does this PR do and why? -->

## Changes

<!-- Bullet list of what changed. -->

-
-

## Type of change

- [ ] Bug fix
- [ ] New feature / enhancement
- [ ] Test improvement
- [ ] Documentation
- [ ] Tooling / CI
- [ ] Refactor (no behaviour change)

## Testing

- [ ] `forge build` passes
- [ ] `forge test` — all tests pass
- [ ] `forge fmt --check` — no formatting issues
- [ ] `.gas-snapshot` updated (if gas changed)

<!-- Paste the relevant test output below: -->

```
Ran N test suite(s): N passed, 0 failed
```

## Gas impact

<!-- Fill in if gas changed. Leave blank if unchanged. -->

| Function | Before | After | Delta |
|---|---|---|---|
| `executeSettlement` | | | |

## Checklist

- [ ] PR title follows Conventional Commits format (`feat:`, `fix:`, `chore:`, `test:`, `docs:`)
- [ ] Natspec added/updated for new or modified functions
- [ ] Events emitted for all state changes
- [ ] Custom errors added for all new revert conditions
- [ ] No `console.log` left in test files
- [ ] No secrets or addresses committed
