// SPDX-License-Identifier: MIT
//
// Stage 3 — Bundler-in-the-loop E2E harness for the SonicSphere settlement bridge.
//
// WHY THIS EXISTS (handoff brief §7): `forge test` drives EntryPoint.handleOps()
// directly, so it SKIPS the ERC-7562 validation rules a real alt-mempool bundler
// enforces. A green `forge test` does NOT prove a bundler will accept the op.
// This harness proves it end-to-end against a REAL bundler (Pimlico's Alto) and a
// REAL EntryPoint v0.7 singleton, on a local Anvil fork of Base Sepolia. LOCAL
// ONLY — nothing is deployed to any public network in this stage.
//
// FLOW:
//   anvil --fork-url <Base Sepolia>   (canonical EntryPoint v0.7 already exists)
//     -> deploy fresh LiquidityVault + ProtocolAccount
//     -> grant the vault's RELAYER_ROLE to the ProtocolAccount
//     -> fund the vault (ETH to release) + the account's EntryPoint gas deposit
//     -> run Alto bundler against the node
//     -> drive UserOperations via raw eth_{estimate,send}UserOperation / receipt
//
// NOTE ON NAMING: the brief's prose says `RELEASER_ROLE` / `releaseFunds`, but the
// REAL Phase-1 vault uses `RELAYER_ROLE` + `executeSettlement(bytes32,address,uint256)`.
// This harness wires to the actual on-chain interface.
//
// SAFETY: the "KMS" signer is a FRESH RANDOM throwaway key generated per run — it
// is NEVER a real KMS key. The executor/deployer keys are the universal, PUBLIC
// Anvil dev keys (not secrets). The only secret used is BASE_SEPOLIA_RPC_URL, read
// from the environment and passed straight to anvil (never printed).

import { spawn } from "node:child_process";
import { connect } from "node:net";
import { readFileSync, openSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  createPublicClient, createWalletClient, http,
  parseEther, parseGwei, formatEther,
  encodeFunctionData, toHex, keccak256, toBytes, getAddress,
} from "viem";
import { privateKeyToAccount, generatePrivateKey } from "viem/accounts";
import { baseSepolia } from "viem/chains";
import { entryPoint07Address, entryPoint07Abi, toPackedUserOperation } from "viem/account-abstraction";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------
const __dirname = dirname(fileURLToPath(import.meta.url));
const CONTRACTS_DIR = join(__dirname, "..");

const ANVIL_PORT = Number(process.env.ANVIL_PORT ?? 8545);
const BUNDLER_PORT = Number(process.env.BUNDLER_PORT ?? 4337);
const NODE_URL = `http://127.0.0.1:${ANVIL_PORT}`;
const BUNDLER_URL = `http://127.0.0.1:${BUNDLER_PORT}`;

// Alto safe-mode enforces the full ERC-7562 rule set, but that requires the node
// to support custom validation tracing. Anvil does not, so safe-mode is OFF by
// default (this is exactly how Pimlico's own anvil-based test env runs). Even with
// it off, the bundler still runs eth_call-based validation simulation, which is
// what surfaces AA23 (bad signature) / AA24 (validation revert). Set SAFE_MODE=true
// to attempt full enforcement against a tracing-capable node.
const SAFE_MODE = (process.env.SAFE_MODE ?? "false") === "true";

const RPC_URL = process.env.BASE_SEPOLIA_RPC_URL;
if (!RPC_URL) {
  console.error("FATAL: BASE_SEPOLIA_RPC_URL is not set (needed to fork Base Sepolia).");
  process.exit(2);
}

// Funded EOAs (deployer + bundler executor/utility) are FRESH random keys generated
// per run — deliberately NOT the well-known Anvil dev keys. Those standard addresses
// carry real Base Sepolia state on the fork (high nonce, ~0 balance) that anvil
// lazily loads on first access, OVERWRITING any anvil_setBalance override and
// starving the bundler's executor mid-run. Fresh addresses have no forked state, so
// setBalance sticks and their nonces start at 0.
const DEPLOYER_KEY = generatePrivateKey();
const EXECUTOR_KEY = generatePrivateKey();
const UTILITY_KEY  = generatePrivateKey();

// Plain payout / role-placeholder targets — never transaction senders, so their
// forked state is irrelevant. Standard PUBLIC Anvil dev addresses.
const RECIPIENT = getAddress("0x90F79bf6EB2c4f870365E785982E1f101E93b906");           // acct3
const PLACEHOLDER_RELAYER = getAddress("0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65"); // acct4

