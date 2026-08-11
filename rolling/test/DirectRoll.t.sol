// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Offer} from "midnight/interfaces/IMidnight.sol";
import {DirectRollBase} from "./helpers/DirectRollBase.sol";

contract DirectRollTest is DirectRollBase {
    function test_fullFaceDirectRollNeedsOneIdleAdvance() public {
        bytes32 oldId = MIDNIGHT.touchMarket(_market(firstMaturity));
        uint256 newMaturity = firstMaturity + 1 days;
        bytes32 newId = MIDNIGHT.touchMarket(_market(newMaturity));
        _fundReserve(dailyCost);

        Offer memory nextOffer = _offer(newMaturity, tick, lender);
        bytes memory ratifierData = _ratifyEoa(nextOffer, lender);

        vm.warp(firstMaturity - 1 hours);
        vm.prank(borrowerOperator);
        borrower.roll(nextOffer, ratifierData, FACE, _market(firstMaturity), FACE, COLLATERAL);

        vm.prank(lender);
        MIDNIGHT.withdraw(_market(firstMaturity), FACE, lender, lender);

        assertEq(MIDNIGHT.debt(oldId, address(borrower)), 0, "old debt remains");
        assertEq(MIDNIGHT.debt(newId, address(borrower)), FACE, "new debt is wrong");
        assertEq(MIDNIGHT.collateral(oldId, address(borrower), 0), 0, "old collateral remains");
        assertEq(MIDNIGHT.collateral(newId, address(borrower), 0), COLLATERAL, "new collateral is wrong");
        assertEq(USDC.balanceOf(address(borrower)), 0, "carry reserve did not pay the roll cost");
        assertEq(USDC.balanceOf(lender), FACE, "old lender credit was not released");
    }
}
