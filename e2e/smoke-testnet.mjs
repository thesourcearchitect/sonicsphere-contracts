// SPDX-License-Identifier: MIT
//
// Stage 4 — LIVE Base Sepolia smoke test of the REAL deployed ProtocolAccount +
// LiquidityVault, driven through a LOCAL Alto bundler pointed at the live network.
//
// WHAT THIS PROVES (and its honest limit):
//   • The deployed account is correctly WIRED: it trusts the canonical EntryPoint
//     v0.7 singleton, its immutable `kmsSigner` == the configured KMS_SIGNER_ADDRESS,
//     and the LiquidityVault has granted it RELAYER_ROLE.
//   • A REAL bundler on the LIVE network reaches the account and ENFORCES its signer:
//     a wrong-key signature and a malformed signature are BOTH rejected at simulation
//     with an AA24 signature error (not AA21 prefund / AA23 validation-revert), and
//     nothing is settled on-chain as a result.
//
//   • The account's HAPPY PATH is intentionally NOT exercised here. A valid settlement
//     UserOperation must be signed by the KMS owner key (== `kmsSigner`), which lives in
//     the operator's KMS and is NEVER available to this environment. That path is driven
//     by the operator's relayer. The full happy path + idempotency is already proven
//     against a real bundler + EntryPoint on a fork of Base Sepolia in run.mjs (Stage 3).
//
// WHY A GAS DEPOSIT IS FUNDED FIRST: EntryPoint v0.7 checks the account's prefund
// (AA21) BEFORE it checks the signature (AA24). With a zero deposit a wrong-sig op
// would be rejected as AA21, masking the signature enforcement we want to prove. We
// therefore pre-fund a small EntryPoint deposit for the account (which also doubles as
// the account's operational gas funding for real settlements). A rejected op never
// touches that deposit.
//
// SAFETY: every signing key used here is a FRESH RANDOM throwaway — deliberately NOT the
// KMS key. The only secrets read are BASE_SEPOLIA_RPC_URL + DEPLOYER_PRIVATE_KEY, which
// are never printed.

import { spawn } from "node:child_process";
import { connect } from "node:net";
import { readFileSync, openSync, writeFileSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  createPublicClient, createWalletClient, http,
  parseEther, parseGwei, formatEther,
  encodeFunctionData, toHex, keccak256, toBytes, getAddress,
  getContractAddress, concat,
} from "viem";
import { privateKeyToAccount, generatePrivateKey } from "viem/accounts";
import { baseSepolia } from "viem/chains";
import { entryPoint07Address, entryPoint07Abi, toPackedUserOperation } from "viem/account-abstraction";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------
const __dirname = dirname(fileURLToPath(import.meta.url));
const CONTRACTS_DIR = join(__dirname, "..");

const BUNDLER_PORT = Number(process.env.BUNDLER_PORT ?? 4337);
const BUNDLER_URL = `http://127.0.0.1:${BUNDLER_PORT}`;

// Final pass/fail summary is mirrored here so results survive even if stdout is lost.
const RESULT_FILE = join(__dirname, ".smoke-result.txt");

const RPC_URL = process.env.BASE_SEPOLIA_RPC_URL;
if (!RPC_URL) {
  console.error("FATAL: BASE_SEPOLIA_RPC_URL is not set (needed to reach the live network).");
  process.exit(2);
}

const RAW_DEPLOYER = process.env.DEPLOYER_PRIVATE_KEY;
if (!RAW_DEPLOYER) {
  console.error("FATAL: DEPLOYER_PRIVATE_KEY is not set (needed to fund the bundler executor + the account gas deposit).");
  process.exit(2);
}
const DEPLOYER_KEY = "0x" + RAW_DEPLOYER.replace(/^0x/, "");

// Real deployed addresses (overridable via env; defaults are the Stage-4 deployment).
const VAULT_ADDR = getAddress(process.env.VAULT_ADDRESS ?? "0x75d56B48b3aF6d2DD1D0B15C04e166ed852A8f26");
const ACCOUNT_ADDR = getAddress(process.env.PROTOCOL_ACCOUNT_ADDRESS ?? "0x58d291a766Ae60D47FAb33686C51853F5020967A");
const ENTRYPOINT = getAddress(entryPoint07Address);
if (!process.env.KMS_SIGNER_ADDRESS) {
  console.error("FATAL: KMS_SIGNER_ADDRESS is not set (needed to assert the account's baked-in signer).");
  process.exit(2);
}
const EXPECTED_KMS = getAddress(process.env.KMS_SIGNER_ADDRESS);

