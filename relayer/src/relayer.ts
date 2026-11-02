// RareRandom relayer (lean v1): discovers requests by walking requestCount() (no log scans), fetches each bound drand
// round at its boundary from four relays, verifies it with noble, and sends one fulfill(round, sig, ids) per round.
import {
  type Account,
  type Address,
  type Chain,
  type PublicClient,
  type Transport,
  type WalletClient,
  parseGwei,
} from "viem";
import { coreAbi, STATUS_PENDING } from "./abi.js";
import { type Beacon, DEFAULT_RELAYS, fetchRoundOnce, roundTime, verifyBeacon } from "./drand.js";

export type RelayerOptions = {
  core: Address;
  publicClient: PublicClient<Transport, Chain>;
  walletClient: WalletClient<Transport, Chain, Account>;
  relays?: string[];
  pollMs?: number;
  prefetchMs?: number;
  log?: (msg: string, data?: Record<string, unknown>) => void;
};

type Pending = { id: bigint; round: number; callbackGasLimit: number; numWords: number; exclusiveUntil: number };

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export class Relayer {
  private readonly o: Required<Omit<RelayerOptions, "log">> & { log: NonNullable<RelayerOptions["log"]> };
  private cursor = 1n; // lowest id that may still be unresolved
  private resolved = new Set<bigint>(); // ids seen resolved above the cursor
  private pending = new Map<number, Map<bigint, Pending>>(); // round -> id -> request
  private scheduled = new Set<number>();
  private beacons = new Map<number, Beacon>();
  private sendQueue: Promise<unknown> = Promise.resolve();
  private stopped = false;
  readonly stats = { delivered: 0, txs: 0, txFailures: 0, verifyFailures: 0 };

  constructor(opts: RelayerOptions) {
    this.o = {
      relays: DEFAULT_RELAYS,
      pollMs: 250,
      prefetchMs: 200,
      log: (msg, data) => console.log(JSON.stringify({ t: new Date().toISOString(), msg, ...data })),
      ...opts,
    };
  }

  async start() {
    const ok = await this.o.publicClient.readContract({
      address: this.o.core,
      abi: coreAbi,
      functionName: "isRelayer",
      args: [this.o.walletClient.account.address],
    });
    if (!ok) throw new Error(`${this.o.walletClient.account.address} is not a relayer slot on ${this.o.core}`);
    this.o.log("relayer started", { core: this.o.core, signer: this.o.walletClient.account.address });
    void this.loop();
  }

  stop() {
    this.stopped = true;
  }

  pendingCount() {
    let n = 0;
    for (const m of this.pending.values()) n += m.size;
    return n;
  }

  private async loop() {
    while (!this.stopped) {
      try {
        await this.discover();
      } catch (e) {
        this.o.log("discover error", { error: String(e) });
      }
      await sleep(this.o.pollMs);
    }
  }

  /** Walks new ids from the cursor and adds Pending ones to the per-round set. */
  private async discover() {
    const count = await this.o.publicClient.readContract({
      address: this.o.core,
      abi: coreAbi,
      functionName: "requestCount",
    });
    for (let id = this.cursor; id <= count; id++) {
      if (this.resolved.has(id) || this.isTracked(id)) continue;
      const r = await this.o.publicClient.readContract({
        address: this.o.core,
        abi: coreAbi,
        functionName: "getRequest",
        args: [id],
      });
      if (r.status !== STATUS_PENDING) {
        this.resolved.add(id);
        continue;
      }
      const round = Number(r.targetRound);
      if (!this.pending.has(round)) this.pending.set(round, new Map());
      this.pending.get(round)!.set(id, {
        id,
        round,
        callbackGasLimit: Number(r.callbackGasLimit),
        numWords: Number(r.numWords),
        exclusiveUntil: Number(r.exclusiveUntil),
      });
      this.o.log("request found", { id: id.toString(), round });
      this.schedule(round);
    }
    while (this.resolved.has(this.cursor)) this.resolved.delete(this.cursor++);
  }

  private isTracked(id: bigint) {
    for (const m of this.pending.values()) if (m.has(id)) return true;
    return false;
  }

  /** Fires the fetch at roundTime(R) - prefetchMs (immediately if that time has passed). */
  private schedule(round: number) {
    if (this.scheduled.has(round)) {
      // Round already handled or in flight: a late-found id gets a delivery-only follow-up.
      if (this.beacons.has(round)) void this.deliver(round);
      return;
    }
    this.scheduled.add(round);
    const wait = Math.max(0, roundTime(round) * 1000 - this.o.prefetchMs - Date.now());
    setTimeout(() => void this.handleRound(round), wait);
  }

  private async handleRound(round: number) {
    const beacon = await this.fetchBeacon(round);
    if (!beacon) return;
    this.beacons.set(round, beacon);
    await this.deliver(round);
  }

  /** Races all relays. Retries every 50 ms until roundTime + 3 s, then backs off to one try per 2 s per relay. */
  private async fetchBeacon(round: number): Promise<Beacon | null> {
    const burstUntil = (roundTime(round) + 3) * 1000;
    const started = Date.now();
    const tryRelay = async (relay: string): Promise<Beacon> => {
      while (!this.stopped) {
        const sig = await fetchRoundOnce(relay, round);
        if (sig) {
          try {
            return verifyBeacon(round, sig);
          } catch (e) {
            this.stats.verifyFailures++;
            this.o.log("relay served invalid signature", { relay, round, error: String(e) });
            throw e; // drop this relay for the round
          }
        }
        await sleep(Date.now() < burstUntil ? 50 : 2000);
      }
      throw new Error("stopped");
    };
    try {
      const b = await Promise.any(this.o.relays.map(tryRelay));
      this.o.log("round fetched", { round, lagMs: Date.now() - roundTime(round) * 1000, tookMs: Date.now() - started });
      return b;
    } catch {
      this.o.log("round fetch failed on all relays", { round });
      this.scheduled.delete(round);
      return null;
    }
  }

  /** Sends fulfill for every pending id of the round. Serialized per signer so nonces stay ordered. */
  private deliver(round: number) {
    const run = async () => {
      const set = this.pending.get(round);
      const beacon = this.beacons.get(round);
      if (!set || set.size === 0 || !beacon) return;
      const batch = [...set.values()];
      const ids = batch.map((p) => p.id);
      const cached =
        (await this.o.publicClient.readContract({
          address: this.o.core,
          abi: coreAbi,
          functionName: "roundRandomness",
          args: [BigInt(round)],
        })) !== `0x${"0".repeat(64)}`;
      const gas = gasLimit(batch, cached);
      const block = await this.o.publicClient.getBlock();
      const base = block.baseFeePerGas ?? 0n;
      const floor = parseGwei("0.1");
      const maxFeePerGas = 5n * base > floor ? 5n * base : floor;
      try {
        const hash = await this.o.walletClient.writeContract({
          address: this.o.core,
          abi: coreAbi,
          functionName: "fulfill",
          args: [BigInt(round), beacon.words, ids],
          gas,
          maxFeePerGas,
          maxPriorityFeePerGas: 0n,
        });
        this.stats.txs++;
        const receipt = await this.o.publicClient.waitForTransactionReceipt({ hash });
        if (receipt.status !== "success") throw new Error(`fulfill reverted: ${hash}`);
        for (const id of ids) {
          set.delete(id);
          this.resolved.add(id);
        }
        if (set.size === 0) this.pending.delete(round);
        this.stats.delivered += ids.length;
        this.o.log("fulfilled", { round, ids: ids.map(String), tx: hash, gasUsed: receipt.gasUsed.toString() });
      } catch (e) {
        this.stats.txFailures++;
        this.o.log("fulfill failed, will retry", { round, error: String(e).slice(0, 300) });
        setTimeout(() => void this.deliver(round), 1000);
      }
    };
    const p = this.sendQueue.then(run, run);
    this.sendQueue = p.catch(() => {});
    return p;
  }
}

/** Worst-case gas from the spec (§7.5): every callback burns its full limit, every late id writes a new credit slot. */
export function gasLimit(batch: Pending[], roundCached: boolean, nowSec = Math.floor(Date.now() / 1000)): bigint {
  let g = 60_000 + (roundCached ? 0 : 150_000);
  for (const p of batch) {
    g += nowSec <= p.exclusiveUntil ? 30_000 : 60_000;
    if (p.callbackGasLimit > 0) g += Math.ceil((p.callbackGasLimit * 32) / 31) + 10_000 + 600 * p.numWords;
  }
  return BigInt(g);
}
