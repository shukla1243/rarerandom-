// Minimal RareRandomV1 ABI used by the relayer and the end-to-end test.
export const coreAbi = [
  { type: "function", name: "requestCount", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  {
    type: "function",
    name: "getRequest",
    stateMutability: "view",
    inputs: [{ name: "requestId", type: "uint256" }],
    outputs: [
      {
        type: "tuple",
        components: [
          { name: "requester", type: "address" },
          { name: "targetRound", type: "uint64" },
          { name: "callbackGasLimit", type: "uint32" },
          { name: "numWords", type: "uint8" },
          { name: "status", type: "uint8" },
          { name: "callbackStatus", type: "uint8" },
          { name: "feeOutcome", type: "uint8" },
          { name: "fee", type: "uint96" },
          { name: "createdAt", type: "uint40" },
          { name: "resolvedAt", type: "uint40" },
          { name: "exclusiveUntil", type: "uint40" },
          { name: "cancellableAt", type: "uint40" },
          { name: "userSeed", type: "bytes32" },
        ],
      },
    ],
  },
  {
    type: "function",
    name: "fulfill",
    stateMutability: "nonpayable",
    inputs: [
      { name: "round", type: "uint64" },
      { name: "signature", type: "uint256[4]" },
      { name: "requestIds", type: "uint256[]" },
    ],
    outputs: [{ name: "settled", type: "uint256" }],
  },
  {
    type: "function",
    name: "roundRandomness",
    stateMutability: "view",
    inputs: [{ name: "round", type: "uint64" }],
    outputs: [{ type: "bytes32" }],
  },
  {
    type: "function",
    name: "isRelayer",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ type: "bool" }],
  },
  {
    type: "function",
    name: "request",
    stateMutability: "payable",
    inputs: [
      { name: "numWords", type: "uint32" },
      { name: "callbackGasLimit", type: "uint32" },
      { name: "userSeed", type: "bytes32" },
    ],
    outputs: [{ name: "requestId", type: "uint256" }],
  },
  {
    type: "function",
    name: "getFee",
    stateMutability: "view",
    inputs: [
      { name: "numWords", type: "uint32" },
      { name: "callbackGasLimit", type: "uint32" },
    ],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "randomWords",
    stateMutability: "view",
    inputs: [{ name: "requestId", type: "uint256" }],
    outputs: [
      { name: "ready", type: "bool" },
      { name: "words", type: "uint256[]" },
    ],
  },
  {
    type: "function",
    name: "totals",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "escrowed", type: "uint256" },
      { name: "credited", type: "uint256" },
      { name: "accruedFees", type: "uint256" },
    ],
  },
  {
    type: "event",
    name: "RandomnessFulfilled",
    inputs: [
      { name: "requestId", type: "uint256", indexed: true },
      { name: "requester", type: "address", indexed: true },
      { name: "round", type: "uint64", indexed: true },
      { name: "deliverer", type: "address", indexed: false },
      { name: "feeEarned", type: "bool", indexed: false },
      { name: "callbackStatus", type: "uint8", indexed: false },
    ],
  },
] as const;

export const STATUS_PENDING = 1;