// Fresh throwaway EOA for the bundler executor (a rejected op is never included, so it
// never actually fronts gas — funded minimally just so Alto starts).
const EXECUTOR_KEY = generatePrivateKey();
// Alto derives the CREATE2 salt for its simulation-helper contracts from the UTILITY
// key's ADDRESS. We use a STABLE utility key (persisted to a gitignored file) so the
// helper contracts we pre-deploy below keep the same addresses and are reused across
// runs instead of needing redeployment each run. Still a throwaway (gas only, swept back).
const UTILITY_KEY_FILE = join(__dirname, ".alto-utility-key");
function loadOrCreateUtilityKey() {
  try {
    const k = readFileSync(UTILITY_KEY_FILE, "utf8").trim();
    if (/^0x[0-9a-fA-F]{64}$/.test(k)) return k;
  } catch {}
  const k = generatePrivateKey();
  writeFileSync(UTILITY_KEY_FILE, k + "\n", { mode: 0o600 });
  return k;
}
const UTILITY_KEY = loadOrCreateUtilityKey();

// Small EntryPoint gas deposit for the account so the prefund check (AA21) cannot
// preempt the signature check (AA24). Ample headroom for Base Sepolia gas prices.
const ACCOUNT_DEPOSIT = parseEther("0.003");
// Generous, fixed gas limits: the op is rejected at signature validation, so exact
// values are irrelevant — they only need to clear the bundler's minimums.
const GAS_LIMITS = { callGasLimit: 300000n, verificationGasLimit: 300000n, preVerificationGas: 200000n };
// Tiny settlement amount used only to shape a well-formed op (never executed).
const AMOUNT = parseEther("0.0005");
const RECIPIENT = getAddress("0x90F79bf6EB2c4f870365E785982E1f101E93b906");
// Explicit, generous fees for every deployer-funded tx so they (a) mine promptly and
// (b) REPLACE any stuck/underpriced pending tx left by a previously-interrupted run.
const FUND_FEES = { maxFeePerGas: parseGwei("3"), maxPriorityFeePerGas: parseGwei("1.5") };
// Lower fees for the one-time, LARGE simulation-contract deploys (~5M gas each): a high
// maxFeePerGas would reserve too much balance up front. They run on a clean mempool (no
// stuck tx to outbid) with explicit nonces, so a modest fee still mines fine.
const DEPLOY_FEES = { maxFeePerGas: parseGwei("1"), maxPriorityFeePerGas: parseGwei("0.1") };

// ---------------------------------------------------------------------------
// Tiny test framework
// ---------------------------------------------------------------------------
let passed = 0, failed = 0;
const results = [];
function check(name, cond, detail = "") {
  if (cond) { passed++; results.push(`  \u2713 ${name}`); }
  else { failed++; results.push(`  \u2717 ${name}${detail ? `  -> ${detail}` : ""}`); }
}
function log(...a) { console.log(...a); }
function writeResult(extra = "") {
  const lines = [
    `SonicSphere Stage 4 — LIVE Base Sepolia bundler smoke test`,
    `${passed} passed, ${failed} failed`,
    ``,
    ...results,
  ];
  if (extra) lines.push(``, extra);
  try { writeFileSync(RESULT_FILE, lines.join("\n") + "\n"); } catch {}
}

// Classify a bundler rejection.
const isSigFailure = (m = "") => /aa24/i.test(m) || /signature/i.test(m);
const isAA23Revert = (m = "") => /aa23/i.test(m);
const isAA21Prefund = (m = "") => /aa21/i.test(m) || /prefund/i.test(m);

// ---------------------------------------------------------------------------
// Artifacts (compiled by forge into ../out)
// ---------------------------------------------------------------------------
function loadArtifact(rel) {
  const j = JSON.parse(readFileSync(join(CONTRACTS_DIR, "out", rel), "utf8"));
  return { abi: j.abi, bytecode: j.bytecode.object };
}
const VAULT = loadArtifact("LiquidityVault.sol/LiquidityVault.json");
const ACCOUNT = loadArtifact("ProtocolAccount.sol/ProtocolAccount.json");

