// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {IEntryPoint}      from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {ProtocolAccount}  from "../src/ProtocolAccount.sol";

/// @notice Deployment script for the Phase 2 ProtocolAccount (ERC-4337 v0.7).
/// @dev    Reads parameters from the environment:
///           • KMS_SIGNER_ADDRESS — PUBLIC address of the relayer's KMS owner key
///             (NEVER a private key).
///           • ENTRYPOINT_ADDRESS — optional; defaults to the canonical v0.7
///             singleton, which is identical on Base and Base Sepolia.
///           • DEPLOYER_PRIVATE_KEY — gas-paying deployer.
///
///         Run on Base Sepolia (testnet):
///           forge script script/DeployProtocolAccount.s.sol \
///             --rpc-url base_sepolia --broadcast --verify -vvvv
///
///         After deploying, wire it to the vault with GrantRelayer.s.sol, then
///         hand the deployed address + ABI + KMS signer address back to the
///         private relayer side (brief §8).
contract DeployProtocolAccount is Script {
    address internal constant DEFAULT_ENTRYPOINT_V07 =
        0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    function run() external returns (ProtocolAccount account) {
        address entryPoint = vm.envOr("ENTRYPOINT_ADDRESS", DEFAULT_ENTRYPOINT_V07);
        address kmsSigner  = vm.envAddress("KMS_SIGNER_ADDRESS");

        console2.log("Deploying ProtocolAccount");
        console2.log("  entryPoint :", entryPoint);
        console2.log("  kmsSigner  :", kmsSigner);

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        account = new ProtocolAccount(IEntryPoint(entryPoint), kmsSigner);
        vm.stopBroadcast();

        console2.log("ProtocolAccount deployed at:", address(account));
    }
}
