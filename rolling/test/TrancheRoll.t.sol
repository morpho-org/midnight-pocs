// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Offer} from "midnight/interfaces/IMidnight.sol";
import {TickLib} from "midnight/libraries/TickLib.sol";
import {DirectRollBase} from "./helpers/DirectRollBase.sol";

contract TrancheRollTest is DirectRollBase {
    uint256 internal constant TRANCHE_COUNT = 10;
    uint128 internal constant TRANCHE_UNITS = 100_000e6;
    uint256 internal constant TRANCHE_COLLATERAL = COLLATERAL / TRANCHE_COUNT;

    function test_tenTranchesRecycleOneTenthAdvance() public {
        bytes32 oldId = MIDNIGHT.touchMarket(_market(firstMaturity));
        uint256 newMaturity = firstMaturity + 1 days;
        bytes32 newId = MIDNIGHT.touchMarket(_market(newMaturity));

        uint256 trancheAdvance = uint256(TRANCHE_UNITS) * TickLib.tickToPrice(tick) / WAD;
        uint256 trancheCost = uint256(TRANCHE_UNITS) - trancheAdvance;

        // Only one tenth of the next advance remains idle after the opening loan.
        deal(address(USDC), lender, trancheAdvance, true);
        _fundReserve(TRANCHE_COUNT * trancheCost);

        Offer memory nextOffer = _offer(newMaturity, tick, lender);
        bytes memory ratifierData = _ratifyEoa(nextOffer, lender);
        vm.warp(firstMaturity - 1 hours);

        for (uint256 i; i < TRANCHE_COUNT; ++i) {
            vm.prank(borrowerOperator);
            borrower.roll(
                nextOffer, ratifierData, TRANCHE_UNITS, _market(firstMaturity), TRANCHE_UNITS, TRANCHE_COLLATERAL
            );

            vm.prank(lender);
            MIDNIGHT.withdraw(_market(firstMaturity), TRANCHE_UNITS, lender, lender);

            uint256 rolledUnits = (i + 1) * uint256(TRANCHE_UNITS);
            assertEq(MIDNIGHT.debt(oldId, address(borrower)), uint256(FACE) - rolledUnits, "old debt is wrong");
            assertEq(MIDNIGHT.debt(newId, address(borrower)), rolledUnits, "new debt is wrong");
            assertEq(MIDNIGHT.credit(oldId, lender), uint256(FACE) - rolledUnits, "old credit is wrong");
            assertEq(MIDNIGHT.credit(newId, lender), rolledUnits, "new credit is wrong");
            assertEq(
                USDC.balanceOf(lender), trancheAdvance + (i + 1) * trancheCost, "tranche liquidity did not recycle"
            );
        }

        assertEq(MIDNIGHT.collateral(oldId, address(borrower), 0), 0, "old collateral remains");
        assertEq(MIDNIGHT.collateral(newId, address(borrower), 0), COLLATERAL, "new collateral is wrong");
        assertEq(USDC.balanceOf(address(borrower)), 0, "carry reserve did not pay the roll cost");

        // Complete the lifecycle: repay the final maturity, recover principal and return collateral.
        deal(address(USDC), address(borrower), FACE, true);
        vm.prank(borrowerOperator);
        borrower.repay(_market(newMaturity), FACE);

        vm.prank(lender);
        MIDNIGHT.withdraw(_market(newMaturity), FACE, lender, lender);

        vm.prank(borrowerOperator);
        borrower.withdrawCollateral(_market(newMaturity), COLLATERAL, borrowerOperator);

        assertEq(MIDNIGHT.debt(newId, address(borrower)), 0, "final debt remains");
        assertEq(MIDNIGHT.credit(newId, lender), 0, "final credit remains");
        assertEq(MIDNIGHT.collateral(newId, address(borrower), 0), 0, "final collateral remains");
        assertEq(collateral.balanceOf(borrowerOperator), COLLATERAL, "collateral was not returned");
    }
}
