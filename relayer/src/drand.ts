// drand quicknet: fetch beacons from public relays, verify them with noble, and convert them to the
// EIP-2537 uint256[4] form the RareRandomV1 contract takes.
import { bls12_381 } from "@noble/curves/bls12-381.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { bytesToHex, hexToBytes } from "@noble/hashes/utils.js";

export const CHAIN_HASH = "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971";
export const GENESIS_TIME = 1692803367;
export const PERIOD = 3;
export const PUBLIC_KEY =
  "83cf0f2896adee7eb8b5f01fcad3912212c437e0073e911fb90022d3e760183c8c4b450b6a0a6c3ac6a5776a2d1064510d1fec758c921cc22b0e17e63aaf4bcb5ed66304de9cf809bd274ca73bab4af5a6e9c76a4bc09e76eae8991ef5ece45a";
export const DST = "BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_NUL_";
export const DEFAULT_RELAYS = [
  "https://drand.cloudflare.com",
  "https://api.drand.sh",
  "https://api2.drand.sh",
  "https://api3.drand.sh",
];

export type Beacon = {
  round: number;
  signature: string; // 48-byte compressed, hex
  randomness: `0x${string}`;
  words: [bigint, bigint, bigint, bigint]; // [x_hi, x_lo, y_hi, y_lo]
};

export const roundTime = (round: number) => GENESIS_TIME + (round - 1) * PERIOD;
export const roundAt = (t: number) => (t < GENESIS_TIME ? 0 : Math.floor((t - GENESIS_TIME) / PERIOD) + 1);

const sigs = bls12_381.shortSignatures;
const pk = bls12_381.G2.Point.fromHex(PUBLIC_KEY);

function roundMessage(round: number): Uint8Array {
  const b = new Uint8Array(8);
  new DataView(b.buffer).setBigUint64(0, BigInt(round));
  return sha256(b);
}

/** Verifies a compressed quicknet signature and returns the beacon in contract form. Throws if invalid. */
export function verifyBeacon(round: number, sigHex: string): Beacon {
  const sigBytes = hexToBytes(sigHex.replace(/^0x/, ""));
  if (sigBytes.length !== 48) throw new Error(`round ${round}: signature is not 48 bytes`);
  const point = bls12_381.G1.Point.fromBytes(sigBytes); // rejects off-curve and non-subgroup points
  const ok = sigs.verify(point, sigs.hash(roundMessage(round), DST), pk);
  if (!ok) throw new Error(`round ${round}: invalid signature`);
  return { round, signature: bytesToHex(sigBytes), randomness: `0x${bytesToHex(sha256(sigBytes))}`, words: toEip2537(point) };
}

/** Splits an affine G1 point into [x_hi, x_lo, y_hi, y_lo]; hi holds the top 16 bytes of each 48-byte coordinate. */
export function toEip2537(point: ReturnType<typeof bls12_381.G1.Point.fromHex>): [bigint, bigint, bigint, bigint] {
  const { x, y } = point.toAffine();
  const mask = (1n << 256n) - 1n;
  return [x >> 256n, x & mask, y >> 256n, y & mask];
}

/** One GET of /{chainHash}/public/{round} (v1 path, which every relay serves). Returns null on any non-200. */
export async function fetchRoundOnce(relay: string, round: number, timeoutMs = 2500): Promise<string | null> {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetch(`${relay}/${CHAIN_HASH}/public/${round}?nc=${Math.random().toString(36).slice(2)}`, {
      signal: ctrl.signal,
    });
    if (res.status !== 200) return null;
    const body = (await res.json()) as { round: number; signature: string };
    if (body.round !== round) return null;
    return body.signature;
  } catch {
    return null;
  } finally {
    clearTimeout(t);
  }
}

/** Latest round number by the clock (not by asking a relay, whose `latest` is served stale). */
export const currentRound = () => roundAt(Math.floor(Date.now() / 1000));
