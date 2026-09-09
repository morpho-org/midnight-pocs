// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Offer} from "midnight/interfaces/IMidnight.sol";
import {WarehouseAccount} from "../src/WarehouseAccount.sol";
import {WarehouseForkBase} from "./WarehouseForkBase.sol";

/// @notice One complete warehouse story against deployed Midnight and Base USDC.
contract WarehouseLifecycleTest is WarehouseForkBase {
    function test_fullWarehouseLifecycle() public {
        // ------------------------------------------------------------ close and fund the warehouse
        (uint256 openingProceeds, uint256 junior) = _openWarehouse();

        assertEq(warehouse.juniorDeposited(), junior, "junior commitment not recorded");
        assertEq(warehouse.totalReceivables(), POOL_FACE, "receivables not held by SPV");
        assertEq(warehouse.collateralValue(), POOL_FACE, "collateral not valued at par");
        assertEq(warehouse.borrowingBase(), SENIOR_FACE, "advance rate not applied");
        assertEq(warehouse.seniorDebt(), SENIOR_FACE, "senior debt face is wrong");
        assertEq(warehouse.cashBalance(), 0, "purchase cash not swept");
        assertEq(USDC.balanceOf(originator), POOL_FACE, "originator not paid in full");
        assertEq(warehouse.equity(), uint256(POOL_FACE) - SENIOR_FACE, "junior cushion is wrong");
        assertEq(openingProceeds + junior, POOL_FACE, "sources do not equal uses");

        // ------------------------------------------------------------ season, settle, and replenish the pool
        // Ten days into the line, a $400k batch settles. Its 75% senior share pays debt down. The warehouse then
        // adds a $400k replacement batch, redraws $300k of senior face, and adds only the discount shortfall as
        // sponsor equity. Pool size and target leverage are restored rather than merely shrinking the facility.
        vm.warp(block.timestamp + 10 days);
        uint256 settled = 400_000e6;
        uint128 seniorPaydown = 300_000e6;

        deal(address(USDC), servicer, settled, true);
        vm.prank(servicer);
        USDC.approve(address(warehouse), settled);

        vm.prank(operator);
        warehouse.settleReceivables(market, servicer, settled, seniorPaydown, settled, servicer);
        receivable.burn(servicer, settled);

        _depositAndPledge(settled);

        deal(address(USDC), lender, USDC.balanceOf(lender) + 400_000e6, true);
        Offer memory replenishmentOffer = _offer(seniorPaydown, keccak256("replenishment draw"));
        bytes memory replenishmentRatifierData = _ratify(replenishmentOffer);
        uint256 replenishmentProceeds = _expectedProceeds(seniorPaydown);
        vm.prank(operator);
        warehouse.borrow(replenishmentOffer, replenishmentRatifierData, seniorPaydown, replenishmentProceeds);

        uint256 retainedEquityCash = settled - seniorPaydown;
        uint256 replacementJunior = settled - retainedEquityCash - replenishmentProceeds;
        _depositJunior(replacementJunior);
        vm.prank(operator);
        warehouse.fundOriginations(settled);

        assertEq(warehouse.totalReceivables(), POOL_FACE, "replenished pool balance is wrong");
        assertEq(warehouse.borrowingBase(), SENIOR_FACE, "target advance rate was not restored");
        assertEq(warehouse.seniorDebt(), SENIOR_FACE, "target senior leverage was not restored");
        assertEq(warehouse.cashBalance(), 0, "replenishment left idle cash");
        assertEq(USDC.balanceOf(originator), 1_400_000e6, "replacement origination not funded");
        assertFalse(warehouse.checkDeficiency(), "healthy replenished pool marked deficient");

        // ------------------------------------------------------------ day-21 takeout and senior-first waterfall
        // The pool sells for $900k, realizing a $100k loss. The takeout buyer receives the actual receivable token;
        // senior receives its full $750k face, leaving only $150k for sponsor equity.
        vm.warp(warehouse.availabilityEnd());
        vm.prank(stranger);
        warehouse.enterExpiredRunOff();
        assertEq(uint256(warehouse.state()), uint256(WarehouseAccount.State.RunOff), "run-off not entered");

        uint256 finalCollections = 900_000e6;
        deal(address(USDC), takeout, finalCollections, true);
        vm.prank(takeout);
        USDC.approve(address(warehouse), finalCollections);

        vm.prank(operator);
        warehouse.settleReceivables(market, takeout, finalCollections, SENIOR_FACE, POOL_FACE, takeout);

        // The lender withdraws both funded senior batches from Midnight. It earns the discounts between its cash
        // advances and their face; no warehouse accounting entry manufactures that return.
        uint256 lenderBeforeWithdraw = USDC.balanceOf(lender);
        uint256 totalSeniorFunded = uint256(SENIOR_FACE) + seniorPaydown;
        vm.prank(lender);
        MIDNIGHT.withdraw(market, totalSeniorFunded, lender, lender);
        assertEq(USDC.balanceOf(lender) - lenderBeforeWithdraw, totalSeniorFunded, "senior face not returned");

        uint256 juniorResidual = finalCollections - uint256(SENIOR_FACE);
        vm.prank(sponsor);
        warehouse.withdrawJuniorResidual(juniorResidual, sponsor);

        assertEq(warehouse.seniorDebt(), 0, "senior not fully repaid");
        assertFalse(warehouse.hasUnacknowledgedSeniorLoss(), "senior loss remains after repayment");
        assertEq(warehouse.totalReceivables(), 0, "receivables remain after settlement");
        assertEq(receivable.balanceOf(takeout), POOL_FACE, "takeout did not receive the pool");
        assertEq(warehouse.cashBalance(), 0, "cash remains after waterfall");
        assertEq(USDC.balanceOf(sponsor), juniorResidual, "junior did not receive residual");
        assertLt(juniorResidual, junior + replacementJunior, "sponsor did not absorb the portfolio loss");
    }
}
