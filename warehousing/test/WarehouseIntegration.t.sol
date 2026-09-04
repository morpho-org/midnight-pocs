// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Offer} from "midnight/interfaces/IMidnight.sol";
import {WarehouseAccount} from "../src/WarehouseAccount.sol";
import {WarehouseForkBase} from "./WarehouseForkBase.sol";

contract WarehouseIntegrationTest is WarehouseForkBase {
    function test_drawCannotExceedBorrowingBase() public {
        _fundLender(1_000_000e6);
        _depositJunior(300_000e6);
        _depositAndPledge(POOL_FACE);

        uint128 excessiveFace = SENIOR_FACE + 1;
        Offer memory offer = _offer(excessiveFace, keccak256("excessive draw"));
        bytes memory ratifierData = _ratify(offer);

        vm.expectRevert(
            abi.encodeWithSelector(
                WarehouseAccount.BorrowingBaseExceeded.selector, uint256(excessiveFace), uint256(SENIOR_FACE)
            )
        );
        vm.prank(operator);
        warehouse.borrow(offer, ratifierData, excessiveFace);

        assertEq(warehouse.seniorDebt(), 0, "reverted draw left debt");
        assertEq(warehouse.cashBalance(), 300_000e6, "reverted draw moved cash");
    }

    function test_impairmentFreezesDrawsAndSweepsUntilSeniorPaydownCuresIt() public {
        _openWarehouse();

        // A 10% mark lowers the 75% borrowing base from $750k to $675k. Midnight's 96.5% liquidation
        // threshold remains above the debt, showing the warehouse covenant is independently stricter.
        vm.prank(administrator);
        oracle.setPrice(0.9e36);
        assertTrue(warehouse.checkDeficiency(), "impairment did not breach borrowing base");
        assertTrue(MIDNIGHT.isHealthy(market, marketId, address(warehouse)), "position unexpectedly liquidatable");

        _depositJunior(75_000e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                WarehouseAccount.BorrowingBaseExceeded.selector, uint256(SENIOR_FACE), uint256(675_000e6)
            )
        );
        vm.prank(operator);
        warehouse.sweepCash(1);

        warehouse.flagDeficiency();
        assertEq(uint256(warehouse.state()), uint256(WarehouseAccount.State.Deficiency));

        Offer memory blockedOffer = _offer(1, keccak256("blocked draw"));
        vm.expectRevert(WarehouseAccount.InvalidState.selector);
        vm.prank(operator);
        warehouse.borrow(blockedOffer, "", 1);

        vm.prank(operator);
        warehouse.repaySenior(market, 75_000e6);
        assertFalse(warehouse.checkDeficiency(), "senior paydown did not cure economics");

        vm.prank(operator);
        warehouse.cureDeficiency();
        assertEq(uint256(warehouse.state()), uint256(WarehouseAccount.State.Active));
    }

    function test_receivablesCannotLeaveIfRemainingPoolWouldUndersecureSenior() public {
        _openWarehouse();

        vm.expectRevert(
            abi.encodeWithSelector(
                WarehouseAccount.BorrowingBaseExceeded.selector, uint256(SENIOR_FACE), uint256(SENIOR_FACE) - 1
            )
        );
        vm.prank(operator);
        warehouse.releaseReceivables(market, 1, originator);

        assertEq(warehouse.totalReceivables(), POOL_FACE, "reverted release moved collateral");
        assertEq(MIDNIGHT.collateral(marketId, address(warehouse), 0), POOL_FACE, "pledge changed on revert");
    }

    function test_runOffIsOneWayAndSeniorAlwaysRanksAheadOfJunior() public {
        _openWarehouse();

        vm.prank(operator);
        warehouse.enterRunOff();

        vm.expectRevert(WarehouseAccount.InvalidState.selector);
        vm.prank(operator);
        warehouse.sweepCash(1);

        vm.expectRevert(WarehouseAccount.InvalidState.selector);
        vm.prank(operator);
        warehouse.depositReceivables(1);

        _depositJunior(1);
        vm.expectRevert(WarehouseAccount.SeniorOutstanding.selector);
        vm.prank(sponsor);
        warehouse.withdrawJuniorResidual(1, sponsor);

        vm.expectRevert(WarehouseAccount.InvalidState.selector);
        vm.prank(operator);
        warehouse.enterRunOff();
    }

    function test_registryCanHaltNewMoneyWithoutBlockingSeniorRunOff() public {
        _openWarehouse();

        vm.prank(administrator);
        registry.setAsset(address(receivable), address(oracle), ADVANCE_RATE_BPS, false);
        assertEq(warehouse.borrowingBase(), 0, "ineligible collateral retained borrowing capacity");
        assertTrue(warehouse.checkDeficiency(), "ineligible collateral did not freeze facility");
        warehouse.flagDeficiency();

        deal(address(USDC), takeout, SENIOR_FACE, true);
        vm.startPrank(takeout);
        USDC.approve(address(warehouse), SENIOR_FACE);
        warehouse.depositCollection(SENIOR_FACE);
        vm.stopPrank();

        vm.startPrank(operator);
        warehouse.repaySenior(market, SENIOR_FACE);
        warehouse.enterRunOff();
        warehouse.releaseReceivables(market, POOL_FACE, address(this));
        vm.stopPrank();

        assertEq(warehouse.seniorDebt(), 0, "asset removal trapped senior debt");
        assertEq(warehouse.totalReceivables(), 0, "asset removal trapped collateral");
    }

    function test_onlyNamedPartiesCanMoveWarehouseAssets() public {
        _depositJunior(100e6);
        _depositAndPledge(100e6);

        vm.expectRevert(WarehouseAccount.OnlyJuniorProvider.selector);
        vm.prank(stranger);
        warehouse.juniorDeposit(1);

        vm.expectRevert(WarehouseAccount.OnlyOperator.selector);
        vm.prank(stranger);
        warehouse.sweepCash(1);

        vm.expectRevert(WarehouseAccount.OnlyOperator.selector);
        vm.prank(stranger);
        warehouse.releaseReceivables(market, 1, stranger);

        assertEq(warehouse.cashBalance(), 100e6, "unauthorized call moved junior cash");
        assertEq(warehouse.totalReceivables(), 100e6, "unauthorized call moved receivables");
    }
}
