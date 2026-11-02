// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {RareRandomV1} from "../src/RareRandomV1.sol";
import {IRareRandom, IRareRandomConsumer} from "../src/interfaces/IRareRandom.sol";
import {QuicknetBLS} from "../src/QuicknetBLS.sol";
import {CoinFlip} from "../src/consumer/CoinFlip.sol";
import {CoreBase} from "./Base.t.sol";

/// @dev Consumer whose callback can be switched to revert, to test failure and retry.
contract FlakyConsumer is IRareRandomConsumer {
    IRareRandom public immutable core;
    bool public broken = true;
    uint256 public gotId;
    uint256[] public got;

    constructor(IRareRandom c) payable {
        core = c;
    }

    function ask(uint32 n, uint32 cbGas) external returns (uint256) {
        return core.request{value: core.getFee(n, cbGas)}(n, cbGas, bytes32(uint256(7)));
    }

    function fix() external {
        broken = false;
    }

    function rawFulfillRandomWords(uint256 id, uint256[] calldata words) external {
        require(msg.sender == address(core));
        require(!broken, "broken");
        gotId = id;
        got = words;
    }

    function gotLength() external view returns (uint256) {
        return got.length;
    }

    receive() external payable {}
}

/// @dev Consumer that requests again from inside its callback (Entropy integrators do this).
contract ChainingConsumer is IRareRandomConsumer {
    IRareRandom public immutable core;
    uint256 public chainedId;

    constructor(IRareRandom c) payable {
        core = c;
    }

    function ask() external returns (uint256) {
        return core.request{value: core.getFee(1, 300_000)}(1, 300_000, 0);
    }

    function rawFulfillRandomWords(uint256, uint256[] calldata) external {
        chainedId = core.request{value: core.getFee(1, 0)}(1, 0, 0);
    }
}

/// @dev Rejects plain ETH, like two of the stranded Dice requesters.
contract EthRejecter {
    function ask(IRareRandom core) external payable returns (uint256) {
        return core.request{value: msg.value}(1, 0, 0);
    }

    function doCancel(IRareRandom core, uint256 id) external {
        core.cancel(id);
    }

    function withdrawTo(IRareRandom core, address payable to) external {
        core.withdrawCredits(to);
    }
}

