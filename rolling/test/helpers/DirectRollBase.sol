// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Offer} from "midnight/interfaces/IMidnight.sol";
import {RollingForkBase} from "../RollingForkBase.sol";

abstract contract DirectRollBase is RollingForkBase {
    address internal lender = makeAddr("directLender");
    uint256 internal firstMaturity;
    uint256 internal tick;
    uint256 internal advance;
    uint256 internal dailyCost;

    function setUp() public virtual {
        _fork();
        _deployBorrower();
        firstMaturity = block.timestamp + 1 days;
        _configure(lender, firstMaturity);

        tick = _tick();
        advance = _advance(tick);
        dailyCost = uint256(FACE) - advance;
        assertEq(MIDNIGHT.settlementFee(MIDNIGHT.touchMarket(_market(firstMaturity)), 1 days), 0);

        // Opening advance plus one full new advance: the direct design needs almost the whole face idle.
        deal(address(USDC), lender, 2 * advance, true);
        vm.prank(lender);
        USDC.approve(address(MIDNIGHT), type(uint256).max);

        Offer memory openingOffer = _offer(firstMaturity, tick, lender);
        bytes memory ratifierData = _ratifyEoa(openingOffer, lender);
        vm.prank(borrowerOperator);
        borrower.open(openingOffer, ratifierData, FACE, useOfProceeds);

        assertEq(USDC.balanceOf(useOfProceeds), advance, "opening proceeds are wrong");
        assertEq(USDC.balanceOf(lender), advance, "idle advance is wrong");
    }
}
