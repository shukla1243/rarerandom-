// Entry point. Configuration comes from the environment:
//   RR_RPC_HTTP       JSON-RPC URL (required)
//   RR_CORE           RareRandomV1 address (required)
//   RR_RELAYER_KEY    relayer private key, 0x-prefixed (required; must be one of the core's relayer slots)
//   RR_POLL_MS        discovery poll interval, default 250
import { createPublicClient, createWalletClient, defineChain, http, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { Relayer } from "./relayer.js";

function need(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`missing env ${name}`);
  return v;
}

const rpc = need("RR_RPC_HTTP");
const transport = http(rpc);
const probe = createPublicClient({ transport });
const chainId = await probe.getChainId();
const chain = defineChain({
  id: chainId,
  name: `chain-${chainId}`,
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [rpc] } },
});

const relayer = new Relayer({
  core: need("RR_CORE") as Address,
  publicClient: createPublicClient({ chain, transport }),
  walletClient: createWalletClient({ chain, transport, account: privateKeyToAccount(need("RR_RELAYER_KEY") as Hex) }),
  pollMs: Number(process.env.RR_POLL_MS ?? 250),
});

await relayer.start();
for (const sig of ["SIGINT", "SIGTERM"] as const) {
  process.on(sig, () => {
    relayer.stop();
    setTimeout(() => process.exit(0), 500);
  });
}
