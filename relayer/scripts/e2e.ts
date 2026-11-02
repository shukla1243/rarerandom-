// End-to-end test: local Prague chain (anvil) + real drand quicknet rounds + the relayer.
// Deploys RareRandomV1 and the CoinFlip example, sends pull and callback requests, lets the relayer deliver them,
// then checks every result against an independent derivation from drand's public data.
// Usage: npx tsx scripts/e2e.ts   (needs anvil on PATH and `forge build` in ../contracts)
import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeAbiParameters,
  http,
  keccak256,
  parseEther,
  toHex,
  zeroAddress,
  type Abi,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { coreAbi } from "../src/abi.js";
import { fetchRoundOnce, verifyBeacon } from "../src/drand.js";
import { Relayer } from "../src/relayer.js";

const PORT = 8547;
const RPC = `http://127.0.0.1:${PORT}`;
// Throwaway local keys; each account is funded with anvil_setBalance below.
const KEYS = [
  keccak256(toHex("rarerandom-e2e-deployer")),
  keccak256(toHex("rarerandom-e2e-relayer")),
  keccak256(toHex("rarerandom-e2e-user")),
] as const;
const [deployer, relayerAcct, user] = KEYS.map((k) => privateKeyToAccount(k));

let failures = 0;
function check(cond: boolean, msg: string) {
  console.log(`${cond ? "  ok  " : "  FAIL"} ${msg}`);
  if (!cond) failures++;
}
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const artifact = (name: string) =>
  JSON.parse(readFileSync(new URL(`../../contracts/out/${name}.sol/${name}.json`, import.meta.url), "utf8")) as {
    abi: Abi;
    bytecode: { object: Hex };
  };

const anvil = spawn("anvil", ["--hardfork", "prague", "--port", String(PORT), "--silent"], { stdio: "inherit" });
let relayer: Relayer | undefined;

