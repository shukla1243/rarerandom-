// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {RareRandomV1} from "../src/RareRandomV1.sol";
import {QuicknetBLS} from "../src/QuicknetBLS.sol";

contract BLSHarness {
    function verify(uint64 r, uint256[4] calldata s) external view returns (bytes32) {
        return QuicknetBLS.verify(r, s);
    }

    function tryVerify(uint64 r, uint256[4] calldata s) external view returns (bool, bytes32) {
        return QuicknetBLS.tryVerify(r, s);
    }

    function selfTest() external view returns (bool) {
        return QuicknetBLS.selfTest();
    }
}

abstract contract Fixtures is Test {
    struct Beacon {
        uint64 round;
        bytes32 randomness;
        uint256[4] sig;
    }

    uint256 internal constant P_HI = 0x1a0111ea397fe69a4b1ba7b6434bacd7;
    uint256 internal constant P_LO = 0x64774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab;

    Beacon[] internal beacons;

    function _loadFixtures() internal {
        string memory json = vm.readFile("test/fixtures/quicknet-rounds.json");
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".rounds[", vm.toString(n), "]"))) ++n;
        for (uint256 i; i < n; ++i) {
            string memory k = string.concat(".rounds[", vm.toString(i), "]");
            uint256[] memory s = vm.parseJsonUintArray(json, string.concat(k, ".sig"));
            beacons.push(
                Beacon({
                    round: uint64(vm.parseJsonUint(json, string.concat(k, ".round"))),
                    randomness: vm.parseJsonBytes32(json, string.concat(k, ".randomness")),
                    sig: [s[0], s[1], s[2], s[3]]
                })
            );
        }
    }

    /// @dev Negated point (x, p - y), split into hi/lo words.
    function _negate(uint256[4] memory s) internal pure returns (uint256[4] memory n) {
        uint256 lo;
        uint256 borrow;
        unchecked {
            lo = P_LO - s[3];
            borrow = s[3] > P_LO ? 1 : 0;
        }
        n = [s[0], s[1], P_HI - s[2] - borrow, lo];
    }

    /// @dev Non-canonical y + p (same point, invalid encoding).
    function _addP(uint256[4] memory s) internal pure returns (uint256[4] memory n) {
        uint256 lo;
        uint256 carry;
        unchecked {
            lo = s[3] + P_LO;
            carry = lo < s[3] ? 1 : 0;
        }
        n = [s[0], s[1], s[2] + P_HI + carry, lo];
    }
}

abstract contract CoreBase is Fixtures {
    RareRandomV1 internal core;
    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal r0 = makeAddr("relayer0");
    address internal r1 = makeAddr("relayer1");
    address internal alice = makeAddr("alice");
    address internal stranger = makeAddr("stranger");

    uint96 internal constant MARGIN = 5e12;
    uint32 internal constant WINDOW = 60;
    uint32 internal constant CANCEL = 86_400;

    function setUp() public virtual {
        _loadFixtures();
        core = _deploy();
        vm.deal(alice, 10 ether);
        vm.deal(stranger, 10 ether);
    }

    function _deploy() internal returns (RareRandomV1) {
        return new RareRandomV1(owner, treasury, MARGIN, WINDOW, CANCEL, [r0, r1, address(0)], 1, 0, 2e7);
    }

    /// @dev A recent consecutive beacon, by index from the end of the fixture list.
    function _recent(uint256 back) internal view returns (Beacon memory) {
        return beacons[beacons.length - 1 - back];
    }

    /// @dev Warp so that a request in this block binds to `round` (MIN_LEAD = 1).
    function _warpToBind(uint64 round) internal {
        vm.warp(core.roundTime(round) - 3);
    }

    function _ids(uint256 id) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = id;
    }

    function _expectedWord(uint256 id, bytes32 seed, bytes32 randomness, uint256 i) internal view returns (uint256) {
        return uint256(
            keccak256(
                abi.encode(keccak256("RareRandom.v1.word"), block.chainid, address(core), id, seed, randomness, i)
            )
        );
    }

    function _requestPull(address who, uint32 n, bytes32 seed) internal returns (uint256 id) {
        uint256 fee = core.getFee(n, 0);
        vm.prank(who);
        id = core.request{value: fee}(n, 0, seed);
    }
}