// Staging risk caps (small, mirrors Stage-4 guidance).
const TX_LIMIT = parseEther("0.1");
const DAILY_CAP = parseEther("1");

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

// Classify a bundler rejection. ProtocolAccount uses ECDSA.tryRecover, so a wrong
// OR malformed signature maps to SIG_VALIDATION_FAILED -> the bundler rejects the op
// at simulation with an AA24 signature error (NOT an AA23 validation revert).
const isSigFailure = (m = "") => /aa24/i.test(m) || /signature/i.test(m);
const isAA23Revert = (m = "") => /aa23/i.test(m);

// ---------------------------------------------------------------------------
// Artifacts (compiled by forge into ../out)
// ---------------------------------------------------------------------------
function loadArtifact(rel) {
  const p = join(CONTRACTS_DIR, "out", rel);
  const j = JSON.parse(readFileSync(p, "utf8"));
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

// Refuse to run if our ports are already taken — otherwise waitFor() could attach
// to a STALE anvil/alto from a previous run and report misleading results.
function portInUse(port) {
  return new Promise((resolve) => {
    const sock = connect({ host: "127.0.0.1", port });
    const finish = (inUse) => { try { sock.destroy(); } catch {} resolve(inUse); };
    sock.setTimeout(1000);
    sock.once("connect", () => finish(true));    // something is listening
    sock.once("timeout", () => finish(false));
    sock.once("error", () => finish(false));     // ECONNREFUSED => free
  });
}
async function assertPortFree(port, label) {
  if (await portInUse(port)) {
    throw new Error(`port ${port} (${label}) is already in use. Stop the stale process (e.g. pkill anvil / pkill alto) or set ${label}_PORT, then re-run.`);
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

async function waitFor(label, fn, { tries = 60, delay = 1000 } = {}) {
  let lastErr;
  for (let i = 0; i < tries; i++) {
    try { return await fn(); } catch (e) { lastErr = e; await sleep(delay); }
  }
  throw new Error(`${label} not ready after ${tries} tries: ${lastErr?.message ?? lastErr}`);
}

// ---------------------------------------------------------------------------
// viem clients
// ---------------------------------------------------------------------------
const deployer = privateKeyToAccount(DEPLOYER_KEY);
const EXECUTOR_ADDR = privateKeyToAccount(EXECUTOR_KEY).address;
const UTILITY_ADDR = privateKeyToAccount(UTILITY_KEY).address;
const pub = createPublicClient({ chain: baseSepolia, transport: http(NODE_URL) });
const wallet = createWalletClient({ account: deployer, chain: baseSepolia, transport: http(NODE_URL) });

async function deploy(artifact, args) {
  const hash = await wallet.deployContract({ abi: artifact.abi, bytecode: artifact.bytecode, args });
  const rcpt = await pub.waitForTransactionReceipt({ hash });
  if (!rcpt.contractAddress) throw new Error("deploy: no contractAddress");
  return rcpt.contractAddress;
}
async function send(req) {
  const hash = await wallet.writeContract(req);
  return pub.waitForTransactionReceipt({ hash });
}

// ---------------------------------------------------------------------------
// UserOperation helpers (raw v0.7)
// ---------------------------------------------------------------------------
let ACCOUNT_ADDR, VAULT_ADDR;

function buildCallData(ref, recipient, amount) {
  const inner = encodeFunctionData({ abi: VAULT.abi, functionName: "executeSettlement", args: [ref, recipient, amount] });
  return encodeFunctionData({ abi: ACCOUNT.abi, functionName: "execute", args: [VAULT_ADDR, 0n, inner] });
}

async function currentFees() {
  // Prefer Alto's gas-price oracle; fall back to the node base fee.
  try {
    const gp = await bundlerRpc("pimlico_getUserOperationGasPrice", []);
    return { maxFeePerGas: BigInt(gp.fast.maxFeePerGas), maxPriorityFeePerGas: BigInt(gp.fast.maxPriorityFeePerGas) };
  } catch {
    const blk = await pub.getBlock();
    const base = blk.baseFeePerGas ?? parseGwei("1");
    const prio = parseGwei("1");
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
  return pub.readContract({ address: entryPoint07Address, abi: entryPoint07Abi, functionName: "getUserOpHash", args: [packed] });
}

const DUMMY_SIG = "0x" + "fa".repeat(64) + "1c"; // 65-byte well-formed stub for estimation

async function estimateLimits(base) {
  const op = hexOp({ ...base, callGasLimit: 0n, verificationGasLimit: 0n, preVerificationGas: 0n, signature: DUMMY_SIG });
  const est = await bundlerRpc("eth_estimateUserOperationGas", [op, entryPoint07Address]);
  // pad by 15% for headroom
  const pad = (h) => (BigInt(h) * 115n) / 100n;
  return {
    callGasLimit: pad(est.callGasLimit),
    verificationGasLimit: pad(est.verificationGasLimit),
    preVerificationGas: pad(est.preVerificationGas),
  };
}

// Build a fully-formed, signed op. `signer` signs the real userOpHash; if
// `rawSignature` is given it overrides (used for the malformed-sig case).
async function makeOp({ ref, recipient, amount, limits, signer, rawSignature }) {
  const { maxFeePerGas, maxPriorityFeePerGas } = await currentFees();
  const nonce = await pub.readContract({ address: entryPoint07Address, abi: entryPoint07Abi, functionName: "getNonce", args: [ACCOUNT_ADDR, 0n] });
  const base = {
    sender: ACCOUNT_ADDR,
    nonce,
    callData: buildCallData(ref, recipient, amount),
    maxFeePerGas, maxPriorityFeePerGas,
    ...limits,
  };
  const h = await userOpHash(base);
  const signature = rawSignature ?? await signer.signMessage({ message: { raw: h } });
  return { op: hexOp({ ...base, signature }), hash: h };
}

async function waitReceipt(uoHash, timeoutMs = 30000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const r = await bundlerRpc("eth_getUserOperationReceipt", [uoHash]);
    if (r) return r;
    await sleep(1500);
  }
  throw new Error("timed out waiting for UserOperation receipt");
}

function receiptSucceeded(r) {
  // Spec: `success` is a boolean; tolerate hex too.
  if (typeof r.success === "boolean") return r.success;
  return r.success === "0x1" || r.success === true;
}

const SETTLEMENT_EXECUTED_TOPIC = keccak256(toBytes("SettlementExecuted(bytes32,address,uint256,address)"));
function hasSettlementEvent(r) {
  const logs = r.logs ?? r.receipt?.logs ?? [];
  return logs.some((l) => (l.address?.toLowerCase() === VAULT_ADDR.toLowerCase()) && l.topics?.[0]?.toLowerCase() === SETTLEMENT_EXECUTED_TOPIC.toLowerCase());
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function main() {
  log(`\n=== SonicSphere Stage 3 — bundler-in-the-loop E2E ===`);
  log(`node RPC: ${NODE_URL}   bundler: ${BUNDLER_URL}   safe-mode: ${SAFE_MODE}\n`);

  // 0) Preflight: our ports must be free so we never test a stale process.
  await assertPortFree(ANVIL_PORT, "ANVIL");
  await assertPortFree(BUNDLER_PORT, "BUNDLER");

  // 1) Anvil fork of Base Sepolia ------------------------------------------------
  log("[1] starting anvil (fork of Base Sepolia)...");
  spawnProc("anvil", "anvil", ["--fork-url", RPC_URL, "--port", String(ANVIL_PORT), "--silent"]);
  const chainId = await waitFor("anvil", () => pub.getChainId());
  const epCode = await pub.getBytecode({ address: entryPoint07Address });
  check("anvil forked Base Sepolia (chainId 84532)", chainId === 84532, `got ${chainId}`);
  check("canonical EntryPoint v0.7 present on fork", !!epCode && epCode !== "0x");

  // The default Anvil dev accounts inherit their *forked* Base Sepolia balances —
  // and the bundler's executor EOA (acct1) typically has ~0 ETH there, so it can't
  // front gas for handleOps. Top up deployer + executor + utility deterministically.
  for (const a of [deployer.address, EXECUTOR_ADDR, UTILITY_ADDR]) {
    await rpc(NODE_URL, "anvil_setBalance", [a, toHex(parseEther("1000"))]);
  }
  const fundedBalances = await Promise.all(
    [deployer.address, EXECUTOR_ADDR, UTILITY_ADDR].map((a) => pub.getBalance({ address: a })),
  );
  check(
    "deployer + bundler executor + utility EOAs funded (>=1000 ETH each)",
    fundedBalances.every((b) => b >= parseEther("1000")),
    fundedBalances.map(formatEther).join(" / "),
  );

  // 2) Deploy + wire -------------------------------------------------------------
  log("[2] deploying LiquidityVault + ProtocolAccount, wiring RELAYER_ROLE...");
  const kms = privateKeyToAccount(generatePrivateKey()); // throwaway KMS stand-in
  VAULT_ADDR = await deploy(VAULT, [deployer.address, deployer.address, PLACEHOLDER_RELAYER, TX_LIMIT, DAILY_CAP]);
  ACCOUNT_ADDR = await deploy(ACCOUNT, [entryPoint07Address, kms.address]);
  const RELAYER_ROLE = await pub.readContract({ address: VAULT_ADDR, abi: VAULT.abi, functionName: "RELAYER_ROLE" });
  await send({ address: VAULT_ADDR, abi: VAULT.abi, functionName: "grantRole", args: [RELAYER_ROLE, ACCOUNT_ADDR] });
  await send({ address: VAULT_ADDR, abi: VAULT.abi, functionName: "revokeRole", args: [RELAYER_ROLE, PLACEHOLDER_RELAYER] });
  const accountHasRole = await pub.readContract({ address: VAULT_ADDR, abi: VAULT.abi, functionName: "hasRole", args: [RELAYER_ROLE, ACCOUNT_ADDR] });
  check("ProtocolAccount holds RELAYER_ROLE", accountHasRole);
  log(`    vault=${VAULT_ADDR}`);
  log(`    account=${ACCOUNT_ADDR}`);

  // 3) Fund the vault (to release) + the account's gas deposit (no paymaster yet) -
  log("[3] funding vault + account gas deposit...");
  await pub.waitForTransactionReceipt({ hash: await wallet.sendTransaction({ to: VAULT_ADDR, value: parseEther("5") }) });
  await send({ address: entryPoint07Address, abi: entryPoint07Abi, functionName: "depositTo", args: [ACCOUNT_ADDR], value: parseEther("1") });
  const dep = await pub.readContract({ address: entryPoint07Address, abi: entryPoint07Abi, functionName: "balanceOf", args: [ACCOUNT_ADDR] });
  check("account funded for gas (EntryPoint deposit > 0)", dep > 0n);

  // 4) Bundler -------------------------------------------------------------------
  log("[4] starting Alto bundler...");
  const altoBin = join(__dirname, "node_modules", ".bin", "alto");
  spawnProc("alto", altoBin, [
    "--entrypoints", entryPoint07Address,
    "--rpc-url", NODE_URL,
    "--executor-private-keys", EXECUTOR_KEY,
    "--utility-private-key", UTILITY_KEY,
    "--port", String(BUNDLER_PORT),
    "--safe-mode", String(SAFE_MODE),
  ]);
  await waitFor("alto", async () => {
    const eps = await bundlerRpc("eth_supportedEntryPoints", []);
    if (!eps?.length) throw new Error("no entrypoints yet");
    return eps;
  }, { tries: 90, delay: 1000 });
  log("    bundler is up.\n");

  // 5) Assertions ----------------------------------------------------------------
  const REF1 = keccak256(toBytes("e2e-settle-1"));
  const AMOUNT = parseEther("0.01");

  // (a) Happy path
  log("[5a] happy path: relayer settles via UserOperation...");
  const balBefore = await pub.getBalance({ address: RECIPIENT });
  const limits = await estimateLimits({ sender: ACCOUNT_ADDR, nonce: 0n, callData: buildCallData(REF1, RECIPIENT, AMOUNT), maxFeePerGas: (await currentFees()).maxFeePerGas, maxPriorityFeePerGas: (await currentFees()).maxPriorityFeePerGas });
  const happy = await makeOp({ ref: REF1, recipient: RECIPIENT, amount: AMOUNT, limits, signer: kms });
  let happyAccepted = true, happyErr = "";
  let happyHash;
  try { happyHash = await bundlerRpc("eth_sendUserOperation", [happy.op, entryPoint07Address]); }
  catch (e) { happyAccepted = false; happyErr = e.message; }
  check("valid op ACCEPTED by bundler (no AA2x at simulation)", happyAccepted, happyErr);
  if (happyAccepted) {
    const r = await waitReceipt(happyHash);
    check("happy path: receipt success == true", receiptSucceeded(r));
    check("happy path: SettlementExecuted event emitted", hasSettlementEvent(r));
    const balAfter = await pub.getBalance({ address: RECIPIENT });
    check("happy path: recipient balance increased by amount", balAfter - balBefore === AMOUNT, `delta=${formatEther(balAfter - balBefore)}`);
    const settled = await pub.readContract({ address: VAULT_ADDR, abi: VAULT.abi, functionName: "isSettled", args: [REF1] });
    check("happy path: vault marks ref settled", settled === true);
  }

  // (b) Idempotency — same settlementRef, fresh nonce
  log("[5b] idempotency: replay same settlementRef...");
  const balBeforeReplay = await pub.getBalance({ address: RECIPIENT });
  const replay = await makeOp({ ref: REF1, recipient: RECIPIENT, amount: AMOUNT, limits, signer: kms });
  let replayHash, replayLanded = true, replayErr = "";
  try { replayHash = await bundlerRpc("eth_sendUserOperation", [replay.op, entryPoint07Address]); }
  catch (e) { replayLanded = false; replayErr = e.message; }
  // The op is well-formed & validly signed, so it should be ACCEPTED and INCLUDED;
  // the *inner* executeSettlement reverts (AlreadySettled), so success == false.
  check("replay op accepted (valid signature/validation)", replayLanded, replayErr);
  if (replayLanded) {
    const r = await waitReceipt(replayHash);
    check("idempotency: receipt success == false (inner revert)", !receiptSucceeded(r));
    const balAfterReplay = await pub.getBalance({ address: RECIPIENT });
    check("idempotency: NO double release (recipient balance unchanged)", balAfterReplay === balBeforeReplay, `delta=${formatEther(balAfterReplay - balBeforeReplay)}`);
  }

  // (c) Wrong/malformed signature — must be REJECTED at simulation (pre-inclusion)
  log("[5c] wrong signature: must be rejected at simulation...");
  const REF2 = keccak256(toBytes("e2e-settle-2"));
  const wrongSigner = privateKeyToAccount(generatePrivateKey());
  const wrong = await makeOp({ ref: REF2, recipient: RECIPIENT, amount: AMOUNT, limits, signer: wrongSigner });
  let wrongRejected = false, wrongRejectErr = "";
  try { await bundlerRpc("eth_sendUserOperation", [wrong.op, entryPoint07Address]); }
  catch (e) { wrongRejected = true; wrongRejectErr = (e.data?.message || e.message || "").slice(0, 160); }
  check("wrong-signature op REJECTED pre-inclusion", wrongRejected, wrongRejected ? wrongRejectErr : "bundler ACCEPTED a bad signature!");
  check("wrong-signature rejection is a SIGNATURE failure (AA24), not some other error", wrongRejected && isSigFailure(wrongRejectErr), wrongRejectErr || "(no error captured)");
  // And it must not have settled REF2.
  const ref2Settled = await pub.readContract({ address: VAULT_ADDR, abi: VAULT.abi, functionName: "isSettled", args: [REF2] });
  check("wrong-signature op did NOT settle (no post-inclusion effect)", ref2Settled === false);

  // (d) Malformed (garbage) signature — also rejected, proving tryRecover stays clean
  log("[5d] malformed signature: must be rejected at simulation...");
  const malformed = await makeOp({ ref: keccak256(toBytes("e2e-settle-3")), recipient: RECIPIENT, amount: AMOUNT, limits, signer: kms, rawSignature: "0xdeadbeef" });
  let malformedRejected = false, malformedErr = "";
  try { await bundlerRpc("eth_sendUserOperation", [malformed.op, entryPoint07Address]); }
  catch (e) { malformedRejected = true; malformedErr = (e.data?.message || e.message || "").slice(0, 160); }
  check("malformed-signature op REJECTED at simulation", malformedRejected, malformedRejected ? malformedErr : "bundler ACCEPTED a malformed signature!");
  check("malformed-signature is an AA24 sig failure, NOT an AA23 validation revert (tryRecover stays clean)", malformedRejected && isSigFailure(malformedErr) && !isAA23Revert(malformedErr), malformedErr || "(no error captured)");

  // (e) ERC-7562 cleanliness summary
  check("ERC-7562: valid op had no AA23/AA24 simulation errors", happyAccepted);
  log(`\n    (ERC-7562 deep opcode/storage rules: ${SAFE_MODE ? "ENFORCED (safe-mode on)" : "not trace-enforced on anvil; account validation reads only immutables + ECDSA, structurally clean. Full enforcement is exercised by the real testnet bundler in Stage 4."})`);
}

// ---------------------------------------------------------------------------
main()
  .then(() => {
    log(`\n=== RESULTS ===`);
    results.forEach((r) => log(r));
    log(`\n${passed} passed, ${failed} failed`);
    teardown();
    process.exit(failed === 0 ? 0 : 1);
  })
  .catch((e) => {
    log(`\nFATAL: ${e?.stack || e}`);
    results.forEach((r) => log(r));
    teardown();
    process.exit(1);
  });
