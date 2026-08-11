// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Market, Offer} from "midnight/interfaces/IMidnight.sol";
import {HashLib} from "midnight/ratifiers/libraries/HashLib.sol";
import {RollingBorrower} from "../src/RollingBorrower.sol";
import {FlashRollLender} from "../src/FlashRollLender.sol";
import {RollingForkBase} from "./RollingForkBase.sol";

contract FlashRollTest is RollingForkBase {
    uint256 internal constant N = 30;
    uint256 internal constant ROLL_LEAD = 1 hours;
    uint256 internal constant RESERVE_MARGIN = 1e6;

    FlashRollLender internal flashLender;
    uint256 internal tick;
    uint256 internal advance;
    uint256 internal dailyCost;
    uint256[N + 1] internal maturities;
    bytes32[N + 1] internal ids;

    function setUp() public {
        _fork();
        _deployBorrower();

        flashLender = new FlashRollLender(
            MORPHO_BLUE,
            address(MIDNIGHT),
            address(USDC),
            SETTER_RATIFIER,
            address(borrower),
            lenderOperator,
            capitalOwner
        );

        for (uint256 i = 1; i <= N; ++i) {
            maturities[i] = block.timestamp + i * 1 days;
        }
        _configure(address(flashLender), maturities[1]);
        vm.prank(borrowerOperator);
        borrower.setRollExecutor(address(flashLender));

        tick = _tick();
        advance = _advance(tick);
        dailyCost = uint256(FACE) - advance;
        ids[1] = MIDNIGHT.touchMarket(_market(maturities[1]));
    }

    function test_thirtyDayFlashRollLifecycleNeedsNoIdlePrincipal() public {
        _open();
        _fundReserve((N - 1) * dailyCost + RESERVE_MARGIN);

        for (uint256 i = 2; i <= N; ++i) {
            vm.warp(maturities[i - 1] - ROLL_LEAD);
            ids[i] = MIDNIGHT.touchMarket(_market(maturities[i]));
            assertEq(MIDNIGHT.settlementFee(ids[i], maturities[i] - block.timestamp), 0, "settlement fee changed");
            assertEq(MIDNIGHT.continuousFee(ids[i]), 0, "continuous fee changed");

            FlashRollLender.RollParams memory params = _params(i - 1, i);
            bytes32 authorization = _authorize(params);
            uint256 blueBefore = USDC.balanceOf(MORPHO_BLUE);
            uint256 reserveBefore = USDC.balanceOf(address(borrower));
            uint256 ownerBefore = USDC.balanceOf(capitalOwner);
            assertEq(USDC.balanceOf(address(flashLender)), 0, "roll started with idle adapter cash");

            vm.prank(lenderOperator);
            flashLender.executeRoll(params);

            assertEq(USDC.balanceOf(MORPHO_BLUE), blueBefore, "Blue principal did not reconcile");
            assertEq(USDC.balanceOf(capitalOwner), ownerBefore, "payout happened inside the critical roll");
            assertEq(USDC.balanceOf(address(flashLender)), dailyCost, "adapter retained the wrong carry");
            assertEq(reserveBefore - USDC.balanceOf(address(borrower)), dailyCost, "reserve paid the wrong amount");
            assertFalse(borrower.isRollAuthorized(authorization), "authorization was not consumed");
            assertEq(MIDNIGHT.debt(ids[i - 1], address(borrower)), 0, "old debt remains");
            assertEq(MIDNIGHT.debt(ids[i], address(borrower)), FACE, "new debt is wrong");
            assertEq(MIDNIGHT.collateral(ids[i - 1], address(borrower), 0), 0, "old collateral remains");
            assertEq(MIDNIGHT.collateral(ids[i], address(borrower), 0), COLLATERAL, "new collateral is wrong");

            vm.prank(lenderOperator);
            flashLender.sweepAsset(dailyCost);
        }

        deal(address(USDC), address(borrower), USDC.balanceOf(address(borrower)) + uint256(FACE), true);
        vm.prank(borrowerOperator);
        borrower.repay(_market(maturities[N]), FACE);

        vm.prank(capitalOwner);
        flashLender.withdrawCredit(_market(maturities[N]), FACE);
        assertEq(USDC.balanceOf(address(flashLender)), FACE, "final principal was not recovered");
        vm.prank(capitalOwner);
        flashLender.sweepAsset(FACE);

        vm.prank(borrowerOperator);
        borrower.withdrawCollateral(_market(maturities[N]), COLLATERAL, borrowerOperator);

        assertEq(USDC.balanceOf(address(flashLender)), 0, "adapter did not finish empty");
        assertEq(MIDNIGHT.debt(ids[N], address(borrower)), 0, "final debt remains");
        assertEq(MIDNIGHT.collateral(ids[N], address(borrower), 0), 0, "final collateral remains");
        assertEq(collateral.balanceOf(borrowerOperator), COLLATERAL, "collateral was not returned");
        assertEq(USDC.balanceOf(capitalOwner), advance + N * dailyCost, "capital return is wrong");
    }

    function test_unapprovedTermsCannotSpendTheReserve() public {
        _openAndFundOneRoll();
        FlashRollLender.RollParams memory approved = _params(1, 2);
        _authorize(approved);

        FlashRollLender.RollParams memory punitive = approved;
        punitive.newOffer.tick -= TICK_SPACING;
        punitive.ratifierData = _ratifyFlash(punitive.newOffer);

        vm.prank(lenderOperator);
        vm.expectRevert(RollingBorrower.RollNotAuthorized.selector);
        flashLender.executeRoll(punitive);
        _assertFirstPositionUnchanged();
    }

    function test_emptyReserveRevertsAtomicallyAndCanRetry() public {
        _open();
        vm.warp(maturities[1] - ROLL_LEAD);
        ids[2] = MIDNIGHT.touchMarket(_market(maturities[2]));
        FlashRollLender.RollParams memory params = _params(1, 2);
        bytes32 authorization = _authorize(params);

        vm.prank(lenderOperator);
        vm.expectRevert();
        flashLender.executeRoll(params);
        _assertFirstPositionUnchanged();
        assertTrue(borrower.isRollAuthorized(authorization), "failed roll consumed authorization");

        _fundReserve(dailyCost);
        vm.prank(lenderOperator);
        flashLender.executeRoll(params);
        assertFalse(borrower.isRollAuthorized(authorization), "retry kept authorization");
        assertEq(MIDNIGHT.debt(ids[2], address(borrower)), FACE, "retry did not roll debt");
    }

    function test_insufficientBlueLiquidityRevertsAtomically() public {
        _openAndFundOneRoll();
        FlashRollLender.RollParams memory params = _params(1, 2);
        _authorize(params);
        deal(address(USDC), MORPHO_BLUE, uint256(FACE) - 1, true);

        vm.prank(lenderOperator);
        vm.expectRevert();
        flashLender.executeRoll(params);
        _assertFirstPositionUnchanged();
    }

    function test_rollAuthorizationCannotReplay() public {
        _openAndFundOneRoll();
        FlashRollLender.RollParams memory params = _params(1, 2);
        _authorize(params);
        vm.prank(lenderOperator);
        flashLender.executeRoll(params);

        vm.prank(lenderOperator);
        vm.expectRevert(RollingBorrower.RollNotAuthorized.selector);
        flashLender.executeRoll(params);
    }

    function test_unsweptCarryCannotBlockTheNextRoll() public {
        _open();
        _fundReserve(2 * dailyCost);

        for (uint256 i = 2; i <= 3; ++i) {
            vm.warp(maturities[i - 1] - ROLL_LEAD);
            ids[i] = MIDNIGHT.touchMarket(_market(maturities[i]));
            FlashRollLender.RollParams memory params = _params(i - 1, i);
            _authorize(params);
            vm.prank(lenderOperator);
            flashLender.executeRoll(params);
        }

        assertEq(USDC.balanceOf(address(flashLender)), 2 * dailyCost, "carry disrupted the next roll");
        assertEq(MIDNIGHT.debt(ids[3], address(borrower)), FACE, "second roll did not complete");
    }

    function test_callbackAndCustodyPermissions() public {
        vm.expectRevert(FlashRollLender.OnlyMorphoBlue.selector);
        flashLender.onMorphoFlashLoan(1, hex"01");

        vm.prank(MORPHO_BLUE);
        vm.expectRevert(FlashRollLender.UnexpectedCallback.selector);
        flashLender.onMorphoFlashLoan(1, hex"01");

        vm.prank(lenderOperator);
        vm.expectRevert(FlashRollLender.OnlyCapitalOwner.selector);
        flashLender.setRootRatified(bytes32(uint256(1)), true);

        vm.prank(stranger);
        vm.expectRevert(FlashRollLender.OnlyCapitalOwner.selector);
        flashLender.setBeneficiary(stranger);

        vm.prank(stranger);
        vm.expectRevert(FlashRollLender.OnlyOperatorOrCapitalOwner.selector);
        flashLender.sweepAsset(0);
    }

    function test_marketShapeIsPinnedAcrossMaturities() public view {
        Market memory supported = _market(maturities[2]);
        assertTrue(borrower.isSupportedMarket(supported));
        supported.collateralParams[0].lltv = 0.9e18;
        assertFalse(borrower.isSupportedMarket(supported));
    }

    function _open() internal {
        assertEq(MIDNIGHT.settlementFee(ids[1], 1 days), 0, "settlement fee changed");
        assertEq(MIDNIGHT.continuousFee(ids[1]), 0, "continuous fee changed");
        deal(address(USDC), capitalOwner, advance, true);
        vm.prank(capitalOwner);
        assertTrue(USDC.transfer(address(flashLender), advance), "opening capital transfer failed");

        Offer memory offer = _offer(maturities[1], tick, address(flashLender));
        bytes memory ratifierData = _ratifyFlash(offer);
        vm.prank(borrowerOperator);
        borrower.open(offer, ratifierData, FACE, useOfProceeds);

        assertEq(USDC.balanceOf(address(flashLender)), 0, "opening capital was not fully deployed");
        assertEq(USDC.balanceOf(useOfProceeds), advance, "opening proceeds are wrong");
        assertEq(MIDNIGHT.debt(ids[1], address(borrower)), FACE, "opening debt is wrong");
    }

    function _openAndFundOneRoll() internal {
        _open();
        _fundReserve(dailyCost);
        vm.warp(maturities[1] - ROLL_LEAD);
        ids[2] = MIDNIGHT.touchMarket(_market(maturities[2]));
    }

    function _params(uint256 from, uint256 to) internal returns (FlashRollLender.RollParams memory params) {
        Offer memory offer = _offer(maturities[to], tick, address(flashLender));
        params = FlashRollLender.RollParams({
            newOffer: offer,
            ratifierData: _ratifyFlash(offer),
            oldMarket: _market(maturities[from]),
            units: FACE,
            collateralAmount: COLLATERAL
        });
    }

    function _ratifyFlash(Offer memory offer) internal returns (bytes memory ratifierData) {
        bytes32 root = HashLib.hashOffer(offer);
        vm.prank(capitalOwner);
        flashLender.setRootRatified(root, true);
        return abi.encode(root, uint256(0), new bytes32[](0));
    }

    function _authorize(FlashRollLender.RollParams memory params) internal returns (bytes32 authorization) {
        authorization = borrower.rollAuthorizationHash(
            params.newOffer, params.ratifierData, params.units, params.oldMarket, params.units, params.collateralAmount
        );
        vm.prank(borrowerOperator);
        borrower.setRollAuthorization(authorization, true);
    }

    function _assertFirstPositionUnchanged() internal view {
        assertEq(MIDNIGHT.debt(ids[1], address(borrower)), FACE, "failed roll changed old debt");
        assertEq(MIDNIGHT.debt(ids[2], address(borrower)), 0, "failed roll created new debt");
        assertEq(MIDNIGHT.collateral(ids[1], address(borrower), 0), COLLATERAL, "failed roll moved collateral");
    }
}