contract RareRandomV1Test is CoreBase {
    // ------------------------------------------------------------ config and deployment

    function test_constructor_storesConfig() public view {
        (uint96 m, uint32 w, uint32 c, address fr) = core.config();
        assertEq(m, MARGIN);
        assertEq(w, WINDOW);
        assertEq(c, CANCEL);
        assertEq(fr, treasury);
        assertEq(core.owner(), owner);
        assertEq(core.MIN_LEAD(), 1);
        assertEq(core.CHAIN_ID(), block.chainid);
        assertEq(core.VERSION(), "1.0.0");
        assertTrue(core.isRelayer(r0) && core.isRelayer(r1));
        assertFalse(core.isRelayer(address(0)) || core.isRelayer(stranger));
        assertEq(core.WORD_DOMAIN(), 0xcab1f1535ccd2b62977562f32f864cc306ad76e0e4ead78ee553e427674f8683);
    }

    function test_constructor_rejectsBadConfig() public {
        address[3] memory rel = [r0, r1, address(0)];
        vm.expectRevert(IRareRandom.InvalidConfiguration.selector);
        new RareRandomV1(owner, address(0), MARGIN, WINDOW, CANCEL, rel, 1, 0, 2e7);
        vm.expectRevert(IRareRandom.InvalidConfiguration.selector);
        new RareRandomV1(owner, treasury, MARGIN, WINDOW, CANCEL, [address(0), r1, address(0)], 1, 0, 2e7);
        vm.expectRevert(IRareRandom.InvalidConfiguration.selector);
        new RareRandomV1(owner, treasury, 1e14 + 1, WINDOW, CANCEL, rel, 1, 0, 2e7);
        vm.expectRevert(IRareRandom.InvalidConfiguration.selector);
        new RareRandomV1(owner, treasury, MARGIN, 14, CANCEL, rel, 1, 0, 2e7);
        vm.expectRevert(IRareRandom.InvalidConfiguration.selector);
        new RareRandomV1(owner, treasury, MARGIN, WINDOW, 3600, rel, 1, 0, 2e7);
        vm.expectRevert(IRareRandom.InvalidConfiguration.selector);
        new RareRandomV1(owner, treasury, MARGIN, WINDOW, CANCEL, rel, 3, 0, 2e7);
        // GAS_PRICE_SOURCE = 1 needs a working ArbGasInfo, absent here
        vm.expectRevert(IRareRandom.InvalidConfiguration.selector);
        new RareRandomV1(owner, treasury, MARGIN, WINDOW, CANCEL, rel, 1, 1, 2e7);
    }

    // ------------------------------------------------------------ round binding

    function test_roundArithmetic() public view {
        assertEq(core.roundTime(1), 1692803367);
        assertEq(core.roundAt(1692803367), 1);
        assertEq(core.roundAt(1692803369), 1);
        assertEq(core.roundAt(1692803370), 2);
        assertEq(core.roundAt(0), 0);
        assertEq(core.roundTime(0), 0);
    }

    function test_binding_specWorkedExample() public {
        vm.warp(1793517290);
        assertEq(core.nextTargetRound(), 33571310);
        assertEq(core.roundTime(33571310), 1793517294);
    }

    /// @notice With MIN_LEAD = 1, the bound round's time is always 2-4 s after the request.
    function testFuzz_binding_leadWindow(uint256 t) public {
        t = bound(t, 1692803367, 1692803367 + 100 * 365 days);
        vm.warp(t);
        uint256 lead = core.roundTime(core.nextTargetRound()) - t;
        assertGe(lead, 2);
        assertLe(lead, 4);
    }

    function test_binding_flooredByLatestPostedRound() public {
        Beacon memory b = _recent(0);
        vm.prank(r0);
        core.postRound(b.round, b.sig);
        vm.warp(core.roundTime(b.round) - 30); // clock behind a round already on chain
        assertEq(core.nextTargetRound(), b.round + 1);
    }

    // ------------------------------------------------------------ fees

    function test_fee_specVectors() public {
        vm.fee(20_030_000);
        assertEq(core.gasPriceRef(), 4e7);
        assertEq(core.getFee(1, 0), 13_000_000_000_000);
        assertEq(core.getFee(32, 0), 13_000_000_000_000);
        assertEq(core.getFee(1, 100_000), 17_424_000_000_000);
        assertEq(core.getFee(1, 200_000), 21_424_000_000_000);
        assertEq(core.getFee(32, 200_000), 22_168_000_000_000);
    }

    function test_fee_priceStepBoundary() public {
        vm.fee(26_666_666);
        assertEq(core.gasPriceRef(), 4e7);
        vm.fee(26_666_667);
        assertEq(core.gasPriceRef(), 8e7);
    }

    function test_fee_outOfRange() public {
        vm.fee(18e18); // needs k = 41 > MAX_PRICE_STEPS
        vm.expectRevert(IRareRandom.GasPriceOutOfRange.selector);
        core.gasPriceRef();
    }

    // ------------------------------------------------------------ request

    function test_request_validation() public {
        uint256 fee = core.getFee(1, 0);
        vm.startPrank(alice);
        vm.expectRevert(IRareRandom.InvalidNumWords.selector);
        core.request{value: fee}(0, 0, 0);
        vm.expectRevert(IRareRandom.InvalidNumWords.selector);
        core.request{value: fee}(33, 0, 0);
        vm.expectRevert(IRareRandom.CallbackGasTooHigh.selector);
        core.request{value: 1 ether}(1, 2_500_001, 0);
        vm.expectRevert(abi.encodeWithSelector(IRareRandom.InsufficientFee.selector, fee));
        core.request{value: fee - 1}(1, 0, 0);
        vm.stopPrank();
    }

    function test_request_overpaymentCredited() public {
        uint256 fee = core.getFee(1, 0);
        vm.prank(alice);
        uint256 id = core.request{value: fee + 1 ether}(1, 0, 0);
        assertEq(core.credits(alice), 1 ether);
        IRareRandom.RequestView memory v = core.getRequest(id);
        assertEq(v.fee, fee);
        (uint256 esc, uint256 cred,) = core.totals();
        assertEq(esc, fee);
        assertEq(cred, 1 ether);
    }

    function test_request_storesView() public {
        Beacon memory b = _recent(0);
        _warpToBind(b.round);
        uint256 id = _requestPull(alice, 3, bytes32(uint256(42)));
        assertEq(id, 1);
        IRareRandom.RequestView memory v = core.getRequest(id);
        assertEq(v.requester, alice);
        assertEq(v.targetRound, b.round);
        assertEq(v.numWords, 3);
        assertEq(v.status, 1);
        assertEq(v.exclusiveUntil, core.roundTime(b.round) + WINDOW);
        assertEq(v.cancellableAt, block.timestamp + CANCEL);
        assertEq(core.pendingCount(), 1);
        (bool ready,) = core.randomWords(id);
        assertFalse(ready);
        assertEq(core.getRequest(999).requester, address(0)); // unknown ids never revert
    }

    // ------------------------------------------------------------ delivery

    function test_fulfill_onTimeByRelayer_earnsFee() public {
        Beacon memory b = _recent(0);
        _warpToBind(b.round);
        bytes32 seed = bytes32(uint256(42));
        uint256 id = _requestPull(alice, 3, seed);
        uint256 fee = core.getRequest(id).fee;

        vm.warp(core.roundTime(b.round) + 1);
        vm.prank(r0);
        assertEq(core.fulfill(b.round, b.sig, _ids(id)), 1);

        IRareRandom.RequestView memory v = core.getRequest(id);
        assertEq(v.status, 2);
        assertEq(v.feeOutcome, 1);
        (uint256 esc,, uint256 accrued) = core.totals();
        assertEq(esc, 0);
        assertEq(accrued, fee);
        assertEq(core.pendingCount(), 0);
        assertEq(core.roundRandomness(b.round), b.randomness);

        (bool ready, uint256[] memory w) = core.randomWords(id);
        assertTrue(ready);
        assertEq(w.length, 3);
        for (uint256 i; i < 3; ++i) {
            assertEq(w[i], _expectedWord(id, seed, b.randomness, i));
        }
        (bool r2, uint256 w1) = core.randomWord(id, 1);
        assertTrue(r2);
        assertEq(w1, w[1]);
        (r2,) = core.randomWord(id, 3);
        assertFalse(r2);
    }

    function test_wordDerivation_specVector() public {
        // Spec §3.6: chain 4663, core at 0x...c0ffee01, id 1, seed 0x11..11, round 33571307.
        vm.chainId(4663);
        address coreAt = 0x00000000000000000000000000000000C0FFEE01;
        deployCodeTo(
            "RareRandomV1.sol:RareRandomV1",
            abi.encode(owner, treasury, MARGIN, WINDOW, CANCEL, [r0, r1, address(0)], 1, 0, 2e7),
            coreAt
        );
        RareRandomV1 c = RareRandomV1(coreAt);
        vm.warp(c.roundTime(33571307) - 3);
        bytes32 seed = 0x1111111111111111111111111111111111111111111111111111111111111111;
        vm.prank(alice);
        uint256 id = c.request{value: c.getFee(2, 0)}(2, 0, seed);
        assertEq(id, 1);
        vm.prank(r0);
        c.postRound(
            33571307,
            [
                uint256(0x0eb65c9efe22e3b31947e2b5a4671d24),
                0x6ac79f04d9a1b7e2379314bc856a52b68077d5448f585ce469417a2fc132adc4,
                0x0855ff600d6b9fd4d583af149551288d,
                0xcef137690f86b9f14664a7051220d47a841468657202a0d782d32468dc45b8fa
            ]
        );
        (bool ready, uint256[] memory w) = c.randomWords(id);
        assertTrue(ready);
        assertEq(w[0], 0xbd0f27d184287b2f6b171ed3f0540758da497914bc79b213e59f6c0a210f7d03);
        assertEq(w[1], 0x3a5aadd6eeac8ee2966d24c33fd2d456f9ef1f0870bfc030dfd602ab67eb836a);
    }

    function test_postRound_makesPendingReadable() public {
        Beacon memory b = _recent(0);
        _warpToBind(b.round);
        uint256 id = _requestPull(alice, 1, 0);
        vm.warp(core.roundTime(b.round));
        vm.prank(r1);
        core.postRound(b.round, b.sig);
        (bool ready,) = core.randomWords(id);
        assertTrue(ready);
        assertEq(core.getRequest(id).status, 1); // still Pending: readable is separate from delivered
        assertEq(core.latestPostedRound(), b.round);
    }

    function test_postRound_relayerGatedWindow() public {
        Beacon memory b = _recent(0);
        uint256 rt = core.roundTime(b.round);
        vm.warp(rt + 600);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IRareRandom.PostingNotYetOpen.selector, rt + 601));
        core.postRound(b.round, b.sig);
        vm.warp(rt + 601);
        vm.prank(stranger);
        assertEq(core.postRound(b.round, b.sig), b.randomness);
    }

    function test_postRound_rejectsBadSignature() public {
        Beacon memory b = _recent(0);
        vm.startPrank(r0);
        vm.expectRevert(QuicknetBLS.InvalidSignature.selector);
        core.postRound(b.round + 1, b.sig);
        vm.expectRevert(QuicknetBLS.BadSignatureEncoding.selector);
        core.postRound(0, b.sig);
        vm.stopPrank();
    }

    function test_fulfill_strangerInsideWindow_cannotPostOrSettle() public {
        Beacon memory b = _recent(0);
        _warpToBind(b.round);
        uint256 id = _requestPull(alice, 1, 0);
        uint256 rt = core.roundTime(b.round);
        vm.warp(rt + 10);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IRareRandom.PostingNotYetOpen.selector, rt + WINDOW + 1));
        core.fulfill(b.round, b.sig, _ids(id));

        // Once the relayer has posted, a stranger's in-window call settles nothing.
        vm.prank(r0);
        core.postRound(b.round, b.sig);
        vm.prank(stranger);
        assertEq(core.fulfill(b.round, b.sig, _ids(id)), 0);
        assertEq(core.getRequest(id).status, 1);
    }

    function test_escapeHatch_lateDeliveryByAnyone_refunds() public {
        Beacon memory b = _recent(0);
        _warpToBind(b.round);
        uint256 id = _requestPull(alice, 1, 0);
        uint256 fee = core.getRequest(id).fee;
        vm.warp(core.roundTime(b.round) + WINDOW + 1);
        vm.prank(stranger);
        assertEq(core.fulfill(b.round, b.sig, _ids(id)), 1);
        IRareRandom.RequestView memory v = core.getRequest(id);
        assertEq(v.status, 2);
        assertEq(v.feeOutcome, 2);
        assertEq(core.credits(alice), fee);
        (,, uint256 accrued) = core.totals();
        assertEq(accrued, 0);

        uint256 before = alice.balance;
        vm.prank(alice);
        core.withdrawCredits(payable(alice));
        assertEq(alice.balance, before + fee);
        assertEq(core.credits(alice), 0);
    }

    function test_lateDeliveryByRelayer_alsoRefunds() public {
        Beacon memory b = _recent(0);
        _warpToBind(b.round);
        uint256 id = _requestPull(alice, 1, 0);
        vm.warp(core.roundTime(b.round) + WINDOW + 1);
        vm.prank(r0);
        core.fulfill(b.round, b.sig, _ids(id));
        assertEq(core.getRequest(id).feeOutcome, 2);
        assertEq(core.credits(alice), core.getRequest(id).fee);
    }

    function test_windowBoundaryIsInclusive() public {
        Beacon memory b = _recent(0);
        _warpToBind(b.round);
        uint256 id = _requestPull(alice, 1, 0);
        vm.warp(core.roundTime(b.round) + WINDOW);
        vm.prank(r0);
        core.fulfill(b.round, b.sig, _ids(id));
        assertEq(core.getRequest(id).feeOutcome, 1);
    }

    function test_fulfill_skipsSilently() public {
        Beacon memory b = _recent(1);
        Beacon memory other = _recent(0);
        _warpToBind(b.round);
        uint256 id = _requestPull(alice, 1, 0);
        vm.warp(core.roundTime(other.round));
        uint256[] memory ids = new uint256[](4);
        ids[0] = id; // wrong round for this call
        ids[1] = 777; // unknown
        ids[2] = 0;
        ids[3] = id;
        vm.prank(r0);
        assertEq(core.fulfill(other.round, other.sig, ids), 0);
        // Duplicates in the right round settle once.
        uint256[] memory dup = new uint256[](2);
        dup[0] = id;
        dup[1] = id;
        vm.prank(r0);
        assertEq(core.fulfill(b.round, b.sig, dup), 1);
    }

    function test_batch_manyRequestsOneRound() public {
        Beacon memory b = _recent(0);
        _warpToBind(b.round);
        uint256[] memory ids = new uint256[](10);
        for (uint256 i; i < 10; ++i) {
            ids[i] = _requestPull(alice, 1, bytes32(i));
        }
        vm.warp(core.roundTime(b.round) + 1);
        vm.prank(r0);
        assertEq(core.fulfill(b.round, b.sig, ids), 10);
        assertEq(core.pendingCount(), 0);
        (, uint256[] memory w0) = core.randomWords(ids[0]);
        (, uint256[] memory w1) = core.randomWords(ids[1]);
        assertTrue(w0[0] != w1[0]);
    }

    // ------------------------------------------------------------ callbacks

    function test_callback_coinFlip() public {
        CoinFlip game = new CoinFlip(core);
        Beacon memory b = _recent(0);
        _warpToBind(b.round);
        uint256 q = game.quote();
        vm.prank(alice);
        uint256 id = game.flip{value: q}(true);
        vm.warp(core.roundTime(b.round) + 1);
        vm.prank(r0);
        core.fulfill(b.round, b.sig, _ids(id));
        (address player,, bool settled, bool won) = game.flips(id);
        assertEq(player, alice);
        assertTrue(settled);
        (, uint256 word) = core.randomWord(id, 0);
        assertEq(won, (word & 1) == 1);
        assertEq(core.getRequest(id).callbackStatus, 2);
    }

    function test_callback_failureKeepsWords_thenRetrySameValue() public {
        FlakyConsumer c = new FlakyConsumer{value: 1 ether}(core);
        Beacon memory b = _recent(0);
        _warpToBind(b.round);
        uint256 id = c.ask(2, 100_000);
        vm.warp(core.roundTime(b.round) + 1);
        vm.prank(r0);
        core.fulfill(b.round, b.sig, _ids(id));
        IRareRandom.RequestView memory v = core.getRequest(id);
        assertEq(v.status, 2);
        assertEq(v.callbackStatus, 3); // Failed
        assertEq(v.feeOutcome, 1); // fee outcome does not depend on callback success
        (bool ready, uint256[] memory w) = core.randomWords(id);
        assertTrue(ready);

        vm.expectRevert(IRareRandom.CallbackReverted.selector);
        core.retryCallback(id);
        assertEq(core.getRequest(id).callbackStatus, 3);

        c.fix();
        vm.prank(stranger); // anyone may retry
        core.retryCallback(id);
        assertEq(core.getRequest(id).callbackStatus, 2);
        assertEq(c.gotId(), id);
        assertEq(c.got(0), w[0]);
        assertEq(c.got(1), w[1]);

        vm.expectRevert(IRareRandom.CallbackNotRetryable.selector);
        core.retryCallback(id);
    }

    function test_callback_insufficientGasRevertsWholeTx() public {
        FlakyConsumer c = new FlakyConsumer{value: 1 ether}(core);
        c.fix();
        Beacon memory b = _recent(0);
        _warpToBind(b.round);
        uint256 id = c.ask(1, 1_000_000);
        vm.warp(core.roundTime(b.round) + 1);
        vm.prank(r0);
        vm.expectRevert(abi.encodeWithSelector(IRareRandom.InsufficientGasForCallback.selector, id));
        core.fulfill{gas: 900_000}(b.round, b.sig, _ids(id));
        assertEq(core.getRequest(id).status, 1); // nothing settled, relayer cannot force a failure
    }

    function test_callback_canRequestAgain() public {
        ChainingConsumer c = new ChainingConsumer{value: 1 ether}(core);
        Beacon memory b = _recent(1);
        _warpToBind(b.round);
        uint256 id = c.ask();
        // Stall: settle long after the breaker would trip, as during catch-up.
        vm.warp(core.roundTime(b.round) + 700);
        assertFalse(core.acceptingRequests());
        vm.prank(r0);
        core.fulfill(b.round, b.sig, _ids(id));
        assertEq(core.getRequest(id).callbackStatus, 2);
        assertEq(c.chainedId(), id + 1);
    }

    function test_callback_targetWithoutCodeSucceeds() public {
        Beacon memory b = _recent(0);
        _warpToBind(b.round);
        uint256 fee = core.getFee(1, 50_000);
        vm.prank(alice);
        uint256 id = core.request{value: fee}(1, 50_000, 0);
        vm.warp(core.roundTime(b.round) + 1);
        vm.prank(r0);
        core.fulfill(b.round, b.sig, _ids(id));
        assertEq(core.getRequest(id).callbackStatus, 2);
    }

    // ------------------------------------------------------------ cancel

    function test_cancel_rules() public {
        Beacon memory b = _recent(0);
        _warpToBind(b.round);
        uint256 id = _requestPull(alice, 1, 0);
        uint256 fee = core.getRequest(id).fee;
        uint256 allowedAt = block.timestamp + CANCEL;

        vm.prank(stranger);
        vm.expectRevert(IRareRandom.NotRequester.selector);
        core.cancel(id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IRareRandom.CancelNotYetAllowed.selector, allowedAt));
        core.cancel(id);

        vm.warp(allowedAt);
        vm.prank(alice);
        core.cancel(id);
        IRareRandom.RequestView memory v = core.getRequest(id);
        assertEq(v.status, 3);
        assertEq(v.feeOutcome, 2);
        assertEq(core.credits(alice), fee);
        assertEq(core.pendingCount(), 0);

        // A cancelled request never exposes words, even once its round is posted, and can't be delivered.
        vm.prank(r0);
        core.postRound(b.round, b.sig);
        (bool ready,) = core.randomWords(id);
        assertFalse(ready);
        vm.prank(r0);
        assertEq(core.fulfill(b.round, b.sig, _ids(id)), 0);
        vm.prank(alice);
        vm.expectRevert(IRareRandom.NotPending.selector);
        core.cancel(id);
    }

    function test_cancel_closedOnceLaterRoundPosted() public {
        Beacon memory b = _recent(1);
        Beacon memory later = _recent(0);
        _warpToBind(b.round);
        uint256 id = _requestPull(alice, 1, 0);
        vm.prank(r0);
        core.postRound(later.round, later.sig); // a later round proves the target's value is public
        vm.warp(block.timestamp + CANCEL);
        vm.prank(alice);
        vm.expectRevert(IRareRandom.RoundAlreadyPosted.selector);
        core.cancel(id);
    }

    // ------------------------------------------------------------ credits and fees

    function test_credits_rejectingContractRoutesElsewhere() public {
        EthRejecter rej = new EthRejecter();
        Beacon memory b = _recent(0);
        _warpToBind(b.round);
        uint256 fee = core.getFee(1, 0);
        vm.deal(address(this), 1 ether);
        uint256 id = rej.ask{value: fee + 1000}(core);
        vm.expectRevert(IRareRandom.TransferFailed.selector);
        core.pushCredits(address(rej));
        assertEq(core.credits(address(rej)), 1000); // credit stays
        rej.withdrawTo(core, payable(treasury));
        assertEq(treasury.balance, 1000);
        id;
        vm.expectRevert(IRareRandom.NothingToWithdraw.selector);
        core.pushCredits(address(rej));
    }

    function test_payFees_onlyAccruedAndForced() public {
        Beacon memory b = _recent(0);
        _warpToBind(b.round);
        uint256 a = _requestPull(alice, 1, 0);
        _requestPull(alice, 1, 0); // stays pending: its fee must not be paid out
        vm.warp(core.roundTime(b.round) + 1);
        vm.prank(r0);
        core.fulfill(b.round, b.sig, _ids(a));
        uint256 fee = core.getRequest(a).fee;

        vm.deal(address(core), address(core).balance + 5); // forced ETH
        vm.prank(stranger);
        core.payFees();
        assertEq(treasury.balance, fee + 5);
        (uint256 esc, uint256 cred, uint256 accrued) = core.totals();
        assertEq(esc, fee);
        assertEq(cred, 0);
        assertEq(accrued, 0);
        assertEq(address(core).balance, esc);
        vm.expectRevert(IRareRandom.NothingToWithdraw.selector);
        core.payFees();
    }

    // ------------------------------------------------------------ circuit breaker

    function test_breaker_tripsAfterStall_andClearsOnSettlement() public {
        Beacon memory b = _recent(0);
        _warpToBind(b.round);
        uint256 id = _requestPull(alice, 1, 0);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 600);
        assertTrue(core.acceptingRequests());
        vm.warp(t0 + 601);
        assertFalse(core.acceptingRequests());
        uint256 fee = core.getFee(1, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IRareRandom.CircuitOpen.selector, t0));
        core.request{value: fee}(1, 0, 0);

        vm.prank(stranger);
        core.fulfill(b.round, b.sig, _ids(id)); // hatch delivery is progress
        assertTrue(core.acceptingRequests());
    }

    function test_breaker_idleNeverTrips() public {
        vm.warp(block.timestamp + 30 days);
        assertTrue(core.acceptingRequests());
    }

    // ------------------------------------------------------------ owner

    function test_owner_boundsAndPowers() public {
        vm.startPrank(owner);
        vm.expectRevert(IRareRandom.OutOfBounds.selector);
        core.setMargin(1e14 + 1);
        core.setMargin(1e14);
        vm.expectRevert(IRareRandom.OutOfBounds.selector);
        core.setExclusiveWindow(601);
        core.setExclusiveWindow(15);
        vm.expectRevert(IRareRandom.OutOfBounds.selector);
        core.setCancelTimeout(21_599);
        core.setCancelTimeout(604_800);
        vm.expectRevert(IRareRandom.OutOfBounds.selector);
        core.setFeeRecipient(address(0));
        core.setFeeRecipient(stranger);
        vm.expectRevert(IRareRandom.OwnershipRequired.selector);
        core.renounceOwnership();
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert();
        core.setMargin(0);
    }

    function test_settingsDoNotTouchInFlightRequests() public {
        Beacon memory b = _recent(0);
        _warpToBind(b.round);
        uint256 id = _requestPull(alice, 1, 0);
        vm.prank(owner);
        core.setExclusiveWindow(15);
        assertEq(core.getRequest(id).exclusiveUntil, core.roundTime(b.round) + WINDOW);
    }

    function test_sunset_stopsIntakeOnly() public {
        Beacon memory b = _recent(0);
        _warpToBind(b.round);
        uint256 id = _requestPull(alice, 1, 0);
        vm.prank(owner);
        core.sunset();
        uint256 fee = core.getFee(1, 0);
        vm.prank(alice);
        vm.expectRevert(IRareRandom.IntakeClosed.selector);
        core.request{value: fee}(1, 0, 0);
        vm.prank(r0);
        assertEq(core.fulfill(b.round, b.sig, _ids(id)), 1);
        vm.prank(owner);
        vm.expectRevert(IRareRandom.OutOfBounds.selector);
        core.sunset();
    }

    // ------------------------------------------------------------ gas report

    function test_gas_report() public {
        Beacon memory b = _recent(0);
        _warpToBind(b.round);
        uint256 fee = core.getFee(1, 0);
        vm.prank(alice);
        uint256 g = gasleft();
        uint256 id = core.request{value: fee}(1, 0, 0);
        emit log_named_uint("request (pull, first)", g - gasleft());
        vm.warp(core.roundTime(b.round) + 1);
        vm.prank(r0);
        g = gasleft();
        core.fulfill(b.round, b.sig, _ids(id));
        emit log_named_uint("fulfill (post + 1 pull)", g - gasleft());
    }
}
