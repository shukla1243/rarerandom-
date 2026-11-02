// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/// @title QuicknetBLS
/// @notice Verification-only library for drand quicknet beacons (scheme `bls-unchained-g1-rfc9380`).
/// @dev Signatures are G1 points in EIP-2537 layout `[x_hi, x_lo, y_hi, y_lo]` (hi words hold the top 16 bytes of
///      each 48-byte coordinate). Verification uses the EIP-2537 precompiles 0x0b (G1ADD), 0x0f (PAIRING) and
///      0x10 (MAP_FP_TO_G1), plus SHA-256 (0x02) and MODEXP (0x05). Every precompile call checks the exact
///      return size, so on a chain without EIP-2537 (empty output) verification fails closed.
///      Gas is always forwarded in full: an invalid point burns the gas given to the precompile, and that cost
///      falls on whoever submitted it.
library QuicknetBLS {
    error InvalidSignature();
    error BadSignatureEncoding();

    // drand quicknet
    bytes32 internal constant CHAIN_HASH = 0x52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971;
    uint256 internal constant GENESIS_TIME = 1692803367;
    uint256 internal constant PERIOD = 3;

    // BLS12-381 base field modulus p, split into the top 16 bytes and the low 32 bytes.
    uint256 internal constant P_HI = 0x1a0111ea397fe69a4b1ba7b6434bacd7;
    uint256 internal constant P_LO = 0x64774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab;
    // (p - 1) / 2, for the compressed encoding's sort bit.
    uint256 internal constant HALF_HI = 0x0d0088f51cbff34d258dd3db21a5d66b;
    uint256 internal constant HALF_LO = 0xb23ba5c279c2895fb39869507b587b120f55ffff58a9ffffdcff7fffffffd555;

    // DST = "BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_NUL_" (43 bytes). DST' = DST || 0x2b (RFC 9380 §5.3.1).
    bytes32 internal constant DST_HEAD = 0x424c535f5349475f424c53313233383147315f584d443a5348412d3235365f53;
    bytes12 internal constant DST_TAIL_PRIME = 0x5357555f524f5f4e554c5f2b;

    // quicknet group public key in G2, EIP-2537 order (x.c0, x.c1, y.c0, y.c1), each 64 bytes left padded.
    uint256 internal constant PK_X0_HI = 0x0d1fec758c921cc22b0e17e63aaf4bcb;
    uint256 internal constant PK_X0_LO = 0x5ed66304de9cf809bd274ca73bab4af5a6e9c76a4bc09e76eae8991ef5ece45a;
    uint256 internal constant PK_X1_HI = 0x03cf0f2896adee7eb8b5f01fcad39122;
    uint256 internal constant PK_X1_LO = 0x12c437e0073e911fb90022d3e760183c8c4b450b6a0a6c3ac6a5776a2d106451;
    uint256 internal constant PK_Y0_HI = 0x0e5db2b6bfbb01c867749cadffca88b3;
    uint256 internal constant PK_Y0_LO = 0x6c24f3012ba09fc4d3022c5c37dce0f977d3adb5d183c7477c442b1f04515273;
    uint256 internal constant PK_Y1_HI = 0x01a714f2edb74119a2f2b0d5a7c75ba9;
    uint256 internal constant PK_Y1_LO = 0x02d163700a61bc224ededd8e63aef7be1aaf8e93d7a9718b047ccddb3eb5d68b;

    // -G2 generator, same layout.
    uint256 internal constant NG2_X0_HI = 0x024aa2b2f08f0a91260805272dc51051;
    uint256 internal constant NG2_X0_LO = 0xc6e47ad4fa403b02b4510b647ae3d1770bac0326a805bbefd48056c8c121bdb8;
    uint256 internal constant NG2_X1_HI = 0x13e02b6052719f607dacd3a088274f65;
    uint256 internal constant NG2_X1_LO = 0x596bd0d09920b61ab5da61bbdc7f5049334cf11213945d57e5ac7d055d042b7e;
    uint256 internal constant NG2_Y0_HI = 0x0d1b3cc2c7027888be51d9ef691d77bc;
    uint256 internal constant NG2_Y0_LO = 0xb679afda66c73f17f9ee3837a55024f78c71363275a75d75d86bab79f74782aa;
    uint256 internal constant NG2_Y1_HI = 0x13fa4d4a0ad8b1ce186ed5061789213d;
    uint256 internal constant NG2_Y1_LO = 0x993923066dddaf1040bc3ff59f825c78df74f2d75467e25e0f55f8a00fa030ed;

    // Round 1 known answer, used by selfTest().
    uint256 internal constant R1_X_HI = 0x155e7cb2d5c613ee0b2e28d6750aabbb;
    uint256 internal constant R1_X_LO = 0x78c39dcc96bd9d38c2c2e12198df95571de8e8e402a0cc48871c7089a2b3af4b;
    uint256 internal constant R1_Y_HI = 0x0fbb74ee8788264320f2501b0fa0dd56;
    uint256 internal constant R1_Y_LO = 0x363bcec5ce4b113b2bf1de6e331116c79191af99234824f03aeb10ab1c4c7771;
    uint256 internal constant R1_NEG_Y_HI = 0x0a459cfbb1f7c0572a29579b33aacf81;
    uint256 internal constant R1_NEG_Y_LO = 0x2e3b7cbf253a01843b3ef432c39fdf5c8d1a50658e0bdb0f7f13ef54e3b3333a;
    bytes32 internal constant R1_RANDOMNESS = 0x1466a6cd24e327188770752f6134001c64d6efcc590ccc26b721611ad96f165a;

    uint8 private constant OK = 0;
    uint8 private constant BAD_ENCODING = 1;
    uint8 private constant BAD_SIGNATURE = 2;

    /// @notice Verifies `signature` for `round` and returns drand's randomness (sha256 of the compressed signature).
    /// @dev Reverts `BadSignatureEncoding` on non-canonical input and `InvalidSignature` if the pairing fails.
    function verify(uint64 round, uint256[4] memory signature) internal view returns (bytes32 randomness) {
        uint8 code;
        (code, randomness) = _verify(round, signature);
        if (code == BAD_ENCODING) revert BadSignatureEncoding();
        if (code != OK) revert InvalidSignature();
    }

    /// @notice Like `verify`, but returns `(false, 0)` instead of reverting.
    function tryVerify(uint64 round, uint256[4] memory signature) internal view returns (bool ok, bytes32 randomness) {
        uint8 code;
        (code, randomness) = _verify(round, signature);
        ok = code == OK;
        if (!ok) randomness = bytes32(0);
    }

    /// @notice True iff round 1 verifies to its known randomness and the negated round-1 signature fails.
    /// @dev False on any chain without working EIP-2537 precompiles.
    function selfTest() internal view returns (bool) {
        (bool ok, bytes32 r) = tryVerify(1, [R1_X_HI, R1_X_LO, R1_Y_HI, R1_Y_LO]);
        if (!ok || r != R1_RANDOMNESS) return false;
        (bool negOk,) = tryVerify(1, [R1_X_HI, R1_X_LO, R1_NEG_Y_HI, R1_NEG_Y_LO]);
        return !negOk;
    }

    function _verify(uint64 round, uint256[4] memory s) private view returns (uint8, bytes32) {
        // 1. Cheap canonical-encoding checks before any precompile can burn gas.
        if (round == 0) return (BAD_ENCODING, 0);
        if (s[0] >> 128 != 0 || s[2] >> 128 != 0) return (BAD_ENCODING, 0);
        if (!_lessThanP(s[0], s[1]) || !_lessThanP(s[2], s[3])) return (BAD_ENCODING, 0);

        // 2-5. H(m) = hash_to_curve(sha256(uint64_be(round))).
        (bool hOk, bytes memory hm) = _hashToG1(sha256(abi.encodePacked(round)));
        if (!hOk) return (BAD_SIGNATURE, 0);

        // 6. e(S, -G2) * e(H(m), PK) == 1
        bytes memory input = abi.encodePacked(abi.encodePacked(s[0], s[1], s[2], s[3]), _negG2(), hm, _publicKey());
        (bool pOk, bytes memory out) = _precompile(address(0x0f), input, 32);
        if (!pOk || abi.decode(out, (uint256)) != 1) return (BAD_SIGNATURE, 0);

        // 7. Rebuild the 48-byte compressed signature and hash it: drand's published randomness.
        uint256 flags = 0x80;
        if (s[2] > HALF_HI || (s[2] == HALF_HI && s[3] > HALF_LO)) flags |= 0x20;
        bytes16 xHi = bytes16(uint128(s[0] | (flags << 120)));
        return (OK, sha256(abi.encodePacked(xHi, s[1])));
    }

    function _negG2() private pure returns (bytes memory) {
        return abi.encodePacked(NG2_X0_HI, NG2_X0_LO, NG2_X1_HI, NG2_X1_LO, NG2_Y0_HI, NG2_Y0_LO, NG2_Y1_HI, NG2_Y1_LO);
    }

    function _publicKey() private pure returns (bytes memory) {
        return abi.encodePacked(PK_X0_HI, PK_X0_LO, PK_X1_HI, PK_X1_LO, PK_Y0_HI, PK_Y0_LO, PK_Y1_HI, PK_Y1_LO);
    }

    function _lessThanP(uint256 hi, uint256 lo) private pure returns (bool) {
        return hi < P_HI || (hi == P_HI && lo < P_LO);
    }

    /// @dev RFC 9380 hash_to_curve for G1 with expand_message_xmd(SHA-256), len_in_bytes = 128.
    function _hashToG1(bytes32 message) private view returns (bool, bytes memory) {
        bytes32 b0 =
            sha256(abi.encodePacked(bytes32(0), bytes32(0), message, uint16(128), uint8(0), DST_HEAD, DST_TAIL_PRIME));
        bytes32 b1 = sha256(abi.encodePacked(b0, uint8(1), DST_HEAD, DST_TAIL_PRIME));
        bytes32 b2 = sha256(abi.encodePacked(b0 ^ b1, uint8(2), DST_HEAD, DST_TAIL_PRIME));
        bytes32 b3 = sha256(abi.encodePacked(b0 ^ b2, uint8(3), DST_HEAD, DST_TAIL_PRIME));
        bytes32 b4 = sha256(abi.encodePacked(b0 ^ b3, uint8(4), DST_HEAD, DST_TAIL_PRIME));

        (bool ok0, bytes memory u0) = _modP(b1, b2);
        (bool ok1, bytes memory u1) = _modP(b3, b4);
        if (!ok0 || !ok1) return (false, "");
        (bool m0, bytes memory q0) = _precompile(address(0x10), u0, 128);
        (bool m1, bytes memory q1) = _precompile(address(0x10), u1, 128);
        if (!m0 || !m1) return (false, "");
        // MAP_FP_TO_G1 already clears the cofactor, so H(m) = Q0 + Q1.
        return _precompile(address(0x0b), abi.encodePacked(q0, q1), 128);
    }

    /// @dev OS2IP(hi || lo) mod p through MODEXP with exponent 1. Output is 64 bytes, the EIP-2537 Fp layout.
    function _modP(bytes32 hi, bytes32 lo) private view returns (bool, bytes memory) {
        return _precompile(
            address(0x05), abi.encodePacked(uint256(64), uint256(1), uint256(64), hi, lo, uint8(1), P_HI, P_LO), 64
        );
    }

    /// @dev Static call that succeeds only if the precompile returns exactly `outLen` bytes. `staticcall` is the
    ///      last argument so it runs before `returndatasize()` is read (Yul evaluates right to left).
    function _precompile(address target, bytes memory input, uint256 outLen)
        private
        view
        returns (bool ok, bytes memory out)
    {
        out = new bytes(outLen);
        assembly ("memory-safe") {
            ok := and(
                eq(returndatasize(), outLen),
                staticcall(gas(), target, add(input, 0x20), mload(input), add(out, 0x20), outLen)
            )
        }
    }
}