// ---------------------------------------------------------------------------
// Process management
// ---------------------------------------------------------------------------
const children = [];
function spawnProc(label, cmd, args, env = {}) {
  const logPath = join(__dirname, `.${label}.log`);
  const fd = openSync(logPath, "w");
  const child = spawn(cmd, args, { stdio: ["ignore", fd, fd], env: { ...process.env, ...env } });
  child.on("exit", (code) => { if (code && code !== 0 && !shuttingDown) log(`[${label}] exited code=${code} (see ${logPath})`); });
  children.push({ label, child });
  return { child, logPath };
}
let shuttingDown = false;
function teardown() {
  shuttingDown = true;
  for (const { child } of children) { try { child.kill("SIGKILL"); } catch {} }
}
process.on("SIGINT", () => { teardown(); process.exit(130); });
process.on("SIGTERM", () => { teardown(); process.exit(143); });

function portInUse(port) {
  return new Promise((resolve) => {
    const sock = connect({ host: "127.0.0.1", port });
    const finish = (inUse) => { try { sock.destroy(); } catch {} resolve(inUse); };
    sock.setTimeout(1000);
    sock.once("connect", () => finish(true));
    sock.once("timeout", () => finish(false));
    sock.once("error", () => finish(false));
  });
}
async function assertPortFree(port, label) {
  if (await portInUse(port)) {
    throw new Error(`port ${port} (${label}) is already in use. Stop the stale process (pkill alto) or set ${label}_PORT, then re-run.`);
  }
}

// ---------------------------------------------------------------------------
// JSON-RPC helpers
// ---------------------------------------------------------------------------
async function rpc(url, method, params) {
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const j = await res.json();
  if (j.error) { const e = new Error(j.error.message || "rpc error"); e.data = j.error; throw e; }
  return j.result;
}
const bundlerRpc = (m, p) => rpc(BUNDLER_URL, m, p);

async function waitFor(label, fn, { tries = 90, delay = 1000, fatal } = {}) {
  let lastErr;
  for (let i = 0; i < tries; i++) {
    if (fatal) { const reason = fatal(); if (reason) throw new Error(`${label} fatal: ${reason}`); }
    try { return await fn(); } catch (e) { lastErr = e; await sleep(delay); }
  }
  throw new Error(`${label} not ready after ${tries} tries: ${lastErr?.message ?? lastErr}`);
}

// ---------------------------------------------------------------------------
// viem clients (LIVE network)
// ---------------------------------------------------------------------------
const deployer = privateKeyToAccount(DEPLOYER_KEY);
const EXECUTOR_ADDR = privateKeyToAccount(EXECUTOR_KEY).address;
const UTILITY_ADDR = privateKeyToAccount(UTILITY_KEY).address;
const pub = createPublicClient({ chain: baseSepolia, transport: http(RPC_URL) });
const wallet = createWalletClient({ account: deployer, chain: baseSepolia, transport: http(RPC_URL) });

async function sendTx(req) {
  const hash = await wallet.writeContract(req);
  return pub.waitForTransactionReceipt({ hash });
}

// Return a throwaway EOA's leftover balance to the deployer (called after teardown, so
// Alto is dead and there is no nonce contention). Best-effort: never fails the run.
// Uses fixed FUND_FEES and a 3x gas buffer so value + actual gas can never exceed balance.
async function sweepBack(key, label) {
  try {
    const acct = privateKeyToAccount(key);
    const bal = await pub.getBalance({ address: acct.address });
    const { maxFeePerGas, maxPriorityFeePerGas } = FUND_FEES;
    const cost = 21000n * maxFeePerGas * 3n;
    if (bal <= cost) return;
    const w = createWalletClient({ account: acct, chain: baseSepolia, transport: http(RPC_URL) });
    const hash = await w.sendTransaction({ to: deployer.address, value: bal - cost, gas: 21000n, maxFeePerGas, maxPriorityFeePerGas });
    await pub.waitForTransactionReceipt({ hash });
    log(`    swept ${label} leftover (~${formatEther(bal - cost)} ETH) back to deployer`);
  } catch (e) { log(`    sweep ${label} skipped (non-fatal): ${(e?.message ?? String(e)).slice(0, 120)}`); }
}

