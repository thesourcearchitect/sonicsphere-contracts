// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";

import {IEntryPoint}         from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {MessageHashUtils}    from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {ProtocolAccount} from "../src/ProtocolAccount.sol";

/// @notice Stage-2 fork test (brief §7): validate ProtocolAccount against the
///         REAL canonical EntryPoint v0.7 singleton and live chain state.
/// @dev    Requires BASE_MAINNET_RPC_URL. When it is unset the tests skip
///         cleanly so the default (no-RPC) `forge test` stays green.
contract ProtocolAccountForkTest is Test {
    address internal constant ENTRYPOINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    uint256 internal constant KMS_PK = 0xA11CE;

    bool internal forked;
    IEntryPoint internal entryPoint;
    ProtocolAccount internal account;
    address internal kmsSigner;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            forked = false;
            return;
        }
        vm.createSelectFork(rpc);
        forked = true;

        kmsSigner  = vm.addr(KMS_PK);
        entryPoint = IEntryPoint(ENTRYPOINT_V07);
        account    = new ProtocolAccount(entryPoint, kmsSigner);
    }

    function test_Fork_CanonicalEntryPointHasCode() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        assertGt(ENTRYPOINT_V07.code.length, 0, "no code at canonical EntryPoint singleton");
    }

    function test_Fork_ValidateSignature_AgainstRealEntryPoint() public {
        if (!forked) {
            vm.skip(true);
            return;
        }

        PackedUserOperation memory op = PackedUserOperation({
            sender:             address(account),
            nonce:              entryPoint.getNonce(address(account), 0),
            initCode:           "",
            callData:           "",
            accountGasLimits:   bytes32((uint256(600_000) << 128) | uint256(600_000)),
            preVerificationGas: 100_000,
            gasFees:            bytes32(0),
            paymasterAndData:   "",
            signature:          ""
        });

        bytes32 opHash = entryPoint.getUserOpHash(op);
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(opHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KMS_PK, digest);
        op.signature = abi.encodePacked(r, s, v);

        vm.prank(ENTRYPOINT_V07);
        uint256 vd = account.validateUserOp(op, opHash, 0);
        assertEq(vd, 0, "valid signer should pass against real EntryPoint");
    }
}
