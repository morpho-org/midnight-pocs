// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IMidnight, Offer} from "midnight/interfaces/IMidnight.sol";
import {AssetRegistry} from "../src/AssetRegistry.sol";
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
        warehouse.borrow(offer, ratifierData, excessiveFace, 0);

        assertEq(warehouse.seniorDebt(), 0, "reverted draw left debt");
        assertEq(warehouse.cashBalance(), 300_000e6, "reverted draw moved cash");
    }

    function test_drawCannotExceedSeniorCommitment() public {
        uint128 oversizedPool = 2_000_000e6;
        uint128 excessiveFace = SENIOR_COMMITMENT + 1;
        _fundLender(excessiveFace);
        _depositAndPledge(oversizedPool);

        Offer memory offer = _offer(excessiveFace, keccak256("excessive commitment draw"));
        bytes memory ratifierData = _ratify(offer);

        vm.expectRevert(
            abi.encodeWithSelector(
                WarehouseAccount.SeniorCommitmentExceeded.selector, uint256(excessiveFace), uint256(SENIOR_COMMITMENT)
            )
        );
        vm.prank(operator);
        warehouse.borrow(offer, ratifierData, excessiveFace, 0);
    }

    function test_drawCannotSettleBelowMinimumProceeds() public {
        _fundLender(1_000_000e6);
        _depositJunior(300_000e6);
        _depositAndPledge(POOL_FACE);

        Offer memory offer = _offer(SENIOR_FACE, keccak256("minimum proceeds"));
        bytes memory ratifierData = _ratify(offer);
        uint256 proceeds = _expectedProceeds(SENIOR_FACE);

        vm.expectRevert(abi.encodeWithSelector(WarehouseAccount.InsufficientProceeds.selector, proceeds, proceeds + 1));
        vm.prank(operator);
        warehouse.borrow(offer, ratifierData, SENIOR_FACE, proceeds + 1);

        assertEq(warehouse.seniorDebt(), 0, "slipped draw left debt");
    }

    function test_impairmentFreezesNewMoneyAndSweepsCashToSeniorUntilCured() public {
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
        warehouse.fundOriginations(1);

        warehouse.flagDeficiency();
        assertEq(uint256(warehouse.state()), uint256(WarehouseAccount.State.Deficiency));

        Offer memory blockedOffer = _offer(1, keccak256("blocked draw"));
        vm.expectRevert(WarehouseAccount.InvalidState.selector);
        vm.prank(operator);
        warehouse.borrow(blockedOffer, "", 1, 0);

        vm.prank(stranger); // permissionless once cash is trapped
        uint256 swept = warehouse.sweepCollectionsToSenior(market);
        assertEq(swept, 75_000e6, "cash sweep did not repay all available cash");
        assertEq(warehouse.cashBalance(), 0, "cash was not fully trapped and swept");
        assertFalse(warehouse.checkDeficiency(), "senior paydown did not cure economics");

        vm.prank(operator);
        warehouse.cureDeficiency();
        assertEq(uint256(warehouse.state()), uint256(WarehouseAccount.State.Active));
    }

    function test_receivablesCannotLeaveIfRemainingPoolWouldUndersecureSenior() public {
        _openWarehouse();
        deal(address(USDC), takeout, 1, true);
        vm.prank(takeout);
        USDC.approve(address(warehouse), 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                WarehouseAccount.BorrowingBaseExceeded.selector, uint256(SENIOR_FACE), uint256(SENIOR_FACE) - 1
            )
        );
        vm.prank(operator);
        warehouse.settleReceivables(market, takeout, 1, 0, 1);

        assertEq(warehouse.totalReceivables(), POOL_FACE, "reverted release moved collateral");
        assertEq(MIDNIGHT.collateral(marketId, address(warehouse), 0), POOL_FACE, "pledge changed on revert");
    }

    function test_onlyPledgedReceivablesSupportBorrowingBaseAndLooseAssetsRemainRecoverable() public {
        _fundLender(1_000_000e6);
        _depositJunior(300_000e6);

        receivable.mint(operator, POOL_FACE);
        vm.startPrank(operator);
        receivable.approve(address(warehouse), POOL_FACE);
        warehouse.depositAndPledgeReceivables(market, 0, 800_000e6);
        assertTrue(receivable.transfer(address(warehouse), 200_000e6));
        vm.stopPrank();

        assertEq(warehouse.totalReceivables(), POOL_FACE, "total pool is wrong");
        assertEq(warehouse.pledgedReceivables(), 800_000e6, "pledged pool is wrong");
        assertEq(warehouse.unpledgedReceivables(), 200_000e6, "loose pool is wrong");
        assertEq(warehouse.borrowingBase(), 600_000e6, "loose assets received borrowing-base credit");

        Offer memory offer = _offer(SENIOR_FACE, keccak256("partial pledge"));
        bytes memory ratifierData = _ratify(offer);
        vm.expectRevert(
            abi.encodeWithSelector(
                WarehouseAccount.BorrowingBaseExceeded.selector, uint256(SENIOR_FACE), uint256(600_000e6)
            )
        );
        vm.prank(operator);
        warehouse.borrow(offer, ratifierData, SENIOR_FACE, 0);

        vm.startPrank(operator);
        warehouse.enterRunOff();
        warehouse.releaseResidualReceivables(market, address(this));
        vm.stopPrank();

        assertEq(warehouse.totalReceivables(), 0, "run-off stranded receivables");
        assertEq(receivable.balanceOf(address(this)), POOL_FACE, "receivables were not recovered");
    }

    function test_runOffIsOneWayAndSeniorAlwaysRanksAheadOfJunior() public {
        _openWarehouse();

        vm.expectRevert(WarehouseAccount.InvalidState.selector);
        vm.prank(operator);
        warehouse.sweepCollectionsToSenior(market);

        vm.prank(operator);
        warehouse.enterRunOff();

        vm.expectRevert(WarehouseAccount.InvalidState.selector);
        vm.prank(operator);
        warehouse.fundOriginations(1);

        vm.expectRevert(WarehouseAccount.InvalidState.selector);
        vm.prank(operator);
        warehouse.depositAndPledgeReceivables(market, 0, 1);

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
        warehouse.sweepCollectionsToSenior(market);
        warehouse.enterRunOff();
        warehouse.releaseResidualReceivables(market, address(this));
        vm.stopPrank();

        assertEq(warehouse.seniorDebt(), 0, "asset removal trapped senior debt");
        assertEq(warehouse.totalReceivables(), 0, "asset removal trapped collateral");
    }

    function test_failedOracleCannotStrandCollateralAfterSeniorIsSatisfied() public {
        _openWarehouse();
        _depositJunior(SENIOR_FACE);

        vm.prank(operator);
        warehouse.enterRunOff();
        warehouse.sweepCollectionsToSenior(market);
        vm.prank(administrator);
        oracle.setShouldRevert(true);

        vm.prank(operator);
        warehouse.releaseResidualReceivables(market, address(this));

        assertEq(warehouse.totalReceivables(), 0, "failed oracle stranded collateral");
    }

    function test_delistedAssetCannotResumeNewMoneyAfterSeniorIsRepaid() public {
        _openWarehouse();

        vm.prank(administrator);
        registry.setAsset(address(receivable), address(oracle), ADVANCE_RATE_BPS, false);

        _depositJunior(uint256(SENIOR_FACE) + 1);
        warehouse.flagDeficiency();
        warehouse.sweepCollectionsToSenior(market);

        vm.expectRevert(WarehouseAccount.InvalidState.selector);
        vm.prank(operator);
        warehouse.fundOriginations(1);

        vm.expectRevert(WarehouseAccount.InvalidMarket.selector);
        vm.prank(operator);
        warehouse.cureDeficiency();
    }

    function test_registryTermsCannotChangeAfterConfiguration() public {
        _openWarehouse();

        vm.expectRevert(AssetRegistry.AssetTermsLocked.selector);
        vm.prank(administrator);
        registry.setAsset(address(receivable), address(oracle), 9_000, true);

        assertEq(warehouse.borrowingBase(), SENIOR_FACE, "locked terms changed borrowing base");
    }

    function test_expiryBlocksNewMoneyAndOpensPermissionlessRunOffAndSweep() public {
        _openWarehouse();

        _depositJunior(1e6);

        vm.warp(warehouse.availabilityEnd());
        assertTrue(warehouse.facilityExpired(), "facility did not expire");

        vm.expectRevert(WarehouseAccount.InvalidState.selector);
        vm.prank(operator);
        warehouse.fundOriginations(1e6);

        vm.prank(stranger);
        warehouse.enterRunOff();
        vm.prank(stranger);
        assertEq(warehouse.sweepCollectionsToSenior(market), 1e6, "expired cash was not swept");
    }

    function test_midnightBadDebtCannotBypassSeniorPriority() public {
        _openWarehouse();
        _depositJunior(100_000e6);

        vm.prank(administrator);
        oracle.setPrice(0);
        MIDNIGHT.liquidate(market, 0, 0, 0, address(warehouse), false, address(this), address(0), "");

        assertEq(warehouse.seniorDebt(), 0, "Midnight debt was not written down");
        assertGt(MIDNIGHT.lossFactor(marketId), 0, "Midnight did not record a loss");
        assertTrue(warehouse.seniorLossRealized(), "facility forgot the senior loss");
        assertTrue(warehouse.checkDeficiency(), "senior loss did not freeze the facility");

        vm.expectRevert(WarehouseAccount.SeniorLossRealized.selector);
        vm.prank(operator);
        warehouse.fundOriginations(1);

        vm.prank(operator);
        warehouse.enterRunOff();
        vm.expectRevert(WarehouseAccount.SeniorOutstanding.selector);
        vm.prank(sponsor);
        warehouse.withdrawJuniorResidual(1, sponsor);
        assertEq(warehouse.cashBalance(), 100_000e6, "realized loss released trapped cash");
    }

    function test_cashBackedLiquidationIsNotMisclassifiedAsSeniorLoss() public {
        _openWarehouse();
        uint256 repaidUnits = 100_000e6;
        uint256 lossFactorBefore = MIDNIGHT.lossFactor(marketId);

        vm.warp(maturity + 1);
        deal(address(USDC), stranger, repaidUnits, true);
        vm.startPrank(stranger);
        USDC.approve(address(MIDNIGHT), repaidUnits);
        MIDNIGHT.liquidate(market, 0, 0, repaidUnits, address(warehouse), true, stranger, address(0), "");
        vm.stopPrank();

        assertEq(warehouse.seniorDebt(), uint256(SENIOR_FACE) - repaidUnits, "liquidation repayment is wrong");
        assertEq(MIDNIGHT.lossFactor(marketId), lossFactorBefore, "cash repayment changed loss factor");
        assertFalse(warehouse.seniorLossRealized(), "cash repayment was classified as a loss");
        assertTrue(warehouse.canIncreaseCredit(lender), "fixed lender was rejected");
        assertFalse(warehouse.canIncreaseCredit(stranger), "lender credit remained transferable");
    }

    function test_marketRejectsEveryOtherBorrower() public {
        _openWarehouse();
        _fundLender(1_000_000e6);
        receivable.mint(stranger, POOL_FACE);
        vm.startPrank(stranger);
        receivable.approve(address(MIDNIGHT), POOL_FACE);
        MIDNIGHT.supplyCollateral(market, 0, POOL_FACE, stranger);
        vm.stopPrank();

        Offer memory offer = _offer(SENIOR_FACE, keccak256("unrelated borrower"));
        bytes memory ratifierData = _ratify(offer);

        vm.expectRevert(IMidnight.SellerGatedFromIncreasingDebt.selector);
        vm.prank(stranger);
        MIDNIGHT.take(offer, ratifierData, SENIOR_FACE, stranger, stranger, address(0), "");
    }

    function test_onlyNamedPartiesCanMoveWarehouseAssets() public {
        _depositJunior(100e6);
        _depositAndPledge(100e6);

        vm.expectRevert(WarehouseAccount.OnlyJuniorProvider.selector);
        vm.prank(stranger);
        warehouse.juniorDeposit(1);

        vm.expectRevert(WarehouseAccount.OnlyOperator.selector);
        vm.prank(stranger);
        warehouse.fundOriginations(1);

        vm.expectRevert(WarehouseAccount.OnlyOperator.selector);
        vm.prank(stranger);
        warehouse.releaseResidualReceivables(market, stranger);

        assertEq(warehouse.cashBalance(), 100e6, "unauthorized call moved junior cash");
        assertEq(warehouse.totalReceivables(), 100e6, "unauthorized call moved receivables");
    }
}