// Replace any stuck pending deployer txs (pending nonce > latest mined nonce) — left by a
// previously-interrupted run — with high-fee 0-value self-transfers, so funding starts clean.
async function clearStuckNonces() {
  const latest = await pub.getTransactionCount({ address: deployer.address, blockTag: "latest" });
  const pending = await pub.getTransactionCount({ address: deployer.address, blockTag: "pending" });
  if (pending <= latest) return;
  log(`    clearing ${pending - latest} stuck pending deployer tx(s) at nonce(s) ${latest}..${pending - 1}...`);
  const hashes = [];
  for (let n = latest; n < pending; n++) {
    hashes.push(await wallet.sendTransaction({ to: deployer.address, value: 0n, nonce: n, gas: 21000n, ...FUND_FEES }));
  }
  for (const h of hashes) { try { await pub.waitForTransactionReceipt({ hash: h }); } catch {} }
}

// ---------------------------------------------------------------------------
// Pre-deploy Alto's CREATE2 simulation-helper contracts (PimlicoSimulations +
// EntryPointSimulations 0.7/0.8/0.9). Alto deploys these itself on boot, but on Base
// Sepolia's fast-preconfirmation ("flashblock") RPC its back-to-back deploys reuse the
// same nonce -> "replacement transaction underpriced" -> Alto exits(1). We deploy them
// ourselves with EXPLICIT sequential nonces via the same deterministic CREATE2 factory
// (the address is msg.sender-independent, so they land exactly where Alto expects). With
// all four present, Alto's deploySimulationsContract early-returns and the bundler boots.
// The CREATE2 salt MUST match Alto's: keccak256(utility EOA address).
// ---------------------------------------------------------------------------
const DETERMINISTIC_DEPLOYER = getAddress("0x4e59b44847b379578588920cA78FbF26c0B4956C");
const ALTO_CONTRACTS_DIR = join(__dirname, "node_modules/@pimlico/alto/esm/contracts");
const SIM_CONTRACTS = [
  ["PimlicoSimulations",        "PimlicoSimulations.sol/PimlicoSimulations.json"],
  ["EntryPointSimulations 0.7", "EntryPointSimulations.sol/EntryPointSimulations07.json"],
  ["EntryPointSimulations 0.8", "EntryPointSimulations.sol/EntryPointSimulations08.json"],
  ["EntryPointSimulations 0.9", "EntryPointSimulations.sol/EntryPointSimulations09.json"],
];
function simBytecode(rel) {
  return JSON.parse(readFileSync(join(ALTO_CONTRACTS_DIR, rel), "utf8")).bytecode.object;
}
async function ensureSimulationContracts(utilityAddress, startNonce) {
  const salt = keccak256(utilityAddress);
  const missing = [];
  for (const [name, rel] of SIM_CONTRACTS) {
    const bytecode = simBytecode(rel);
    const address = getContractAddress({ opcode: "CREATE2", bytecode, salt, from: DETERMINISTIC_DEPLOYER });
    const code = await pub.getCode({ address });
    if (!code || code === "0x") missing.push({ name, bytecode, address });
  }
  if (missing.length === 0) {
    log("    all 4 Alto simulation contracts already present (skipping deploy)");
    return startNonce;
  }
  log(`    pre-deploying ${missing.length} Alto simulation contract(s) (one-time)...`);
  let nonce = startNonce;
  for (const { name, bytecode, address } of missing) {
    log(`      ${name} -> ${address} (nonce ${nonce})`);
    const hash = await wallet.sendTransaction({ to: DETERMINISTIC_DEPLOYER, data: concat([salt, bytecode]), nonce: nonce++, ...DEPLOY_FEES });
    await pub.waitForTransactionReceipt({ hash });
    const code = await pub.getCode({ address });
    if (!code || code === "0x") throw new Error(`simulation contract ${name} did not deploy at ${address}`);
  }
  return nonce;
}

// ---------------------------------------------------------------------------
// UserOperation helpers (raw v0.7)
// ---------------------------------------------------------------------------
function buildCallData(ref, recipient, amount) {
  const inner = encodeFunctionData({ abi: VAULT.abi, functionName: "executeSettlement", args: [ref, recipient, amount] });
  return encodeFunctionData({ abi: ACCOUNT.abi, functionName: "execute", args: [VAULT_ADDR, 0n, inner] });
}

