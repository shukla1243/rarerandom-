// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRareRandom, IRareRandomConsumer} from "../interfaces/IRareRandom.sol";

/// @notice Base for contracts that receive RareRandom callbacks. Checks the caller and forwards to `_onRandomWords`.
/// @dev Keep `_onRandomWords` cheap and non-reverting (store the words, settle later). A failed callback never loses
///      the words: they stay readable through `core.randomWords(id)` and anyone can call `core.retryCallback(id)`.
abstract contract RareRandomConsumer is IRareRandomConsumer {
    error OnlyRareRandom();

    IRareRandom public immutable RARE_RANDOM;

    constructor(IRareRandom core) {
        RARE_RANDOM = core;
    }

    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata words) external {
        if (msg.sender != address(RARE_RANDOM)) revert OnlyRareRandom();
        _onRandomWords(requestId, words);
    }

    /// @dev Requests `numWords` with a callback, paying the exact quote. Excess ETH would be credited to this contract.
    function _requestRandom(uint32 numWords, uint32 callbackGasLimit, bytes32 seed) internal returns (uint256) {
        uint256 fee = RARE_RANDOM.getFee(numWords, callbackGasLimit);
        return RARE_RANDOM.request{value: fee}(numWords, callbackGasLimit, seed);
    }

    function _onRandomWords(uint256 requestId, uint256[] calldata words) internal virtual;
}
