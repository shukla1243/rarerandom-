// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRareRandom} from "../interfaces/IRareRandom.sol";
import {RareRandomConsumer} from "./RareRandomConsumer.sol";

/// @notice Example: a coin flip with a cheap store-only callback and a permissionless settle from the pull view.
contract CoinFlip is RareRandomConsumer {
    uint32 public constant CALLBACK_GAS = 60_000;

    struct Flip {
        address player;
        bool guessHeads;
        bool settled;
        bool won;
    }

    mapping(uint256 requestId => Flip) public flips;

    event FlipRequested(uint256 indexed requestId, address indexed player, bool guessHeads);
    event FlipSettled(uint256 indexed requestId, address indexed player, bool won);

    error NotReady();
    error AlreadySettled();

    constructor(IRareRandom core) RareRandomConsumer(core) {}

    function quote() external view returns (uint256) {
        return RARE_RANDOM.getFee(1, CALLBACK_GAS);
    }

    function flip(bool guessHeads) external payable returns (uint256 requestId) {
        uint256 fee = RARE_RANDOM.getFee(1, CALLBACK_GAS);
        requestId = RARE_RANDOM.request{value: fee}(
            1, CALLBACK_GAS, keccak256(abi.encode(msg.sender, guessHeads, block.number))
        );
        flips[requestId] = Flip({player: msg.sender, guessHeads: guessHeads, settled: false, won: false});
        emit FlipRequested(requestId, msg.sender, guessHeads);
        if (msg.value > fee) {
            (bool ok,) = msg.sender.call{value: msg.value - fee}("");
            require(ok, "refund failed");
        }
    }

    function _onRandomWords(uint256 requestId, uint256[] calldata words) internal override {
        _settle(requestId, words[0]);
    }

    /// @notice Anyone can settle from the pull view if the callback failed or was never run.
    function settle(uint256 requestId) external {
        (bool ready, uint256 word) = RARE_RANDOM.randomWord(requestId, 0);
        if (!ready) revert NotReady();
        _settle(requestId, word);
    }

    function _settle(uint256 requestId, uint256 word) internal {
        Flip storage f = flips[requestId];
        if (f.settled) revert AlreadySettled();
        f.settled = true;
        f.won = ((word & 1) == 1) == f.guessHeads;
        emit FlipSettled(requestId, f.player, f.won);
    }
}