async function currentFees() {
  try {
    const gp = await bundlerRpc("pimlico_getUserOperationGasPrice", []);
    return { maxFeePerGas: BigInt(gp.fast.maxFeePerGas), maxPriorityFeePerGas: BigInt(gp.fast.maxPriorityFeePerGas) };
  } catch {
    const blk = await pub.getBlock();
    const base = blk.baseFeePerGas ?? parseGwei("0.1");
    const prio = parseGwei("0.1");
    return { maxFeePerGas: base * 2n + prio, maxPriorityFeePerGas: prio };
  }
}

function hexOp(o) {
  return {
    sender: o.sender,
    nonce: toHex(o.nonce),
    callData: o.callData,
    callGasLimit: toHex(o.callGasLimit),
    verificationGasLimit: toHex(o.verificationGasLimit),
    preVerificationGas: toHex(o.preVerificationGas),
    maxFeePerGas: toHex(o.maxFeePerGas),
    maxPriorityFeePerGas: toHex(o.maxPriorityFeePerGas),
    signature: o.signature,
  };
}

async function userOpHash(o) {
  const packed = toPackedUserOperation({
    sender: o.sender, nonce: o.nonce, callData: o.callData,
    callGasLimit: o.callGasLimit, verificationGasLimit: o.verificationGasLimit,
    preVerificationGas: o.preVerificationGas,
    maxFeePerGas: o.maxFeePerGas, maxPriorityFeePerGas: o.maxPriorityFeePerGas,
    signature: o.signature ?? "0x",
  });
  return pub.readContract({ address: ENTRYPOINT, abi: entryPoint07Abi, functionName: "getUserOpHash", args: [packed] });
}

