// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {LiquidityVault}   from "../src/LiquidityVault.sol";

/// @notice Guardian script to cancel one or more settlement refs in a
///         single broadcast transaction (batched via a multicall pattern).
///
/// @dev    The broadcaster must hold GUARDIAN_ROLE on the target vault.
///         Refs are passed as a comma-separated hex list via the
///         CANCEL_REFS env var, or individually via the run(address,bytes32[])
///         overload when called programmatically.
///
///         Usage (single ref):
///           VAULT_ADDRESS=0x... CANCEL_REFS=0xabc...def \
///             forge script script/CancelRefs.s.sol --rpc-url base --broadcast
///
///         Usage (multiple refs, comma-separated):
///           VAULT_ADDRESS=0x... \
///           CANCEL_REFS=0xabc...def,0x123...456,0xfed...cba \
///             forge script script/CancelRefs.s.sol --rpc-url base --broadcast
///
///         NOTE: Each cancelSettlement call is a separate transaction in the
///         broadcast. Foundry batches them into a single broadcast sequence.
contract CancelRefs is Script {

    // Entry point: read refs from CANCEL_REFS env var (comma-separated hex)
    function run() external {
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");
        string  memory raw = vm.envString("CANCEL_REFS");
        bytes32[] memory refs = _parseRefs(raw);
        _execute(vaultAddr, refs);
    }

    // Entry point: pass refs directly (for scripting / programmatic use)
    function run(address vaultAddr, bytes32[] calldata refs) external {
        _execute(vaultAddr, refs);
    }

    // -------------------------------------------------------------------------

    function _execute(address vaultAddr, bytes32[] memory refs) internal {
        require(refs.length > 0, "CancelRefs: no refs provided");

        LiquidityVault vault = LiquidityVault(payable(vaultAddr));

        console2.log("================================================");
        console2.log("  CancelRefs");
        console2.log("  vault :", vaultAddr);
        console2.log("  count :", refs.length);
        console2.log("================================================");

        vm.startBroadcast();

        for (uint256 i = 0; i < refs.length; i++) {
            bytes32 ref = refs[i];

            if (vault.isSettled(ref)) {
                console2.log("  [SKIP] already settled - ref %d", i);
                continue;
            }

            vault.cancelSettlement(ref);
            console2.log("  [OK]   cancelled ref %d", i);
        }

        vm.stopBroadcast();

        console2.log("================================================");
        console2.log("  Done. %d ref(s) processed.", refs.length);
        console2.log("================================================");
    }

    // -------------------------------------------------------------------------
    // Internal: parse a comma-separated hex string into bytes32[]
    // Supports refs with or without the "0x" prefix.
    // -------------------------------------------------------------------------

    function _parseRefs(string memory raw) internal pure returns (bytes32[] memory) {
        // Count commas to size the array
        bytes memory b = bytes(raw);
        uint256 count = 1;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == ",") count++;
        }

        bytes32[] memory refs = new bytes32[](count);
        uint256 idx     = 0;
        uint256 start   = 0;

        for (uint256 i = 0; i <= b.length; i++) {
            if (i == b.length || b[i] == ",") {
                // Extract slice [start, i)
                bytes memory slice = new bytes(i - start);
                for (uint256 j = start; j < i; j++) {
                    slice[j - start] = b[j];
                }
                refs[idx++] = _hexToBytes32(string(slice));
                start = i + 1;
            }
        }

        return refs;
    }

    function _hexToBytes32(string memory hexStr) internal pure returns (bytes32) {
        bytes memory b = bytes(hexStr);
        uint256 startIdx = 0;

        // Strip optional "0x" prefix
        if (b.length >= 2 && b[0] == "0" && (b[1] == "x" || b[1] == "X")) {
            startIdx = 2;
        }

        require(b.length - startIdx == 64, "CancelRefs: each ref must be 32 bytes (64 hex chars)");

        bytes32 result;
        for (uint256 i = startIdx; i < b.length; i++) {
            result = result << 4 | bytes32(uint256(_hexCharToNibble(b[i])));
        }
        return result;
    }

    function _hexCharToNibble(bytes1 c) internal pure returns (uint8) {
        if (c >= "0" && c <= "9") return uint8(c) - uint8(bytes1("0"));
        if (c >= "a" && c <= "f") return uint8(c) - uint8(bytes1("a")) + 10;
        if (c >= "A" && c <= "F") return uint8(c) - uint8(bytes1("A")) + 10;
        revert("CancelRefs: invalid hex character");
    }
}
