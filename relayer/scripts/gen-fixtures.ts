// Fetches quicknet rounds from two relays, checks they agree, verifies each with noble, and writes the contract
// test fixture. Usage: npx tsx scripts/gen-fixtures.ts [count]
import { writeFileSync } from "node:fs";
import { currentRound, fetchRoundOnce, verifyBeacon } from "../src/drand.js";

const count = Number(process.argv[2] ?? 60);
const now = currentRound() - 2;
const rounds = new Set<number>([1, 2, 33571300, 33571301, 33571302, 33571303, 33571304, 33571305, 33571306, 33571307, 33571308]);
for (let i = 0; i < count / 2; i++) rounds.add(now - i); // consecutive recent rounds
let seed = 12345;
while (rounds.size < 11 + count) {
  seed = (seed * 1103515245 + 12345) % 2 ** 31;
  rounds.add(1 + (seed % now)); // sampled across all history
}

const out: unknown[] = [];
for (const r of [...rounds].sort((a, b) => a - b)) {
  const [a, b] = await Promise.all([
    fetchRoundOnce("https://api.drand.sh", r, 8000),
    fetchRoundOnce("https://drand.cloudflare.com", r, 8000),
  ]);
  if (!a || (b && a !== b)) throw new Error(`round ${r}: relays disagree or missing`);
  const beacon = verifyBeacon(r, a);
  out.push({ round: r, randomness: beacon.randomness, sig: beacon.words.map((w) => "0x" + w.toString(16).padStart(64, "0")) });
}
writeFileSync(
  new URL("../../contracts/test/fixtures/quicknet-rounds.json", import.meta.url),
  JSON.stringify({ fetchedAt: new Date().toISOString(), source: "api.drand.sh + drand.cloudflare.com, verified by @noble/curves 2.4.0", rounds: out }, null, 1),
);
console.log(`wrote ${out.length} rounds`);