// Build a fully-formed op. `signer` signs the real userOpHash; `rawSignature` overrides
// (used for the malformed-signature case).
async function makeOp({ ref, signer, rawSignature }) {
  const { maxFeePerGas, maxPriorityFeePerGas } = await currentFees();
  const nonce = await pub.readContract({ address: ENTRYPOINT, abi: entryPoint07Abi, functionName: "getNonce", args: [ACCOUNT_ADDR, 0n] });
  const base = {
    sender: ACCOUNT_ADDR,
    nonce,
    callData: buildCallData(ref, RECIPIENT, AMOUNT),
    maxFeePerGas, maxPriorityFeePerGas,
    ...GAS_LIMITS,
  };
  const h = await userOpHash(base);
  const signature = rawSignature ?? await signer.signMessage({ message: { raw: h } });
  return { op: hexOp({ ...base, signature }), hash: h };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function main() {
  log(`\n=== SonicSphere Stage 4 — LIVE Base Sepolia bundler smoke test ===`);
  log(`network RPC: <live Base Sepolia>   bundler: ${BUNDLER_URL}`);
  log(`vault  : ${VAULT_ADDR}`);
  log(`account: ${ACCOUNT_ADDR}`);
  log(`entryPt: ${ENTRYPOINT}\n`);

  await assertPortFree(BUNDLER_PORT, "BUNDLER");

  // 1) Live connectivity ---------------------------------------------------------
  log("[1] checking live network + deployed code...");
  const chainId = await pub.getChainId();
  check("connected to Base Sepolia (chainId 84532)", chainId === 84532, `got ${chainId}`);
  const epCode = await pub.getBytecode({ address: ENTRYPOINT });
  check("canonical EntryPoint v0.7 present on live network", !!epCode && epCode !== "0x");
  const acctCode = await pub.getBytecode({ address: ACCOUNT_ADDR });
  check("ProtocolAccount is deployed (has code)", !!acctCode && acctCode !== "0x");
  const vaultCode = await pub.getBytecode({ address: VAULT_ADDR });
  check("LiquidityVault is deployed (has code)", !!vaultCode && vaultCode !== "0x");

  // 2) On-chain wiring -----------------------------------------------------------
  log("[2] verifying on-chain wiring...");
  const acctEntryPoint = await pub.readContract({ address: ACCOUNT_ADDR, abi: ACCOUNT.abi, functionName: "entryPoint" });
  check("account.entryPoint() == canonical v0.7 singleton", getAddress(acctEntryPoint) === ENTRYPOINT, acctEntryPoint);
  const acctSigner = await pub.readContract({ address: ACCOUNT_ADDR, abi: ACCOUNT.abi, functionName: "kmsSigner" });
  check("account.kmsSigner() == configured KMS_SIGNER_ADDRESS", getAddress(acctSigner) === EXPECTED_KMS, `${acctSigner} vs ${EXPECTED_KMS}`);
  const RELAYER_ROLE = await pub.readContract({ address: VAULT_ADDR, abi: VAULT.abi, functionName: "RELAYER_ROLE" });
  const hasRole = await pub.readContract({ address: VAULT_ADDR, abi: VAULT.abi, functionName: "hasRole", args: [RELAYER_ROLE, ACCOUNT_ADDR] });
  check("vault grants RELAYER_ROLE to the account", hasRole === true);
  const paused = await pub.readContract({ address: VAULT_ADDR, abi: VAULT.abi, functionName: "paused" });
  check("vault is not paused", paused === false);
  const txLimit = await pub.readContract({ address: VAULT_ADDR, abi: VAULT.abi, functionName: "txLimit" });
  const dailyCap = await pub.readContract({ address: VAULT_ADDR, abi: VAULT.abi, functionName: "dailyCap" });
  log(`    caps: txLimit=${formatEther(txLimit)} ETH  dailyCap=${formatEther(dailyCap)} ETH`);

  // 3) Pre-deploy Alto sim contracts + fund bundler EOAs + account gas deposit -----
  log("[3] ensuring Alto sim contracts + funding bundler EOAs + account gas deposit...");
  // ONE locally-managed, explicit nonce sequence for every deployer tx below. Base
  // Sepolia's fast-preconfirmation RPC lags eth_getTransactionCount, so relying on
  // auto-nonce causes "replacement underpriced" collisions; explicit nonces avoid that.
  await clearStuckNonces();
  let nonce = await pub.getTransactionCount({ address: deployer.address, blockTag: "pending" });
  // Pre-deploy the bundler's CREATE2 simulation helpers ourselves (Alto would otherwise
  // crash deploying them on this chain). Runs once; later runs find them present and skip.
  // Done first, while the deployer still has its full balance.
  nonce = await ensureSimulationContracts(UTILITY_ADDR, nonce);
  // Fund the throwaway bundler EOAs (both swept back to the deployer at the end, so this
  // is not a real spend). With the sim helpers pre-deployed, the utility EOA only needs
  // a little gas for Alto's tiny startup checks.
  await pub.waitForTransactionReceipt({ hash: await wallet.sendTransaction({ to: EXECUTOR_ADDR, value: parseEther("0.003"), nonce: nonce++, gas: 21000n, ...FUND_FEES }) });
  await pub.waitForTransactionReceipt({ hash: await wallet.sendTransaction({ to: UTILITY_ADDR, value: parseEther("0.005"), nonce: nonce++, gas: 21000n, ...FUND_FEES }) });
  const depBefore = await pub.readContract({ address: ENTRYPOINT, abi: entryPoint07Abi, functionName: "balanceOf", args: [ACCOUNT_ADDR] });
  if (depBefore < ACCOUNT_DEPOSIT) {
    await sendTx({ address: ENTRYPOINT, abi: entryPoint07Abi, functionName: "depositTo", args: [ACCOUNT_ADDR], value: ACCOUNT_DEPOSIT - depBefore, nonce: nonce++, maxFeePerGas: FUND_FEES.maxFeePerGas, maxPriorityFeePerGas: FUND_FEES.maxPriorityFeePerGas });
  }
  const dep = await pub.readContract({ address: ENTRYPOINT, abi: entryPoint07Abi, functionName: "balanceOf", args: [ACCOUNT_ADDR] });
  check("account EntryPoint gas deposit is funded (so AA21 cannot mask AA24)", dep >= ACCOUNT_DEPOSIT, `deposit=${formatEther(dep)} ETH`);

  // 4) Local Alto bundler against the LIVE network -------------------------------
  log("[4] starting local Alto bundler against the live network...");
  const altoBin = join(__dirname, "node_modules", ".bin", "alto");
  const { child: altoChild } = spawnProc("alto", altoBin, [
    "--entrypoints", ENTRYPOINT,
    "--rpc-url", RPC_URL,
    "--executor-private-keys", EXECUTOR_KEY,
    "--utility-private-key", UTILITY_KEY,
    "--port", String(BUNDLER_PORT),
    "--safe-mode", "false",
  ]);
  await waitFor("alto", async () => {
    const eps = await bundlerRpc("eth_supportedEntryPoints", []);
    if (!eps?.length) throw new Error("no entrypoints yet");
    return eps;
  }, {
    tries: 150, delay: 1000,
    fatal: () => altoChild.exitCode !== null ? `bundler process exited early (code=${altoChild.exitCode}); see e2e/.alto.log` : null,
  });
  log("    bundler is up.\n");

  // 5) Negative tests against the REAL account -----------------------------------
  // (a) Wrong-key signature -> must be rejected as a SIGNATURE failure (AA24).
  log("[5a] wrong-key signature: must be rejected at simulation (AA24)...");
  const REF1 = keccak256(toBytes(`stage4-smoke-wrongkey-${Date.now()}`));
  const wrongSigner = privateKeyToAccount(generatePrivateKey());
  const wrong = await makeOp({ ref: REF1, signer: wrongSigner });
  let wrongRejected = false, wrongErr = "";
  try { await bundlerRpc("eth_sendUserOperation", [wrong.op, ENTRYPOINT]); }
  catch (e) { wrongRejected = true; wrongErr = (e.data?.message || e.message || "").slice(0, 200); }
  check("wrong-signature op REJECTED pre-inclusion", wrongRejected, wrongRejected ? wrongErr : "bundler ACCEPTED a bad signature!");
  check("rejection is a SIGNATURE failure (AA24), not AA21 prefund / AA23 revert",
    wrongRejected && isSigFailure(wrongErr) && !isAA21Prefund(wrongErr) && !isAA23Revert(wrongErr), wrongErr || "(no error captured)");
  const ref1Settled = await pub.readContract({ address: VAULT_ADDR, abi: VAULT.abi, functionName: "isSettled", args: [REF1] });
  check("wrong-signature op did NOT settle anything on the real vault", ref1Settled === false);

  // (b) Malformed (garbage) signature -> also AA24, proving ECDSA.tryRecover stays clean.
  log("[5b] malformed signature: must be rejected at simulation (AA24, not AA23)...");
  const REF2 = keccak256(toBytes(`stage4-smoke-malformed-${Date.now()}`));
  const malformed = await makeOp({ ref: REF2, signer: wrongSigner, rawSignature: "0xdeadbeef" });
  let malformedRejected = false, malformedErr = "";
  try { await bundlerRpc("eth_sendUserOperation", [malformed.op, ENTRYPOINT]); }
  catch (e) { malformedRejected = true; malformedErr = (e.data?.message || e.message || "").slice(0, 200); }
  check("malformed-signature op REJECTED at simulation", malformedRejected, malformedRejected ? malformedErr : "bundler ACCEPTED a malformed signature!");
  check("malformed-signature is an AA24 sig failure, NOT an AA23 validation revert",
    malformedRejected && isSigFailure(malformedErr) && !isAA23Revert(malformedErr) && !isAA21Prefund(malformedErr), malformedErr || "(no error captured)");
  const ref2Settled = await pub.readContract({ address: VAULT_ADDR, abi: VAULT.abi, functionName: "isSettled", args: [REF2] });
  check("malformed-signature op did NOT settle anything on the real vault", ref2Settled === false);

  log(`\n    NOTE: the account's happy path (a VALID settlement) requires a signature from the`);
  log(`    KMS owner key and is driven by the operator's relayer — never from this environment.`);
}

// ---------------------------------------------------------------------------
main()
  .then(async () => {
    log(`\n=== RESULTS ===`);
    results.forEach((r) => log(r));
    log(`\n${passed} passed, ${failed} failed`);
    teardown();
    await sleep(1500);
    await sweepBack(EXECUTOR_KEY, "executor");
    await sweepBack(UTILITY_KEY, "utility");
    writeResult();
    process.exit(failed === 0 ? 0 : 1);
  })
  .catch(async (e) => {
    log(`\nFATAL: ${e?.stack || e}`);
    results.forEach((r) => log(r));
    teardown();
    await sleep(1500);
    try { await sweepBack(EXECUTOR_KEY, "executor"); await sweepBack(UTILITY_KEY, "utility"); } catch {}
    writeResult(`FATAL: ${e?.message || e}`);
    process.exit(1);
  });