try {
  const chain = defineChain({
    id: 31337,
    name: "anvil",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [RPC] } },
  });
  const pub = createPublicClient({ chain, transport: http(RPC) });
  for (let i = 0; ; i++) {
    try {
      await pub.getChainId();
      break;
    } catch {
      if (i > 50) throw new Error("anvil did not start");
      await sleep(100);
    }
  }
  for (const a of [deployer, relayerAcct, user]) {
    await pub.request({ method: "anvil_setBalance" as never, params: [a.address, toHex(parseEther("100"))] as never });
  }
  const wallet = (acct: typeof deployer) => createWalletClient({ chain, transport: http(RPC), account: acct });

  // --- deploy
  const core = artifact("RareRandomV1");
  const deployHash = await wallet(deployer).deployContract({
    abi: core.abi,
    bytecode: core.bytecode.object,
    args: [deployer.address, deployer.address, 5_000_000_000_000n, 60, 86_400, [relayerAcct.address, zeroAddress, zeroAddress], 1n, 0, 20_000_000n],
  });
  const coreAddr = (await pub.waitForTransactionReceipt({ hash: deployHash })).contractAddress!;
  const flipArt = artifact("CoinFlip");
  const flipHash = await wallet(deployer).deployContract({ abi: flipArt.abi, bytecode: flipArt.bytecode.object, args: [coreAddr] });
  const flipAddr = (await pub.waitForTransactionReceipt({ hash: flipHash })).contractAddress!;
  console.log(`core ${coreAddr}, coinflip ${flipAddr}`);
  check(true, "RareRandomV1 deployed (constructor BLS self-test passed on Prague)");

  // --- relayer
  relayer = new Relayer({ core: coreAddr, publicClient: pub, walletClient: wallet(relayerAcct), log: () => {} });
  await relayer.start();

  // --- requests
  const u = wallet(user);
  type Sent = { id: bigint; seed: Hex; n: number; flip: boolean; blockTime: bigint };
  const sent: Sent[] = [];
  const pullCases = [1, 3, 32];
  for (const [i, n] of pullCases.entries()) {
    const seed = keccak256(toHex(`e2e-${i}`));
    const fee = await pub.readContract({ address: coreAddr, abi: coreAbi, functionName: "getFee", args: [n, 0] });
    const { result: id, request } = await pub.simulateContract({
      account: user, address: coreAddr, abi: coreAbi, functionName: "request", args: [n, 0, seed], value: fee,
    });
    const r = await pub.waitForTransactionReceipt({ hash: await u.writeContract(request) });
    sent.push({ id, seed, n, flip: false, blockTime: (await pub.getBlock({ blockNumber: r.blockNumber })).timestamp });
    await sleep(1200); // spread across rounds
  }
  for (const guess of [true, false]) {
    const { result: id, request } = await pub.simulateContract({
      account: user, address: flipAddr, abi: flipArt.abi, functionName: "flip", args: [guess], value: parseEther("0.01"),
    });
    const r = await pub.waitForTransactionReceipt({ hash: await u.writeContract(request) });
    sent.push({ id: id as bigint, seed: "0x", n: 1, flip: true, blockTime: (await pub.getBlock({ blockNumber: r.blockNumber })).timestamp });
  }
  console.log(`sent ${sent.length} requests: ids ${sent.map((s) => s.id).join(", ")}`);

  // --- wait for delivery
  const deadline = Date.now() + 45_000;
  const settledAt = new Map<bigint, number>();
  while (Date.now() < deadline && settledAt.size < sent.length) {
    for (const s of sent) {
      if (settledAt.has(s.id)) continue;
      const v = await pub.readContract({ address: coreAddr, abi: coreAbi, functionName: "getRequest", args: [s.id] });
      if (v.status === 2) settledAt.set(s.id, Number(v.resolvedAt));
    }
    await sleep(200);
  }
  check(settledAt.size === sent.length, `relayer delivered all ${sent.length} requests`);

  // --- verify every result independently from drand
  for (const s of sent) {
    const v = await pub.readContract({ address: coreAddr, abi: coreAbi, functionName: "getRequest", args: [s.id] });
    const label = `request ${s.id} (${s.flip ? "coinflip callback" : `${s.n}-word pull`})`;
    check(v.status === 2 && v.feeOutcome === 1, `${label}: Fulfilled, fee earned on time`);
    if (s.flip) check(v.callbackStatus === 2, `${label}: callback succeeded`);
    const lead = Number(v.exclusiveUntil) - 60 - Number(s.blockTime);
    check(lead >= 2 && lead <= 4, `${label}: bound round is ${lead}s after the request block (2-4s expected)`);

    const sig = await fetchRoundOnce("https://drand.cloudflare.com", Number(v.targetRound), 8000);
    const beacon = verifyBeacon(Number(v.targetRound), sig!);
    const onchain = await pub.readContract({ address: coreAddr, abi: coreAbi, functionName: "roundRandomness", args: [v.targetRound] });
    check(onchain === beacon.randomness, `${label}: on-chain randomness equals drand's for round ${v.targetRound}`);

    const [ready, words] = await pub.readContract({ address: coreAddr, abi: coreAbi, functionName: "randomWords", args: [s.id] });
    const requester = s.flip ? flipAddr : user.address;
    const seed = v.userSeed;
    const expected = Array.from({ length: s.n }, (_, i) =>
      BigInt(
        keccak256(
          encodeAbiParameters(
            [{ type: "bytes32" }, { type: "uint256" }, { type: "address" }, { type: "uint256" }, { type: "bytes32" }, { type: "bytes32" }, { type: "uint256" }],
            [keccak256(toHex("RareRandom.v1.word")), 31337n, coreAddr, s.id, seed, beacon.randomness, BigInt(i)],
          ),
        ),
      ),
    );
    check(ready && words.length === s.n && words.every((w, i) => w === expected[i]), `${label}: all ${s.n} words match independent derivation`);
    check(v.requester.toLowerCase() === requester.toLowerCase(), `${label}: requester recorded correctly`);
    if (s.flip) {
      const f = (await pub.readContract({ address: flipAddr, abi: flipArt.abi, functionName: "flips", args: [s.id] })) as readonly [string, boolean, boolean, boolean];
      check(f[2] && f[3] === (((words[0] & 1n) === 1n) === f[1]), `${label}: game settled from the delivered word`);
    }
    const settle = settledAt.get(s.id);
    if (settle) console.log(`        latency: request block ${s.blockTime} -> fulfil block ${settle} (${settle - Number(s.blockTime)}s)`);
  }

  const [escrowed, credited, accrued] = await pub.readContract({ address: coreAddr, abi: coreAbi, functionName: "totals" });
  const bal = await pub.getBalance({ address: coreAddr });
  check(escrowed === 0n, "no fees left in escrow");
  check(bal === escrowed + credited + accrued, `contract balance equals escrow + credits + accrued fees (${bal} wei)`);
  check(relayer.stats.txFailures === 0 && relayer.stats.verifyFailures === 0, `relayer: ${relayer.stats.txs} txs, 0 failures`);
} catch (e) {
  console.error(e);
  failures++;
} finally {
  relayer?.stop();
  anvil.kill();
}
console.log(failures === 0 ? "\nE2E PASSED" : `\nE2E FAILED (${failures})`);
process.exit(failures === 0 ? 0 : 1);
