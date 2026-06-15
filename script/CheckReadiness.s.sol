// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script, console2} from "forge-std/Script.sol";

/// @notice Pre-deployment wallet and environment readiness check.
/// @dev    Run this BEFORE Deploy.s.sol to confirm the deployer wallet is
///         funded and all required env vars are present.
///
///         Usage (read-only, no broadcast needed):
///           forge script script/CheckReadiness.s.sol \
///             --rpc-url base_sepolia
///
///         Exit code 0 = all checks passed, safe to deploy.
///         Exit code 1 = one or more checks failed.
contract CheckReadiness is Script {

    // Estimated deployment gas (conservative upper bound for LiquidityVault + verify)
    uint256 constant DEPLOY_GAS_ESTIMATE = 1_500_000;

    // Minimum recommended vault seed funding
    uint256 constant MIN_VAULT_SEED = 0.01 ether; // testnet default; override via INITIAL_VAULT_FUND

    uint256 private _failures;

    function run() external {
        console2.log("");
        console2.log("====================================================");
        console2.log("  SonicSphere - Pre-Deployment Readiness Check");
        console2.log("====================================================");

        _checkEnvVars();
        _checkDeployerWallet();
        _checkRiskParams();
        _checkAddresses();

        console2.log("");
        console2.log("----------------------------------------------------");
        if (_failures == 0) {
            console2.log("  RESULT: READY TO DEPLOY");
        } else {
            console2.log("  RESULT: NOT READY (%d issue(s) found)", _failures);
            revert("CheckReadiness: fix the issues above before deploying");
        }
        console2.log("====================================================");
        console2.log("");
    }

    // -------------------------------------------------------------------------
    // Check groups
    // -------------------------------------------------------------------------

    function _checkEnvVars() internal {
        console2.log("");
        console2.log("[1] Environment variables");

        _checkEnvSet("ADMIN_ADDRESS");
        _checkEnvSet("GUARDIAN_ADDRESS");
        _checkEnvSet("RELAYER_ADDRESS");
        _checkEnvSet("TX_LIMIT");
        _checkEnvSet("DAILY_CAP");
        _checkEnvSet("DEPLOYER_PRIVATE_KEY");
    }

    function _checkDeployerWallet() internal {
        console2.log("");
        console2.log("[2] Deployer wallet");

        // Derive deployer address from private key
        uint256 pk = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        if (pk == 0) {
            _fail("DEPLOYER_PRIVATE_KEY not set - cannot derive deployer address");
            return;
        }

        address deployer = vm.addr(pk);
        console2.log("  deployer address : %s", deployer);

        uint256 balance = deployer.balance;
        console2.log("  deployer balance : %d wei (%s ETH)",
            balance,
            _toEthString(balance)
        );

        // Estimate deployment cost at current base fee + 10% buffer
        uint256 baseFee    = block.basefee;
        uint256 gasPrice   = baseFee == 0 ? 0.01 gwei : baseFee * 110 / 100;
        uint256 deployCost = DEPLOY_GAS_ESTIMATE * gasPrice;

        console2.log("  base fee         : %d gwei", baseFee / 1 gwei);
        console2.log("  est. deploy cost : %d wei (%s ETH)",
            deployCost,
            _toEthString(deployCost)
        );

        uint256 vaultSeed = vm.envOr("INITIAL_VAULT_FUND", MIN_VAULT_SEED);
        uint256 needed    = deployCost + vaultSeed;

        console2.log("  initial vault fund (INITIAL_VAULT_FUND): %d wei (%s ETH)",
            vaultSeed,
            _toEthString(vaultSeed)
        );
        console2.log("  total needed     : %d wei (%s ETH)",
            needed,
            _toEthString(needed)
        );

        _check(
            "Deployer has enough ETH (deploy gas + initial vault fund)",
            balance >= needed
        );

        if (balance < needed) {
            uint256 shortfall = needed - balance;
            console2.log("  SHORTFALL        : %d wei (%s ETH) - top up deployer wallet",
                shortfall,
                _toEthString(shortfall)
            );
        }
    }

    function _checkRiskParams() internal {
        console2.log("");
        console2.log("[3] Risk parameters");

        uint256 txLimit  = vm.envOr("TX_LIMIT",   uint256(0));
        uint256 dailyCap = vm.envOr("DAILY_CAP",  uint256(0));

        console2.log("  TX_LIMIT  : %d wei (%s ETH)", txLimit,  _toEthString(txLimit));
        console2.log("  DAILY_CAP : %d wei (%s ETH)", dailyCap, _toEthString(dailyCap));

        _check("TX_LIMIT > 0",              txLimit > 0);
        _check("DAILY_CAP > 0",             dailyCap > 0);
        _check("DAILY_CAP >= TX_LIMIT",     dailyCap >= txLimit);

        // Warn if txLimit is very large relative to initial vault fund
        uint256 vaultSeed = vm.envOr("INITIAL_VAULT_FUND", MIN_VAULT_SEED);
        if (txLimit > vaultSeed) {
            console2.log("  WARN: TX_LIMIT (%d) > INITIAL_VAULT_FUND (%d)", txLimit, vaultSeed);
            console2.log("        First settlement will fail unless vault is funded more");
        }
    }

    function _checkAddresses() internal {
        console2.log("");
        console2.log("[4] Role addresses");

        address admin    = vm.envOr("ADMIN_ADDRESS",    address(0));
        address guardian = vm.envOr("GUARDIAN_ADDRESS", address(0));
        address relayer  = vm.envOr("RELAYER_ADDRESS",  address(0));

        console2.log("  ADMIN_ADDRESS    : %s", admin);
        console2.log("  GUARDIAN_ADDRESS : %s", guardian);
        console2.log("  RELAYER_ADDRESS  : %s", relayer);

        _check("ADMIN_ADDRESS is not zero",    admin    != address(0));
        _check("GUARDIAN_ADDRESS is not zero", guardian != address(0));
        _check("RELAYER_ADDRESS is not zero",  relayer  != address(0));
        _check("ADMIN != GUARDIAN",            admin    != guardian);
        _check("ADMIN != RELAYER",             admin    != relayer);
        _check("GUARDIAN != RELAYER",          guardian != relayer);

        // Check if deployer is the admin (common pattern - not required but typical)
        uint256 pk = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        if (pk != 0) {
            address deployer = vm.addr(pk);
            if (deployer != admin) {
                console2.log("  NOTE: deployer (%s) != admin (%s)", deployer, admin);
                console2.log("        Deployer sets admin in constructor. Deployer does NOT need ADMIN_ROLE.");
            }
        }
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _checkEnvSet(string memory name) internal {
        string memory val = vm.envOr(name, string(""));
        bool set = bytes(val).length > 0;
        if (set) {
            console2.log("  [OK] %s is set", name);
        } else {
            console2.log("  [MISSING] %s is not set", name);
            _failures++;
        }
    }

    function _check(string memory description, bool condition) internal {
        if (condition) {
            console2.log("  [OK] %s", description);
        } else {
            console2.log("  [FAIL] %s", description);
            _failures++;
        }
    }

    function _fail(string memory msg) internal {
        console2.log("  [FAIL] %s", msg);
        _failures++;
    }

    /// @dev Returns a rough "X.XX" ETH string from wei (2 decimal places).
    function _toEthString(uint256 wei_) internal pure returns (string memory) {
        uint256 whole     = wei_ / 1 ether;
        uint256 remainder = (wei_ % 1 ether) / 0.01 ether;
        return string(abi.encodePacked(
            _uintToString(whole),
            ".",
            remainder < 10 ? "0" : "",
            _uintToString(remainder)
        ));
    }

    function _uintToString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 tmp = v;
        uint256 len;
        while (tmp != 0) { len++; tmp /= 10; }
        bytes memory buf = new bytes(len);
        for (uint256 i = len; i > 0; i--) {
            buf[i - 1] = bytes1(uint8(48 + v % 10));
            v /= 10;
        }
        return string(buf);
    }
}
