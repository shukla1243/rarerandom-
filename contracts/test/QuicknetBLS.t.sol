// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {QuicknetBLS} from "../src/QuicknetBLS.sol";
import {BLSHarness, Fixtures} from "./Base.t.sol";

contract QuicknetBLSTest is Fixtures {
    BLSHarness internal h;

    function setUp() public {
        h = new BLSHarness();
        _loadFixtures();
    }

    /// @dev Under `EXPECT_NO_BLS=true FOUNDRY_PROFILE=nobls` (no EIP-2537) every call must fail closed.
    function test_selfTest() public view {
        if (vm.envOr("EXPECT_NO_BLS", false)) {
            assertFalse(h.selfTest());
            (bool ok,) = h.tryVerify(beacons[0].round, beacons[0].sig);
            assertFalse(ok);
        } else {
            assertTrue(h.selfTest());
        }
    }

    function test_pinnedConstants() public pure {
        assertEq(
            keccak256(bytes("BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_NUL_")),
            keccak256(abi.encodePacked(QuicknetBLS.DST_HEAD, bytes11(QuicknetBLS.DST_TAIL_PRIME)))
        );
        assertEq(uint8(QuicknetBLS.DST_TAIL_PRIME[11]), 43);
    }

    /// @notice Every fixture round (fetched from two relays, verified by noble) matches drand's randomness on chain.
    function test_differential_allFixtures() public view {
        assertGt(beacons.length, 60);
        for (uint256 i; i < beacons.length; ++i) {
            assertEq(h.verify(beacons[i].round, beacons[i].sig), beacons[i].randomness, vm.toString(beacons[i].round));
        }
    }

    function test_specKnownAnswer_33571307() public {
        uint256[4] memory s = [
            uint256(0x0eb65c9efe22e3b31947e2b5a4671d24),
            0x6ac79f04d9a1b7e2379314bc856a52b68077d5448f585ce469417a2fc132adc4,
            0x0855ff600d6b9fd4d583af149551288d,
            0xcef137690f86b9f14664a7051220d47a841468657202a0d782d32468dc45b8fa
        ];
        uint256 g = gasleft();
        bytes32 r = h.verify(33571307, s);
        emit log_named_uint("verify gas (external call)", g - gasleft());
        assertEq(r, 0x3443dfaafb74638bf037cce7065ea2ee8a2b41d11046e4cd9cc0d808362cc134);
    }

    function test_rejects_wrongRound() public {
        for (uint256 i; i < 5; ++i) {
            Beacon memory b = beacons[i];
            vm.expectRevert(QuicknetBLS.InvalidSignature.selector);
            h.verify(b.round + 1, b.sig);
        }
    }

    function test_rejects_otherRoundsSignature() public {
        for (uint256 i; i < 5; ++i) {
            vm.expectRevert(QuicknetBLS.InvalidSignature.selector);
            h.verify(beacons[i].round, beacons[i + 1].sig);
        }
    }

    function test_rejects_negatedPoint() public {
        for (uint256 i; i < 5; ++i) {
            vm.expectRevert(QuicknetBLS.InvalidSignature.selector);
            h.verify(beacons[i].round, _negate(beacons[i].sig));
        }
    }

    function test_rejects_nonCanonicalY_cheaply() public {
        Beacon memory b = beacons[0];
        uint256 g = gasleft();
        vm.expectRevert(QuicknetBLS.BadSignatureEncoding.selector);
        h.verify(b.round, _addP(b.sig));
        assertLt(g - gasleft(), 50_000);
    }

    function test_rejects_hiWordTooLarge() public {
        Beacon memory b = beacons[0];
        uint256[4] memory s = b.sig;
        s[0] |= 1 << 128;
        vm.expectRevert(QuicknetBLS.BadSignatureEncoding.selector);
        h.verify(b.round, s);
        s = b.sig;
        s[2] |= 1 << 200;
        vm.expectRevert(QuicknetBLS.BadSignatureEncoding.selector);
        h.verify(b.round, s);
    }

    function test_rejects_xEqualsP() public {
        vm.expectRevert(QuicknetBLS.BadSignatureEncoding.selector);
        h.verify(1, [P_HI, P_LO, 0, 1]);
    }

    function test_rejects_infinity() public {
        vm.expectRevert(QuicknetBLS.InvalidSignature.selector);
        h.verify(1, [uint256(0), 0, 0, 0]);
    }

    function test_rejects_nonSubgroupPoint() public {
        // On-curve point x = 5 that is not in the G1 subgroup (spec Appendix C).
        uint256[4] memory s = [
            uint256(0),
            5,
            0x0d3c6da1211ebe797bc0790f1e6e7d66,
            0x9b180a8e59196825506d2bb2185f53715df092c8a7ceb64843ea7df67dbad60d
        ];
        vm.expectRevert(QuicknetBLS.InvalidSignature.selector);
        h.verify{gas: 2_000_000}(1, s);
    }

    function test_rejects_roundZero() public {
        vm.expectRevert(QuicknetBLS.BadSignatureEncoding.selector);
        h.verify(0, beacons[0].sig);
    }

    function test_tryVerify_neverReverts() public view {
        (bool ok, bytes32 r) = h.tryVerify(beacons[0].round + 1, beacons[0].sig);
        assertFalse(ok);
        assertEq(r, bytes32(0));
        (ok, r) = h.tryVerify(beacons[0].round, _addP(beacons[0].sig));
        assertFalse(ok);
        (ok, r) = h.tryVerify(beacons[0].round, beacons[0].sig);
        assertTrue(ok);
        assertEq(r, beacons[0].randomness);
    }

    /// @notice Random corruption of a valid signature never verifies.
    function testFuzz_corruptedSignatureFails(uint8 word, uint256 xorMask) public view {
        vm.assume(xorMask != 0);
        Beacon memory b = beacons[beacons.length - 1];
        uint256[4] memory s = b.sig;
        s[word % 4] ^= xorMask;
        (bool ok,) = h.tryVerify{gas: 3_000_000}(b.round, s);
        assertFalse(ok);
    }
}
