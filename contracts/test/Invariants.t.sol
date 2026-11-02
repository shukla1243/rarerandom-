// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {RareRandomV1} from "../src/RareRandomV1.sol";
import {IRareRandom} from "../src/interfaces/IRareRandom.sol";
import {CoreBase} from "./Base.t.sol";

/// @dev Drives random requests, deliveries (on time and late, relayer and stranger), cancels, withdrawals and fee
///      pushes against real drand rounds, and tracks the ground truth the accounting invariants are checked against.
contract Handler is Test {
    RareRandomV1 internal core;
    address internal relayer;
    address[] internal actors;
    uint64[] internal rounds;
    mapping(uint64 => uint256[4]) internal sigs;

    uint256[] public ids;
    uint256 public forced;

    constructor(RareRandomV1 c, address r, uint64[] memory rs, uint256[4][] memory ss) {
        core = c;
        relayer = r;
        for (uint256 i; i < rs.length; ++i) {
            rounds.push(rs[i]);
            sigs[rs[i]] = ss[i];
        }
        for (uint256 i; i < 4; ++i) {
            address a = address(uint160(0xA11CE + i));
            actors.push(a);
            vm.deal(a, 1000 ether);
        }
    }

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function request(uint256 actorSeed, uint256 roundSeed, uint32 n, uint32 cb, uint96 extra) external {
        uint64 round = rounds[roundSeed % rounds.length];
        vm.warp(core.roundTime(round) - 3);
        if (core.latestPostedRound() >= round || !core.acceptingRequests()) return;
        n = uint32(bound(n, 1, 32));
        cb = cb % 3 == 0 ? uint32(bound(cb, 1, 200_000)) : 0;
        extra = uint96(bound(extra, 0, 1 ether));
        address a = actors[actorSeed % actors.length];
        uint256 fee = core.getFee(n, cb);
        vm.prank(a);
        ids.push(core.request{value: fee + extra}(n, cb, bytes32(roundSeed)));
    }

    function deliver(uint256 idSeed, uint256 delay, bool asRelayer) external {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        IRareRandom.RequestView memory v = core.getRequest(id);
        if (v.status != 1) return;
        vm.warp(core.roundTime(v.targetRound) + bound(delay, 0, 1200));
        uint256[] memory list = new uint256[](1);
        list[0] = id;
        vm.prank(asRelayer ? relayer : actors[0]);
        try core.fulfill(v.targetRound, sigs[v.targetRound], list) {} catch {}
    }

    function cancel(uint256 idSeed) external {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        IRareRandom.RequestView memory v = core.getRequest(id);
        if (v.status != 1) return;
        vm.warp(v.cancellableAt);
        vm.prank(v.requester);
        try core.cancel(id) {} catch {}
    }

    function withdraw(uint256 actorSeed) external {
        address a = actors[actorSeed % actors.length];
        if (core.credits(a) == 0) return;
        vm.prank(a);
        core.withdrawCredits(payable(a));
    }

    function payFees() external {
        try core.payFees() {} catch {}
    }

    function forceEth(uint96 amount) external {
        amount = uint96(bound(amount, 1, 1 ether));
        forced += amount;
        vm.deal(address(core), address(core).balance + amount);
    }
}

contract InvariantsTest is CoreBase {
    Handler internal handler;

    function setUp() public override {
        super.setUp();
        uint64[] memory rs = new uint64[](6);
        uint256[4][] memory ss = new uint256[4][](6);
        for (uint256 i; i < 6; ++i) {
            Beacon memory b = _recent(5 - i);
            rs[i] = b.round;
            ss[i] = b.sig;
        }
        handler = new Handler(core, r0, rs, ss);
        targetContract(address(handler));
    }

    /// I1: the contract always holds at least escrow + credits + accrued fees.
    function invariant_I1_solvent() public view {
        (uint256 esc, uint256 cred, uint256 acc) = core.totals();
        assertGe(address(core).balance, esc + cred + acc);
    }

    /// I2 and I4: escrow equals the fees of Pending requests, and pendingCount equals their number.
    function invariant_I2_I4_escrowMatchesPending() public view {
        uint256 sum;
        uint256 pending;
        for (uint256 i; i < handler.idsLength(); ++i) {
            IRareRandom.RequestView memory v = core.getRequest(handler.ids(i));
            if (v.status == 1) {
                sum += v.fee;
                ++pending;
                assertEq(v.feeOutcome, 0);
            } else {
                assertTrue(v.feeOutcome != 0); // resolved requests always have a final fee outcome
            }
        }
        (uint256 esc,,) = core.totals();
        assertEq(esc, sum);
        assertEq(core.pendingCount(), pending);
    }

    /// I3: total credited equals the sum of individual credits.
    function invariant_I3_creditsSum() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorsLength(); ++i) {
            sum += core.credits(handler.actorAt(i));
        }
        (, uint256 cred,) = core.totals();
        assertEq(cred, sum);
    }

    /// Words, once readable, never change and match the derivation formula.
    function invariant_wordsAreDeterministic() public view {
        for (uint256 i; i < handler.idsLength(); ++i) {
            uint256 id = handler.ids(i);
            (bool ready, uint256[] memory w) = core.randomWords(id);
            if (!ready) continue;
            IRareRandom.RequestView memory v = core.getRequest(id);
            assertEq(w[0], _expectedWord(id, v.userSeed, core.roundRandomness(v.targetRound), 0));
        }
    }
}
