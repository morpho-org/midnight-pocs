// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

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

        // ------------------------------------------------------------ partial collection and recycling
        // A $400k receivable settles. Its 75% senior share pays debt down, and the $100k equity share funds
        // a replacement receivable. Senior face and the borrowing base both fall by $300k.
        uint256 settled = 400_000e6;
        uint256 seniorPaydown = 300_000e6;
        uint256 recycled = 100_000e6;

        deal(address(USDC), takeout, settled, true);
        vm.startPrank(takeout);
        USDC.approve(address(warehouse), settled);
        warehouse.depositCollection(settled);
        vm.stopPrank();

        vm.startPrank(operator);
        warehouse.repaySenior(market, seniorPaydown);
        warehouse.releaseReceivables(market, settled, address(this));
        vm.stopPrank();
        receivable.burn(address(this), settled);

        _depositAndPledge(recycled);
        vm.prank(operator);
        warehouse.sweepCash(recycled);

        assertEq(warehouse.totalReceivables(), 700_000e6, "recycled pool balance is wrong");
        assertEq(warehouse.borrowingBase(), 525_000e6, "recycled borrowing base is wrong");
        assertEq(warehouse.seniorDebt(), 450_000e6, "partial senior paydown is wrong");
        assertEq(warehouse.cashBalance(), 0, "recycling left idle cash");
        assertEq(USDC.balanceOf(originator), 1_100_000e6, "replacement origination not funded");
        assertFalse(warehouse.checkDeficiency(), "healthy recycled pool marked deficient");

        // ------------------------------------------------------------ run-off and senior-first waterfall
        vm.prank(operator);
        warehouse.enterRunOff();
        assertEq(uint256(warehouse.state()), uint256(WarehouseAccount.State.RunOff), "run-off not entered");

        uint256 remainingReceivables = 700_000e6;
        uint256 finalCollections = 770_000e6; // par plus a $70k portfolio gain
        deal(address(USDC), takeout, finalCollections, true);
        vm.startPrank(takeout);
        USDC.approve(address(warehouse), finalCollections);
        warehouse.depositCollection(finalCollections);
        vm.stopPrank();

        vm.startPrank(operator);
        warehouse.repaySenior(market, 450_000e6);
        warehouse.releaseReceivables(market, remainingReceivables, address(this));
        vm.stopPrank();
        receivable.burn(address(this), remainingReceivables);

        // The lender withdraws the repaid face from Midnight. It earns the discount between its opening cash
        // advance and the $750k face; no warehouse accounting entry manufactures that return.
        uint256 lenderBeforeWithdraw = USDC.balanceOf(lender);
        vm.prank(lender);
        MIDNIGHT.withdraw(market, SENIOR_FACE, lender, lender);
        assertEq(USDC.balanceOf(lender) - lenderBeforeWithdraw, SENIOR_FACE, "senior face not returned");

        uint256 juniorResidual = finalCollections - 450_000e6;
        vm.prank(sponsor);
        warehouse.withdrawJuniorResidual(juniorResidual, sponsor);

        assertEq(warehouse.seniorDebt(), 0, "senior not fully repaid");
        assertEq(warehouse.totalReceivables(), 0, "receivables remain after settlement");
        assertEq(warehouse.cashBalance(), 0, "cash remains after waterfall");
        assertEq(USDC.balanceOf(sponsor), juniorResidual, "junior did not receive residual");
        assertGt(juniorResidual, junior, "junior did not receive the portfolio upside");
        assertGt(USDC.balanceOf(lender), uint256(SENIOR_FACE) + 100_000e6, "senior carry not realized");
    }
}
