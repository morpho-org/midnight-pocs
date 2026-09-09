// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Offer} from "midnight/interfaces/IMidnight.sol";
import {WarehouseAccount} from "../src/WarehouseAccount.sol";
import {WarehouseForkBase} from "./WarehouseForkBase.sol";
import {MockReceivableOracle} from "./mocks/MockReceivable.sol";

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
        warehouse.borrow(offer, ratifierData, excessiveFace);
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
        warehouse.borrow(blockedOffer, "", 1);

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

    function test_onlyPledgedReceivablesSupportBorrowingBaseAndLooseAssetsRemainRecoverable() public {
        _fundLender(1_000_000e6);
        _depositJunior(300_000e6);

        receivable.mint(operator, POOL_FACE);
        vm.startPrank(operator);
        receivable.approve(address(warehouse), POOL_FACE);
        warehouse.depositReceivables(POOL_FACE);
        warehouse.pledgeReceivables(market, 0, 800_000e6);
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
        warehouse.borrow(offer, ratifierData, SENIOR_FACE);

        vm.startPrank(operator);
        warehouse.enterRunOff();
        warehouse.releaseUnpledgedReceivables(200_000e6, address(this));
        warehouse.releaseReceivables(market, 800_000e6, address(this));
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
        warehouse.sweepCollectionsToSenior(market);
        warehouse.enterRunOff();
        warehouse.releaseReceivables(market, POOL_FACE, address(this));
        vm.stopPrank();

        assertEq(warehouse.seniorDebt(), 0, "asset removal trapped senior debt");
        assertEq(warehouse.totalReceivables(), 0, "asset removal trapped collateral");
    }

    function test_delistedAssetCannotResumeNewMoneyAfterSeniorIsRepaid() public {
        _openWarehouse();

        vm.prank(administrator);
        registry.setAsset(address(receivable), address(oracle), ADVANCE_RATE_BPS, false);

        deal(address(USDC), takeout, uint256(SENIOR_FACE) + 1, true);
        vm.startPrank(takeout);
        USDC.approve(address(warehouse), type(uint256).max);
        warehouse.depositCollection(uint256(SENIOR_FACE) + 1);
        vm.stopPrank();

        vm.prank(operator);
        warehouse.repaySenior(market, SENIOR_FACE);

        vm.expectRevert(WarehouseAccount.InvalidMarket.selector);
        vm.prank(operator);
        warehouse.fundOriginations(1);
    }

    function test_facilityTermsStayPinnedWhenRegistryConfigurationChanges() public {
        _openWarehouse();
        MockReceivableOracle replacementOracle = new MockReceivableOracle(administrator, 2e36);

        vm.prank(administrator);
        registry.setAsset(address(receivable), address(replacementOracle), 9_000, true);

        assertEq(warehouse.facilityOracle(), address(oracle), "facility oracle changed");
        assertEq(warehouse.facilityAdvanceRateBps(), ADVANCE_RATE_BPS, "advance rate changed");
        assertEq(warehouse.collateralValue(), POOL_FACE, "replacement oracle changed facility value");
        assertEq(warehouse.borrowingBase(), SENIOR_FACE, "replacement terms changed borrowing base");
    }

    function test_expiryBlocksNewMoneyAndOpensPermissionlessRunOffAndSweep() public {
        _openWarehouse();

        deal(address(USDC), takeout, 1e6, true);
        vm.startPrank(takeout);
        USDC.approve(address(warehouse), 1e6);
        warehouse.depositCollection(1e6);
        vm.stopPrank();

        vm.warp(warehouse.availabilityEnd());
        assertTrue(warehouse.facilityExpired(), "facility did not expire");

        vm.expectRevert(WarehouseAccount.InvalidState.selector);
        vm.prank(operator);
        warehouse.fundOriginations(1e6);

        vm.prank(stranger);
        warehouse.enterExpiredRunOff();
        vm.prank(stranger);
        assertEq(warehouse.sweepCollectionsToSenior(market), 1e6, "expired cash was not swept");
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
        warehouse.releaseReceivables(market, 1, stranger);

        assertEq(warehouse.cashBalance(), 100e6, "unauthorized call moved junior cash");
        assertEq(warehouse.totalReceivables(), 100e6, "unauthorized call moved receivables");
    }
}
