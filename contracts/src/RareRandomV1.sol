// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IRareRandom} from "./interfaces/IRareRandom.sol";
import {QuicknetBLS} from "./QuicknetBLS.sol";

/// @title RareRandomV1
/// @notice Permissionless randomness bound to future drand quicknet rounds, verified on chain.
/// @dev Each request is bound at request time to a drand round that does not exist yet. The operator can delay a
///      result but can neither choose nor foresee it. Immutable: fixes ship as new versions.
contract RareRandomV1 is IRareRandom, Ownable2Step, ReentrancyGuardTransient {
    // ---------------------------------------------------------------- constants
    string public constant VERSION_STRING = "1.0.0";
    bytes32 public constant WORD_DOMAIN = keccak256("RareRandom.v1.word");
    uint256 public constant GENESIS_TIME = QuicknetBLS.GENESIS_TIME;
    uint256 public constant PERIOD = QuicknetBLS.PERIOD;

    uint256 public constant MAX_WORDS = 32;
    uint256 public constant MAX_CALLBACK_GAS = 2_500_000;
    uint256 public constant G_BASE = 200_000;
    uint256 public constant G_CALLBACK = 10_000;
    uint256 public constant G_WORD = 600;
    uint256 public constant CALLBACK_GAS_GUARD = 10_000;
    uint256 public constant STALL_TIMEOUT = 600;
    uint96 public constant MAX_MARGIN = 1e14;
    uint32 public constant MIN_EXCLUSIVE_WINDOW = 15;
    uint32 public constant MAX_EXCLUSIVE_WINDOW = 600; // also the posting window for non-relayers
    uint32 public constant MIN_CANCEL_TIMEOUT = 21_600;
    uint32 public constant MAX_CANCEL_TIMEOUT = 604_800;
    uint256 public constant MAX_PRICE_STEPS = 40;

    address internal constant ARB_GAS_INFO = address(0x6C);
    bytes4 internal constant GET_PRICES_IN_WEI = 0x41b247a8; // getPricesInWei()
    bytes4 internal constant CALLBACK_SELECTOR = 0x1fe543e3; // rawFulfillRandomWords(uint256,uint256[])

    uint8 internal constant STATUS_NONE = 0;
    uint8 internal constant STATUS_PENDING = 1;
    uint8 internal constant STATUS_FULFILLED = 2;
    uint8 internal constant STATUS_CANCELLED = 3;
    uint8 internal constant CB_NONE = 0;
    uint8 internal constant CB_PENDING = 1;
    uint8 internal constant CB_SUCCEEDED = 2;
    uint8 internal constant CB_FAILED = 3;
    uint8 internal constant FEE_ESCROWED = 0;
    uint8 internal constant FEE_EARNED = 1;
    uint8 internal constant FEE_REFUNDED = 2;
    uint8 internal constant CREDIT_OVERPAYMENT = 0;
    uint8 internal constant CREDIT_LATE = 1;
    uint8 internal constant CREDIT_CANCEL = 2;

    // ---------------------------------------------------------------- immutables
    uint256 public immutable CHAIN_ID;
    uint256 public immutable MIN_LEAD;
    uint8 public immutable GAS_PRICE_SOURCE; // 1 = ArbGasInfo + basefee (Nitro), 0 = basefee only
    uint256 public immutable GAS_PRICE_FLOOR;
    address public immutable RELAYER_0;
    address public immutable RELAYER_1;
    address public immutable RELAYER_2;

    // ---------------------------------------------------------------- storage
    struct Request {
        // slot 0
        address requester;
        uint64 targetRound;
        uint32 callbackGasLimit;
        // slot 1
        uint96 fee;
        uint40 createdAt;
        uint40 resolvedAt;
        uint16 windowSnapshot;
        uint24 cancelSnapshot;
        uint8 numWords;
        uint8 status;
        uint8 callbackStatus;
        uint8 feeOutcome;
        // slot 2
        bytes32 userSeed;
    }

    struct Globals {
        uint64 requestCount;
        uint64 latestPostedRound;
        uint40 lastProgressAt;
        uint32 pendingCount;
        uint40 sunsetAt;
    }

    struct Totals {
        uint96 escrowed;
        uint96 credited;
        uint64 sentinel; // stays 1 so the slot is never zeroed
    }

    struct Config {
        uint96 margin;
        uint16 exclusiveWindow;
        uint24 cancelTimeout;
    }

    Globals internal _g;
    Totals internal _t;
    Config internal _c;
    address internal _feeRecipient;
    uint96 internal _accruedFees;

    mapping(uint256 requestId => Request) internal _requests;
    mapping(uint64 round => bytes32 randomness) public roundRandomness;
    mapping(address account => uint256) public credits;

    // ---------------------------------------------------------------- constructor
    constructor(
        address owner_,
        address feeRecipient_,
        uint96 margin_,
        uint32 exclusiveWindow_,
        uint32 cancelTimeout_,
        address[3] memory relayers_,
        uint256 minLead_,
        uint8 gasPriceSource_,
        uint256 gasPriceFloor_
    ) Ownable(owner_) {
        if (!QuicknetBLS.selfTest()) revert InvalidConfiguration();
        if (feeRecipient_ == address(0) || relayers_[0] == address(0)) revert InvalidConfiguration();
        if (margin_ > MAX_MARGIN) revert InvalidConfiguration();
        if (exclusiveWindow_ < MIN_EXCLUSIVE_WINDOW || exclusiveWindow_ > MAX_EXCLUSIVE_WINDOW) {
            revert InvalidConfiguration();
        }
        if (cancelTimeout_ < MIN_CANCEL_TIMEOUT || cancelTimeout_ > MAX_CANCEL_TIMEOUT) revert InvalidConfiguration();
        if (minLead_ > 2 || gasPriceSource_ > 1 || gasPriceFloor_ == 0) revert InvalidConfiguration();
        if (gasPriceSource_ == 1 && _arbBaseFeeRaw(true) == 0) revert InvalidConfiguration();

        CHAIN_ID = block.chainid;
        MIN_LEAD = minLead_;
        GAS_PRICE_SOURCE = gasPriceSource_;
        GAS_PRICE_FLOOR = gasPriceFloor_;
        RELAYER_0 = relayers_[0];
        RELAYER_1 = relayers_[1];
        RELAYER_2 = relayers_[2];

        _feeRecipient = feeRecipient_;
        // forge-lint: disable-next-line(unsafe-typecast) -- window and timeout were bounds-checked above (<= 600 and <= 604,800 fit uint16 / uint24)
        _c = Config({margin: margin_, exclusiveWindow: uint16(exclusiveWindow_), cancelTimeout: uint24(cancelTimeout_)});
        _t.sentinel = 1;
    }

    // ---------------------------------------------------------------- requester

    /// @inheritdoc IRareRandom
    function request(uint32 numWords, uint32 callbackGasLimit, bytes32 userSeed)
        external
        payable
        returns (uint256 requestId)
    {
        if (!acceptingRequests()) {
            if (_g.sunsetAt != 0) revert IntakeClosed();
            revert CircuitOpen(_g.lastProgressAt);
        }
        if (numWords == 0 || numWords > MAX_WORDS) revert InvalidNumWords();
        if (callbackGasLimit > MAX_CALLBACK_GAS) revert CallbackGasTooHigh();
        uint256 fee = getFee(numWords, callbackGasLimit);
        if (msg.value < fee) revert InsufficientFee(fee);

        uint64 target = nextTargetRound();
        requestId = ++_g.requestCount;
        Config memory c = _c;
        _requests[requestId] = Request({
            requester: msg.sender,
            targetRound: target,
            callbackGasLimit: callbackGasLimit,
            // forge-lint: disable-next-line(unsafe-typecast) -- fee = q * units + margin, far below 2^96 wei for any q the 40-step ladder allows
            fee: uint96(fee),
            createdAt: uint40(block.timestamp),
            resolvedAt: 0,
            windowSnapshot: c.exclusiveWindow,
            cancelSnapshot: c.cancelTimeout,
            // forge-lint: disable-next-line(unsafe-typecast) -- numWords was checked to be 1..32 above
            numWords: uint8(numWords),
            status: STATUS_PENDING,
            callbackStatus: callbackGasLimit > 0 ? CB_PENDING : CB_NONE,
            feeOutcome: FEE_ESCROWED,
            userSeed: userSeed
        });

        if (_g.pendingCount == 0) _g.lastProgressAt = uint40(block.timestamp);
        _g.pendingCount += 1;
        // forge-lint: disable-next-line(unsafe-typecast) -- fee fits uint96, see above
        _t.escrowed += uint96(fee);

        emit RandomnessRequested(requestId, msg.sender, target, numWords, callbackGasLimit, fee, userSeed);

        uint256 excess = msg.value - fee;
        if (excess > 0) {
            credits[msg.sender] += excess;
            // forge-lint: disable-next-line(unsafe-typecast) -- excess <= msg.value, and all ETH in existence is below 2^96 wei
            _t.credited += uint96(excess);
            emit Credited(msg.sender, requestId, excess, CREDIT_OVERPAYMENT);
        }
    }

    /// @inheritdoc IRareRandom
    function cancel(uint256 requestId) external nonReentrant {
        Request storage r = _requests[requestId];
        if (r.requester != msg.sender) revert NotRequester();
        if (r.status != STATUS_PENDING) revert NotPending();
        uint256 allowedAt = uint256(r.createdAt) + r.cancelSnapshot;
        if (block.timestamp < allowedAt) revert CancelNotYetAllowed(allowedAt);
        // drand never skips a round, so any posted round >= target proves the target's value is public.
        if (_g.latestPostedRound >= r.targetRound) revert RoundAlreadyPosted();

        uint96 fee = r.fee;
        r.status = STATUS_CANCELLED;
        r.callbackStatus = CB_NONE;
        r.feeOutcome = FEE_REFUNDED;
        r.resolvedAt = uint40(block.timestamp);
        _t.escrowed -= fee;
        _t.credited += fee;
        credits[msg.sender] += fee;
        _g.pendingCount -= 1; // not progress: lastProgressAt unchanged

        emit RequestCancelled(requestId, msg.sender, fee);
        emit Credited(msg.sender, requestId, fee, CREDIT_CANCEL);
    }

    /// @inheritdoc IRareRandom
    function withdrawCredits(address payable to) external nonReentrant {
        _payCredits(msg.sender, to);
    }

    /// @inheritdoc IRareRandom
    function pushCredits(address account) external nonReentrant {
        _payCredits(account, payable(account));
    }

    // ---------------------------------------------------------------- posting and delivery

    /// @inheritdoc IRareRandom
    function postRound(uint64 round, uint256[4] calldata signature) external returns (bytes32 randomness) {
        randomness = roundRandomness[round];
        if (randomness != 0) return randomness;
        if (round == 0) revert QuicknetBLS.BadSignatureEncoding();
        if (!isRelayer(msg.sender)) {
            uint256 openAt = roundTime(round) + MAX_EXCLUSIVE_WINDOW + 1;
            if (block.timestamp < openAt) revert PostingNotYetOpen(openAt);
        }
        randomness = _post(round, signature);
    }

    /// @inheritdoc IRareRandom
    function fulfill(uint64 round, uint256[4] calldata signature, uint256[] calldata requestIds)
        external
        nonReentrant
        returns (uint256 settled)
    {
        bool relayer = isRelayer(msg.sender);
        if (roundRandomness[round] == 0) {
            if (round == 0) revert QuicknetBLS.BadSignatureEncoding();
            if (!relayer) {
                uint256 openAt = _postingOpenAt(round, requestIds);
                if (block.timestamp < openAt) revert PostingNotYetOpen(openAt);
            }
            _post(round, signature);
        }
        bytes32 randomness = roundRandomness[round];
        uint256 rt = roundTime(round);

        for (uint256 i; i < requestIds.length; ++i) {
            uint256 id = requestIds[i];
            Request storage r = _requests[id];
            // Silent skips: duplicates, stale ids, wrong round, or a non-relayer inside the window.
            if (r.status != STATUS_PENDING || r.targetRound != round) continue;
            bool onTime = block.timestamp <= rt + r.windowSnapshot;
            if (onTime && !relayer) continue;

            // State first: everything is written before the callback runs.
            address requester = r.requester;
            uint96 fee = r.fee;
            r.status = STATUS_FULFILLED;
            r.resolvedAt = uint40(block.timestamp);
            _t.escrowed -= fee;
            if (onTime) {
                r.feeOutcome = FEE_EARNED;
                _accruedFees += fee;
            } else {
                r.feeOutcome = FEE_REFUNDED;
                credits[requester] += fee;
                _t.credited += fee;
            }
            _g.pendingCount -= 1;
            _g.lastProgressAt = uint40(block.timestamp);
            ++settled;

            uint8 cbStatus = CB_NONE;
            if (r.callbackGasLimit > 0) {
                cbStatus = _firstCallback(id, r, randomness);
                r.callbackStatus = cbStatus;
            }
            emit RandomnessFulfilled(id, requester, round, msg.sender, onTime, cbStatus);
            if (!onTime) emit Credited(requester, id, fee, CREDIT_LATE);
        }
    }

    /// @inheritdoc IRareRandom
    function retryCallback(uint256 requestId) external nonReentrant {
        Request storage r = _requests[requestId];
        if (r.status != STATUS_FULFILLED || r.callbackStatus != CB_FAILED) revert CallbackNotRetryable();
        if (gasleft() < _callbackGasNeeded(r.callbackGasLimit)) revert InsufficientGasForCallback(requestId);
        r.callbackStatus = CB_SUCCEEDED;
        bytes memory data =
            abi.encodeWithSelector(CALLBACK_SELECTOR, requestId, _words(requestId, r, roundRandomness[r.targetRound]));
        address target = r.requester;
        bool ok;
        assembly ("memory-safe") {
            ok := call(gas(), target, 0, add(data, 0x20), mload(data), 0, 0)
        }
        if (!ok) revert CallbackReverted();
        emit CallbackRetried(requestId, target, msg.sender);
    }

    /// @inheritdoc IRareRandom
    function payFees() external nonReentrant {
        uint256 amount = address(this).balance - _t.escrowed - _t.credited; // checked: fails safe
        if (amount == 0) revert NothingToWithdraw();
        _accruedFees = 0;
        address recipient = _feeRecipient;
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit FeesPaid(recipient, amount);
    }

    // ---------------------------------------------------------------- owner

    function setMargin(uint96 margin_) external onlyOwner {
        if (margin_ > MAX_MARGIN) revert OutOfBounds();
        _c.margin = margin_;
        emit MarginSet(margin_);
    }

    function setFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert OutOfBounds();
        _feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    function setExclusiveWindow(uint32 seconds_) external onlyOwner {
        if (seconds_ < MIN_EXCLUSIVE_WINDOW || seconds_ > MAX_EXCLUSIVE_WINDOW) revert OutOfBounds();
        // forge-lint: disable-next-line(unsafe-typecast) -- seconds_ was bounds-checked to [15, 600]
        _c.exclusiveWindow = uint16(seconds_);
        emit ExclusiveWindowSet(seconds_);
    }

    function setCancelTimeout(uint32 seconds_) external onlyOwner {
        if (seconds_ < MIN_CANCEL_TIMEOUT || seconds_ > MAX_CANCEL_TIMEOUT) revert OutOfBounds();
        // forge-lint: disable-next-line(unsafe-typecast) -- seconds_ was bounds-checked to [21,600, 604,800]
        _c.cancelTimeout = uint24(seconds_);
        emit CancelTimeoutSet(seconds_);
    }

    /// @notice One-way: stops new requests only. Delivery, retry, cancel, credits and fees continue.
    function sunset() external onlyOwner {
        if (_g.sunsetAt != 0) revert OutOfBounds();
        _g.sunsetAt = uint40(block.timestamp);
        emit SunsetActivated(block.timestamp);
    }

    function renounceOwnership() public view override onlyOwner {
        revert OwnershipRequired();
    }

    // ---------------------------------------------------------------- views

    function getFee(uint32 numWords, uint32 callbackGasLimit) public view returns (uint256) {
        uint256 units = G_BASE;
        if (callbackGasLimit > 0) units += G_CALLBACK + uint256(callbackGasLimit) + G_WORD * uint256(numWords);
        return gasPriceRef() * units + _c.margin;
    }

    /// @notice Price step q: GAS_PRICE_FLOOR * 2^k for the smallest k with 2q >= 3b. Stable within a step.
    function gasPriceRef() public view returns (uint256 q) {
        uint256 b = block.basefee;
        uint256 arb = _arbBaseFeeRaw(false);
        if (arb > b) b = arb;
        if (GAS_PRICE_FLOOR > b) b = GAS_PRICE_FLOOR;
        q = GAS_PRICE_FLOOR;
        for (uint256 k; 2 * q < 3 * b; ++k) {
            if (k == MAX_PRICE_STEPS) revert GasPriceOutOfRange();
            q *= 2;
        }
    }

    function getRequest(uint256 requestId) external view returns (RequestView memory v) {
        Request storage r = _requests[requestId];
        if (r.requester == address(0)) return v;
        v = RequestView({
            requester: r.requester,
            targetRound: r.targetRound,
            callbackGasLimit: r.callbackGasLimit,
            numWords: r.numWords,
            status: r.status,
            callbackStatus: r.callbackStatus,
            feeOutcome: r.feeOutcome,
            fee: r.fee,
            createdAt: r.createdAt,
            resolvedAt: r.resolvedAt,
            exclusiveUntil: uint40(roundTime(r.targetRound) + r.windowSnapshot),
            cancellableAt: uint40(uint256(r.createdAt) + r.cancelSnapshot),
            userSeed: r.userSeed
        });
    }

    function randomWords(uint256 requestId) external view returns (bool ready, uint256[] memory words) {
        Request storage r = _requests[requestId];
        bytes32 rnd;
        (ready, rnd) = _readable(r);
        if (ready) words = _words(requestId, r, rnd);
    }

    function randomWord(uint256 requestId, uint256 index) external view returns (bool ready, uint256 word) {
        Request storage r = _requests[requestId];
        bytes32 rnd;
        (ready, rnd) = _readable(r);
        if (!ready || index >= r.numWords) return (false, 0);
        word = _word(requestId, r.userSeed, rnd, index);
    }

    function latestPostedRound() external view returns (uint64) {
        return _g.latestPostedRound;
    }

    function nextTargetRound() public view returns (uint64) {
        uint64 r = roundAt(block.timestamp + MIN_LEAD);
        uint64 floor = _g.latestPostedRound;
        return (r > floor ? r : floor) + 1;
    }

    function roundTime(uint64 round) public pure returns (uint256) {
        if (round == 0) return 0;
        return GENESIS_TIME + (uint256(round) - 1) * PERIOD;
    }

    function roundAt(uint256 timestamp) public pure returns (uint64) {
        if (timestamp < GENESIS_TIME) return 0;
        // forge-lint: disable-next-line(unsafe-typecast) -- a uint64 round count lasts ~1.7e12 years at 3 s per round
        return uint64((timestamp - GENESIS_TIME) / PERIOD + 1);
    }

    function requestCount() external view returns (uint256) {
        return _g.requestCount;
    }

    function pendingCount() external view returns (uint256) {
        return _g.pendingCount;
    }

    function lastProgressAt() external view returns (uint256) {
        return _g.lastProgressAt;
    }

    function sunsetAt() external view returns (uint256) {
        return _g.sunsetAt;
    }

    function acceptingRequests() public view returns (bool) {
        return
            _g.sunsetAt == 0 && (_g.pendingCount == 0 || block.timestamp <= uint256(_g.lastProgressAt) + STALL_TIMEOUT);
    }

    function totals() external view returns (uint256 escrowed, uint256 credited, uint256 accruedFees) {
        return (_t.escrowed, _t.credited, _accruedFees);
    }

    function config()
        external
        view
        returns (uint96 margin, uint32 exclusiveWindow, uint32 cancelTimeout, address feeRecipient)
    {
        Config memory c = _c;
        return (c.margin, c.exclusiveWindow, c.cancelTimeout, _feeRecipient);
    }

    function isRelayer(address account) public view returns (bool) {
        return account != address(0) && (account == RELAYER_0 || account == RELAYER_1 || account == RELAYER_2);
    }

    function relayers() external view returns (address[3] memory) {
        return [RELAYER_0, RELAYER_1, RELAYER_2];
    }

    // forge-lint: disable-next-line(mixed-case-function) -- name fixed by the published ABI
    function VERSION() external pure returns (string memory) {
        return VERSION_STRING;
    }

    // ---------------------------------------------------------------- internals

    function _post(uint64 round, uint256[4] calldata signature) internal returns (bytes32 randomness) {
        randomness = QuicknetBLS.verify(round, signature);
        roundRandomness[round] = randomness;
        if (round > _g.latestPostedRound) _g.latestPostedRound = round;
        emit RoundPosted(round, randomness, msg.sender);
    }

    /// @dev First second a non-relayer may post `round` through fulfill: after the posting window, or earlier
    ///      once any supplied Pending request bound to `round` is past its own exclusive window.
    function _postingOpenAt(uint64 round, uint256[] calldata ids) internal view returns (uint256 openAt) {
        uint256 rt = roundTime(round);
        openAt = rt + MAX_EXCLUSIVE_WINDOW + 1;
        for (uint256 i; i < ids.length; ++i) {
            Request storage r = _requests[ids[i]];
            if (r.status != STATUS_PENDING || r.targetRound != round) continue;
            uint256 t = rt + r.windowSnapshot + 1;
            if (t < openAt) openAt = t;
        }
    }

    function _firstCallback(uint256 id, Request storage r, bytes32 randomness) internal returns (uint8) {
        uint256 cbGas = r.callbackGasLimit;
        // 31/32 pre-check: the callee always receives its full limit, so a failure is the callee's own.
        if (gasleft() < _callbackGasNeeded(cbGas)) revert InsufficientGasForCallback(id);
        bytes memory data = abi.encodeWithSelector(CALLBACK_SELECTOR, id, _words(id, r, randomness));
        address target = r.requester;
        bool ok;
        assembly ("memory-safe") {
            ok := call(cbGas, target, 0, add(data, 0x20), mload(data), 0, 0) // no return data copied
        }
        return ok ? CB_SUCCEEDED : CB_FAILED;
    }

    function _callbackGasNeeded(uint256 cbGas) internal pure returns (uint256) {
        return (cbGas * 32 + 30) / 31 + CALLBACK_GAS_GUARD;
    }

    function _readable(Request storage r) internal view returns (bool, bytes32 rnd) {
        if (r.status != STATUS_PENDING && r.status != STATUS_FULFILLED) return (false, 0);
        rnd = roundRandomness[r.targetRound];
        return (rnd != 0, rnd);
    }

    function _words(uint256 id, Request storage r, bytes32 randomness) internal view returns (uint256[] memory w) {
        uint256 n = r.numWords;
        bytes32 seed = r.userSeed;
        w = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            w[i] = _word(id, seed, randomness, i);
        }
    }

    function _word(uint256 id, bytes32 seed, bytes32 randomness, uint256 i) internal view returns (uint256) {
        return uint256(keccak256(abi.encode(WORD_DOMAIN, CHAIN_ID, address(this), id, seed, randomness, i)));
    }

    function _payCredits(address account, address payable to) internal {
        uint256 amount = credits[account];
        if (amount == 0) revert NothingToWithdraw();
        credits[account] = 0;
        // forge-lint: disable-next-line(unsafe-typecast) -- amount is one account's credit, which is part of the uint96 total
        _t.credited -= uint96(amount);
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit CreditsWithdrawn(account, to, amount);
    }

    /// @dev ArbGasInfo.getPricesInWei()[5] (the L2 base fee). Any failure or short return yields 0, never a revert,
    ///      except when `strict` (constructor check).
    function _arbBaseFeeRaw(bool strict) internal view returns (uint256 fee) {
        if (!strict && GAS_PRICE_SOURCE != 1) return 0;
        bytes4 sel = GET_PRICES_IN_WEI;
        address target = ARB_GAS_INFO;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, sel)
            let ok := and(eq(returndatasize(), 192), staticcall(gas(), target, ptr, 4, ptr, 192))
            if ok { fee := mload(add(ptr, 160)) }
        }
    }
}
