# RareRandom v1 (hackathon MVP)

A replacement randomness provider for Rare Friends after Dice Protocol went dark on Robinhood Chain.

Every request is bound to a **future drand quicknet round** at the moment it is made, and that round's BLS
signature is **verified on chain**. Whoever runs the relayer can delay a result but can't choose it or see it
early. There is no operator secret, so nothing breaks if an operator disappears. The Dice failure was exactly
that.

This repo is the on-chain core plus the relayer, built from `architecture-scope.md` (sections 3, 4 and 7) using
the scope's recommended defaults for the open owner decisions.

```
contracts/   Foundry project
  src/QuicknetBLS.sol          drand quicknet verifier (EIP-2537 precompiles, RFC 9380 hash-to-G1)
  src/RareRandomV1.sol         core: binding, verification, round cache, fees, escrow, credits, window, cancel, breaker
  src/interfaces/IRareRandom.sol
  src/consumer/                RareRandomConsumer base + CoinFlip example
  test/                        unit, fuzz, invariant and live-drand differential tests
  script/Deploy.s.sol
relayer/     TypeScript + viem
  src/drand.ts                 fetch from 4 relays, verify with @noble/curves, encode for the contract
  src/relayer.ts               discover requests (counter walk, no log scans), fetch at the round boundary, fulfill
  src/main.ts                  entry point (env config)
  scripts/e2e.ts               end to end: anvil (Prague) + live drand + relayer, every result checked independently
  scripts/gen-fixtures.ts      regenerates contracts/test/fixtures/quicknet-rounds.json from live drand
```

## Test status

All of these pass with zero errors and zero compiler or lint warnings:

| Check | Result |
|---|---|
| `forge build` (solc 0.8.38, Prague, optimizer 200) | clean, no warnings |
| `forge test`, 57 tests | 57 passed |
| BLS verifier against 71 real quicknet rounds (round 1, the spec's known answers, 30 consecutive recent rounds, 30 sampled across all history; each cross-checked between two relays and verified by noble) | all match drand's randomness |
| BLS negatives: wrong round, other round's signature, negated point, `y + p`, oversize hi word, `x = p`, infinity, non-subgroup point, round 0, 1,024 random corruptions | all rejected |
| Spec vectors: word derivation (§3.6), fee table (Appendix C), price-step boundary, worked binding example (§3.5) | exact match |
| Invariants I1 to I4 plus word determinism, 256 runs × 500 calls | hold |
| On an EVM without EIP-2537 (`FOUNDRY_PROFILE=nobls`) | self-test fails closed, so deployment reverts |
| `tsc --noEmit` (relayer) | 0 errors |
| End to end, run 3 times: deploy, 3 pull requests (1, 3, 32 words) + 2 CoinFlip callbacks, relayer delivers from live drand | all on time, fee earned, words match an independent derivation, 2 to 4 s latency |

## Run it

```bash
# contracts
cd contracts && npm ci && forge test
EXPECT_NO_BLS=true FOUNDRY_PROFILE=nobls forge test --match-test test_selfTest   # no-precompile chain

# relayer
cd relayer && npm ci && npm run typecheck
(cd ../contracts && forge build) && npx tsx scripts/e2e.ts                          # needs anvil and internet

# run the relayer against a deployment
RR_RPC_HTTP=... RR_CORE=0x... RR_RELAYER_KEY=0x... npm start
```

Deploy (simulation first; the owner sends the real one):

```bash
cd contracts
OWNER=0x... FEE_RECIPIENT=0x... RELAYER_0=0x... GAS_PRICE_SOURCE=1 \
  forge script script/Deploy.s.sol --rpc-url $RPC
```

On Robinhood Chain (4663) use `GAS_PRICE_SOURCE=1` (reads the real base fee from ArbGasInfo). Use 0 on
non-Nitro chains.

## Decisions baked in (scope §15.1 recommended defaults)

| Q | Choice |
|---|---|
| Q1 minimum lead | `MIN_LEAD = 1` (constructor argument, so it can change before deploy if the clock test says so) |
| Q2 sunset | included: one-way `sunset()` stops new requests only |
| Q3 pricing | margin 5e12 wei, cap 1e14; late delivery by RF's own relayer is **refunded** |
| Q5 identifiers | `RareRandom.v1.word` as the permanent word domain |
| Q8 posting window | only relayer slots post a round in its first 600 s; anyone after, or once a supplied request's own 60 s window has passed |

## What "lean MVP" cut, compared with the full scope

Nothing that protects fairness or funds was cut. Everything in scope §3 (the core) is implemented. These were
left for later:

- **Entropy V2 adapter** (§5), so stranded Dice integrators can switch by changing an address. Next on the list.
- **Relayer extras** (§7): WSS wake-ups, Multicall3 batching, a second hot key with in-process failover, the
  heartbeat and metrics, the persisted state file, 429 handling and relay quarantine. The relayer does have the
  core loop: counter-walk discovery, four-relay race, 50 ms burst then 2 s backoff, noble verification, one
  `fulfill` per round, spec gas formula, serialized nonces, and retry on failure.
- Watchdog, status page, HTTP/x402 API, SDK/CLI, CreateX deterministic deploys, Sourcify scripts, mainnet fork
  tests, and the canary run.

## Known differences from the spec

- **Verification gas is about 131k** for an external call, against the spec's ~123k. The library uses
  `abi.encodePacked` for readability rather than hand-placed memory. It's paid once per posted round, and
  `G_BASE = 200,000` still covers a full post-plus-deliver transaction (~196k measured in `test_gas_report`).
  Hand-optimising the memory layout is a straightforward follow-up if the team wants the spec figure.
- **Runtime size is 16.6 KB** (spec prototypes were 11.6 to 12.7 KB). That's still well under the 24 KB limit.
- `InvalidSignature` and `BadSignatureEncoding` are declared in `QuicknetBLS`, not in `IRareRandom`. The
  selectors are identical.

## Before mainnet

This is new, unaudited cryptographic code going into contracts that can't be changed after deployment. The
scope's own plan still applies before real money goes through it: the Robinhood fork tests (§12.6), the
clock-offset test that fixes `MIN_LEAD` (T1), the mainnet canary (§13.4), and the owner's audit contest.

## Licence

Apache-2.0 for the repo; Solidity files are MIT (SPDX headers).
