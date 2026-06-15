---
name: Bug report
about: Report a bug in the contract or scripts
title: "[BUG] "
labels: bug
assignees: ""
---

## Description

<!-- A clear, concise description of the bug. -->

## Environment

- Foundry version: <!-- forge --version -->
- Solc version: 0.8.25
- Network: <!-- Base Sepolia / Base Mainnet / Anvil -->
- Contract address: <!-- if applicable -->

## Steps to reproduce

1.
2.
3.

## Expected behaviour

<!-- What you expected to happen. -->

## Actual behaviour

<!-- What actually happened. Include error messages and stack traces. -->

## Proof of concept

<!-- Paste a minimal Foundry test that reproduces the issue, if possible. -->

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {LiquidityVault} from "src/LiquidityVault.sol";

contract BugReproTest is Test {
    function test_ReproduceBug() public {
        // ...
    }
}
```

## Additional context

<!-- Any other relevant information. -->

---

> **Security issue?** Do not open a public issue — see [SECURITY.md](../../SECURITY.md) for the private disclosure process.
