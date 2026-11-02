// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRareRandomConsumer {
    /// @notice Called by the core with exactly the requested gas. Implementations must check msg.sender.
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external; // 0x1fe543e3
}

interface IRareRandom {
    // Status 0 None, 1 Pending, 2 Fulfilled, 3 Cancelled
    // CallbackStatus 0 None, 1 Pending, 2 Succeeded, 3 Failed
    // FeeOutcome 0 Escrowed, 1 Earned, 2 Refunded;   Credited.reason 0 Overpayment, 1 LateDelivery, 2 Cancel
    struct RequestView {
        address requester;
        uint64 targetRound;
        uint32 callbackGasLimit; // 0 = pull only
        uint8 numWords;
        uint8 status;
        uint8 callbackStatus;
        uint8 feeOutcome;
        uint96 fee; // escrowed quote
        uint40 createdAt;
        uint40 resolvedAt; // 0 while Pending
        uint40 exclusiveUntil; // roundTime(targetRound) + window snapshot (inclusive)
        uint40 cancellableAt; // createdAt + cancel-timeout snapshot
        bytes32 userSeed;
    }

    event RandomnessRequested(
        uint256 indexed requestId,
        address indexed requester,
        uint64 indexed targetRound,
        uint32 numWords,
        uint32 callbackGasLimit,
        uint256 fee,
        bytes32 userSeed
    );
    event RoundPosted(uint64 indexed round, bytes32 randomness, address indexed poster);
    event RandomnessFulfilled(
        uint256 indexed requestId,
        address indexed requester,
        uint64 indexed round,
        address deliverer,
        bool feeEarned,
        uint8 callbackStatus
    );
    event CallbackRetried(uint256 indexed requestId, address indexed requester, address caller);
    event RequestCancelled(uint256 indexed requestId, address indexed requester, uint256 refund);
    event Credited(address indexed account, uint256 indexed requestId, uint256 amount, uint8 reason);
    event CreditsWithdrawn(address indexed account, address indexed to, uint256 amount);
    event FeesPaid(address indexed recipient, uint256 amount);
    event MarginSet(uint96 margin);
    event FeeRecipientSet(address recipient);
    event ExclusiveWindowSet(uint32 seconds_);
    event CancelTimeoutSet(uint32 seconds_);
    event SunsetActivated(uint256 timestamp);

    error InvalidNumWords();
    error CallbackGasTooHigh();
    error CircuitOpen(uint256 stalledSince);
    error IntakeClosed();
    error InsufficientFee(uint256 required);
    error InsufficientGasForCallback(uint256 requestId);
    error NotRequester();
    error NotPending();
    error CancelNotYetAllowed(uint256 allowedAt);
    error RoundAlreadyPosted();
    error CallbackNotRetryable();
    error CallbackReverted();
    error NothingToWithdraw();
    error TransferFailed();
    error OutOfBounds();
    error InvalidConfiguration();
    error OwnershipRequired();
    error GasPriceOutOfRange();
    error PostingNotYetOpen(uint256 openAt);

    // requester
    function request(uint32 numWords, uint32 callbackGasLimit, bytes32 userSeed)
        external
        payable
        returns (uint256 requestId);
    function cancel(uint256 requestId) external;
    function withdrawCredits(address payable to) external;
    function pushCredits(address account) external;

    // posting and delivery
    function postRound(uint64 round, uint256[4] calldata signature) external returns (bytes32);
    function fulfill(uint64 round, uint256[4] calldata signature, uint256[] calldata requestIds)
        external
        returns (uint256 settled);
    function retryCallback(uint256 requestId) external;
    function payFees() external;

    // owner
    function setMargin(uint96 margin) external;
    function setFeeRecipient(address recipient) external;
    function setExclusiveWindow(uint32 seconds_) external;
    function setCancelTimeout(uint32 seconds_) external;
    function sunset() external;

    // views
    function getFee(uint32 numWords, uint32 callbackGasLimit) external view returns (uint256);
    function gasPriceRef() external view returns (uint256);
    function getRequest(uint256 requestId) external view returns (RequestView memory);
    function randomWords(uint256 requestId) external view returns (bool ready, uint256[] memory words);
    function randomWord(uint256 requestId, uint256 index) external view returns (bool ready, uint256 word);
    function roundRandomness(uint64 round) external view returns (bytes32);
    function latestPostedRound() external view returns (uint64);
    function nextTargetRound() external view returns (uint64);
    function roundTime(uint64 round) external pure returns (uint256);
    function roundAt(uint256 timestamp) external pure returns (uint64);
    function requestCount() external view returns (uint256);
    function pendingCount() external view returns (uint256);
    function lastProgressAt() external view returns (uint256);
    function acceptingRequests() external view returns (bool);
    function credits(address account) external view returns (uint256);
    function totals() external view returns (uint256 escrowed, uint256 credited, uint256 accruedFees);
    function config()
        external
        view
        returns (uint96 margin, uint32 exclusiveWindow, uint32 cancelTimeout, address feeRecipient);
    function isRelayer(address account) external view returns (bool);
    function relayers() external view returns (address[3] memory);
    function sunsetAt() external view returns (uint256);
    function MIN_LEAD() external view returns (uint256);
    function CHAIN_ID() external view returns (uint256);
    // forge-lint: disable-next-line(mixed-case-function) -- name fixed by the published ABI
    function VERSION() external pure returns (string memory);
}
