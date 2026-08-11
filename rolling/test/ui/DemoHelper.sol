// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Market, Offer} from "midnight/interfaces/IMidnight.sol";
import {IdLib} from "midnight/libraries/IdLib.sol";
import {TickLib} from "midnight/libraries/TickLib.sol";
import {HashLib} from "midnight/ratifiers/libraries/HashLib.sol";

/// @notice Demo-only wrapper around Midnight's internal market and offer math.
contract DemoHelper {
    function priceToTick(uint256 price, uint256 spacing) external pure returns (uint256) {
        return TickLib.priceToTick(price, spacing);
    }

    function tickToPrice(uint256 tick) external pure returns (uint256) {
        return TickLib.tickToPrice(tick);
    }

    function hashOffer(Offer memory offer) external pure returns (bytes32) {
        return HashLib.hashOffer(offer);
    }

    function toId(Market memory market) external pure returns (bytes32) {
        return IdLib.toId(market);
    }
}
