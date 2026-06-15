// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @title MockFailingReceiver
/// @notice A test helper contract whose `receive()` function intentionally
///         reverts, simulating a recipient that cannot accept native ETH.
///
///         Used in LiquidityVaultTest to exercise the `TransferFailed` error
///         path in `LiquidityVault.executeSettlement`.
///
/// @dev    Two modes are supported:
///         • REVERT — the default; every ETH transfer attempt reverts.
///         • CONSUME_GAS — reverts after burning a configurable amount of gas,
///           exercising the out-of-gas path in the `.call` execution.
contract MockFailingReceiver {

    enum Mode { REVERT, CONSUME_GAS }

    Mode    public mode;
    uint256 public gasToConsume;

    constructor() {
        mode = Mode.REVERT;
    }

    // ── Configuration ─────────────────────────────────────────────────────────

    /// @notice Switch to gas-consuming mode and set the burn amount.
    function setConsumeGasMode(uint256 gas_) external {
        mode         = Mode.CONSUME_GAS;
        gasToConsume = gas_;
    }

    /// @notice Reset to simple revert mode.
    function setRevertMode() external {
        mode = Mode.REVERT;
    }

    // ── ETH rejection ─────────────────────────────────────────────────────────

    receive() external payable {
        if (mode == Mode.REVERT) {
            revert("MockFailingReceiver: ETH not accepted");
        } else {
            // Burn gas then revert
            uint256 start = gasleft();
            while (gasleft() > start - gasToConsume && gasleft() > 1_000) {
                // spin
            }
            revert("MockFailingReceiver: out of gas");
        }
    }

    fallback() external payable {
        revert("MockFailingReceiver: fallback not accepted");
    }
}
