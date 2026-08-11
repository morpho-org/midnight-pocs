// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IMidnight, Market, CollateralParams, Offer} from "midnight/interfaces/IMidnight.sol";
import {ISetterRatifier} from "midnight/ratifiers/interfaces/ISetterRatifier.sol";
import {HashLib} from "midnight/ratifiers/libraries/HashLib.sol";
import {IdLib} from "midnight/libraries/IdLib.sol";
import {TickLib} from "midnight/libraries/TickLib.sol";
import {MidnightRoller} from "../src/MidnightRoller.sol";
import {MockCollateral, FixedOracle} from "./mocks/MockCollateral.sol";

contract MidnightRollerTest is Test {
    IMidnight internal constant MIDNIGHT = IMidnight(0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A);
    address internal constant SETTER_RATIFIER = 0x800B5F12A61B8198a5a6EfD794Cac6699B294d63;
    IERC20 internal constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    uint256 internal constant WAD = 1e18;
    uint256 internal constant ORACLE_PRICE = 1e36;
    uint256 internal constant LLTV = 0.965e18;
    uint256 internal constant LIQUIDATION_CURSOR = 0.3e18;
    uint256 internal constant APR = 0.05e18;
    uint256 internal constant TICK_SPACING = 4;
    uint256 internal constant FACE = 1_000_000e6;
    uint128 internal constant MAX_OFFER_UNITS = 2_000_000e6;
    uint256 internal constant COLLATERAL = 1_100_000e6;

    address internal user = makeAddr("user");
    address internal oldLender = makeAddr("oldLender");
    address internal newLender = makeAddr("newLender");
    address internal thirdLender = makeAddr("thirdLender");
    address internal attacker = makeAddr("attacker");

    MidnightRoller internal roller;
    MockCollateral internal collateral;
    FixedOracle internal oracle;

    uint256 internal firstMaturity;
    uint256 internal secondMaturity;
    uint256 internal thirdMaturity;
    uint256 internal tick;

    function setUp() public {
        string memory forkBlock = vm.envOr("FORK_BLOCK", string(""));
        if (bytes(forkBlock).length == 0) {
            vm.createSelectFork(vm.envString("BASE_RPC"));
        } else {
            vm.createSelectFork(vm.envString("BASE_RPC"), vm.parseUint(forkBlock));
        }

        collateral = new MockCollateral();
        oracle = new FixedOracle(ORACLE_PRICE);
        roller = new MidnightRoller(address(MIDNIGHT));

        firstMaturity = block.timestamp + 1 days;
        secondMaturity = firstMaturity + 1 days;
        thirdMaturity = secondMaturity + 1 days;
        tick = _tick();

        // Prime the singleton's Midnight allowances for both tokens (anyone can call).
        roller.setApprovalMax(address(USDC));
        roller.setApprovalMax(address(collateral));

        _prepareLender(oldLender);
        _prepareLender(newLender);
        _prepareLender(thirdLender);
    }

    function testFullLifecycleRollsFromOldLenderToNewLender() public {
        // 1. Open the user's first position on Midnight directly (no roller yet).
        _openPosition(user, firstMaturity, FACE, COLLATERAL, oldLender);
        bytes32 oldId = IdLib.toId(_market(firstMaturity));
        assertEq(MIDNIGHT.debt(oldId, user), FACE, "old debt not opened");
        assertEq(MIDNIGHT.collateral(oldId, user, 0), COLLATERAL, "old collateral not deposited");
        assertEq(MIDNIGHT.credit(oldId, oldLender), FACE, "old lender credit not opened");

        // 2. User authorises the roller singleton on Midnight (one-time setup).
        vm.prank(user);
        MIDNIGHT.setIsAuthorized(address(roller), true, user);

        // 3. A different lender provides the valid offer for the second maturity.
        Offer memory nextOffer = _offer(secondMaturity, tick, newLender);
        bytes memory ratifierData = _ratifyEoa(nextOffer, newLender);

        // 4. Roll.
        MidnightRoller.RollParams memory params = MidnightRoller.RollParams({
            oldMarket: _market(firstMaturity),
            oldCollateralIndex: 0,
            newCollateralIndex: 0,
            collateralAmount: COLLATERAL,
            oldUnits: FACE,
            maxNewUnits: FACE * 2,
            maxLtv: 0,
            newOffer: nextOffer,
            ratifierData: ratifierData
        });
        vm.prank(user);
        uint256 newUnits = roller.roll(params);

        // 5. Assert old position is closed, new one is open with the same collateral.
        bytes32 newId = IdLib.toId(_market(secondMaturity));
        assertEq(MIDNIGHT.debt(oldId, user), 0, "old debt not repaid");
        assertEq(MIDNIGHT.collateral(oldId, user, 0), 0, "old collateral not withdrawn");
        assertEq(MIDNIGHT.debt(newId, user), newUnits, "new debt wrong");
        assertEq(MIDNIGHT.collateral(newId, user, 0), COLLATERAL, "new collateral wrong");
        assertEq(MIDNIGHT.credit(newId, newLender), newUnits, "new lender credit wrong");
        assertGt(newUnits, FACE, "newUnits should exceed old face to cover the discount");

        // 6. The old lender exits after its credit is made withdrawable by the repayment.
        uint256 oldLenderBalance = USDC.balanceOf(oldLender);
        vm.prank(oldLender);
        MIDNIGHT.withdraw(_market(firstMaturity), FACE, oldLender, oldLender);
        assertEq(USDC.balanceOf(oldLender), oldLenderBalance + FACE, "old lender was not repaid");

        // 7. Repay the new lender and return the collateral to complete the lifecycle.
        deal(address(USDC), user, USDC.balanceOf(user) + newUnits, true);
        vm.startPrank(user);
        USDC.approve(address(MIDNIGHT), type(uint256).max);
        MIDNIGHT.repay(_market(secondMaturity), newUnits, user, address(0), "");
        MIDNIGHT.withdrawCollateral(_market(secondMaturity), 0, COLLATERAL, user, user);
        vm.stopPrank();

        uint256 newLenderBalance = USDC.balanceOf(newLender);
        vm.prank(newLender);
        MIDNIGHT.withdraw(_market(secondMaturity), newUnits, newLender, newLender);
        assertEq(USDC.balanceOf(newLender), newLenderBalance + newUnits, "new lender was not repaid");

        // 8. Every position and the singleton finish empty.
        assertEq(MIDNIGHT.debt(newId, user), 0, "final debt remains");
        assertEq(MIDNIGHT.collateral(newId, user, 0), 0, "final collateral remains");
        assertEq(USDC.balanceOf(address(roller)), 0, "roller retains loan token");
        assertEq(collateral.balanceOf(address(roller)), 0, "roller retains collateral");
    }

    function testRepeatedRollsCompoundDebtAcrossLenders() public {
        _openPosition(user, firstMaturity, FACE, COLLATERAL, oldLender);
        vm.prank(user);
        MIDNIGHT.setIsAuthorized(address(roller), true, user);

        vm.warp(firstMaturity - 1 hours);
        MidnightRoller.RollParams memory secondParams =
            _rollParams(firstMaturity, secondMaturity, FACE, COLLATERAL, FACE * 2, 0, newLender);
        vm.prank(user);
        uint256 secondUnits = roller.roll(secondParams);

        // Capitalized carry makes the second debt slightly larger than FACE, so the third lender funds that amount.
        deal(address(USDC), thirdLender, FACE * 2, true);
        vm.warp(secondMaturity - 1 hours);
        MidnightRoller.RollParams memory thirdParams =
            _rollParams(secondMaturity, thirdMaturity, secondUnits, COLLATERAL, FACE * 2, 0, thirdLender);
        vm.prank(user);
        uint256 thirdUnits = roller.roll(thirdParams);

        bytes32 firstId = IdLib.toId(_market(firstMaturity));
        bytes32 secondId = IdLib.toId(_market(secondMaturity));
        bytes32 thirdId = IdLib.toId(_market(thirdMaturity));
        assertEq(MIDNIGHT.debt(firstId, user), 0, "first debt remains");
        assertEq(MIDNIGHT.debt(secondId, user), 0, "second debt remains");
        assertEq(MIDNIGHT.debt(thirdId, user), thirdUnits, "third debt wrong");
        assertEq(MIDNIGHT.collateral(firstId, user, 0), 0, "first collateral remains");
        assertEq(MIDNIGHT.collateral(secondId, user, 0), 0, "second collateral remains");
        assertEq(MIDNIGHT.collateral(thirdId, user, 0), COLLATERAL, "third collateral wrong");
        assertGt(secondUnits, FACE, "first roll did not capitalize carry");
        assertGt(thirdUnits, secondUnits, "second roll did not capitalize carry");
        assertEq(USDC.balanceOf(address(roller)), 0, "roller retains loan token");
        assertEq(collateral.balanceOf(address(roller)), 0, "roller retains collateral");
    }

    function testRollAccountsForSettlementFee() public {
        _openPosition(user, firstMaturity, FACE, COLLATERAL, oldLender);
        vm.prank(user);
        MIDNIGHT.setIsAuthorized(address(roller), true, user);

        Market memory newMarket = _market(secondMaturity);
        bytes32 newId = MIDNIGHT.touchMarket(newMarket);
        uint256 settlementFee = 0.00001e18;
        vm.startPrank(MIDNIGHT.feeSetter());
        MIDNIGHT.setMarketSettlementFee(newId, 1, settlementFee);
        MIDNIGHT.setMarketSettlementFee(newId, 2, settlementFee);
        vm.stopPrank();

        // The new lender pays both the advance and the settlement fee charged by Midnight.
        deal(address(USDC), newLender, FACE * 2, true);
        uint256 offerPrice = TickLib.tickToPrice(tick);
        uint256 unitsWithoutFee = (FACE * WAD + offerPrice - 1) / offerPrice;
        uint256 claimableFeeBefore = MIDNIGHT.claimableSettlementFee(address(USDC));

        MidnightRoller.RollParams memory params =
            _rollParams(firstMaturity, secondMaturity, FACE, COLLATERAL, FACE * 2, 0, newLender);
        vm.prank(user);
        uint256 newUnits = roller.roll(params);

        bytes32 oldId = IdLib.toId(_market(firstMaturity));
        assertGt(newUnits, unitsWithoutFee, "settlement fee was not capitalized");
        assertEq(MIDNIGHT.debt(oldId, user), 0, "old debt remains");
        assertEq(MIDNIGHT.debt(newId, user), newUnits, "new debt wrong");
        assertGt(MIDNIGHT.claimableSettlementFee(address(USDC)), claimableFeeBefore, "fee was not accrued");
        assertEq(USDC.balanceOf(address(roller)), 0, "roller retains loan token");
        assertEq(collateral.balanceOf(address(roller)), 0, "roller retains collateral");
    }

    function testUnauthorizedCallerCannotRollAnotherBorrower() public {
        _openPosition(user, firstMaturity, FACE, COLLATERAL, oldLender);
        vm.prank(user);
        MIDNIGHT.setIsAuthorized(address(roller), true, user);

        MidnightRoller.RollParams memory params =
            _rollParams(firstMaturity, secondMaturity, FACE, COLLATERAL, FACE * 2, 0, newLender);

        // The attacker may authorize the singleton for itself, but roll() still cannot select the user's position.
        vm.prank(attacker);
        MIDNIGHT.setIsAuthorized(address(roller), true, attacker);
        vm.prank(attacker);
        vm.expectRevert();
        roller.roll(params);

        bytes32 oldId = IdLib.toId(_market(firstMaturity));
        bytes32 newId = IdLib.toId(_market(secondMaturity));
        assertEq(MIDNIGHT.debt(oldId, user), FACE, "attacker changed user debt");
        assertEq(MIDNIGHT.collateral(oldId, user, 0), COLLATERAL, "attacker moved user collateral");
        assertEq(MIDNIGHT.debt(newId, user), 0, "attacker created user debt");
        assertEq(MIDNIGHT.debt(newId, attacker), 0, "failed attack retained debt");
    }

    function testDirectCallbackIsRejected() public {
        bytes memory data = abi.encode(_market(firstMaturity), uint256(0), uint256(0), COLLATERAL, FACE);
        vm.expectRevert(MidnightRoller.OnlyMidnight.selector);
        roller.onSell(
            IdLib.toId(_market(secondMaturity)), _market(secondMaturity), FACE, FACE, 0, user, address(roller), data
        );

        vm.prank(address(MIDNIGHT));
        vm.expectRevert(MidnightRoller.UnexpectedCallback.selector);
        roller.onSell(
            IdLib.toId(_market(secondMaturity)), _market(secondMaturity), FACE, FACE, 0, user, address(roller), data
        );
    }

    function testRevokedAuthorizationPreventsRoll() public {
        _openPosition(user, firstMaturity, FACE, COLLATERAL, oldLender);
        vm.startPrank(user);
        MIDNIGHT.setIsAuthorized(address(roller), true, user);
        MIDNIGHT.setIsAuthorized(address(roller), false, user);
        vm.stopPrank();

        MidnightRoller.RollParams memory params =
            _rollParams(firstMaturity, secondMaturity, FACE, COLLATERAL, FACE * 2, 0, newLender);
        vm.prank(user);
        vm.expectRevert();
        roller.roll(params);

        bytes32 oldId = IdLib.toId(_market(firstMaturity));
        assertEq(MIDNIGHT.debt(oldId, user), FACE, "revoked roll changed debt");
        assertEq(MIDNIGHT.collateral(oldId, user, 0), COLLATERAL, "revoked roll moved collateral");
    }

    function testRollRejectsExistingTargetDebt() public {
        _openPosition(user, firstMaturity, FACE, COLLATERAL, oldLender);
        _openPosition(user, secondMaturity, FACE, COLLATERAL, newLender);
        vm.prank(user);
        MIDNIGHT.setIsAuthorized(address(roller), true, user);

        MidnightRoller.RollParams memory params =
            _rollParams(firstMaturity, secondMaturity, FACE, COLLATERAL, FACE * 2, 0.95e18, newLender);
        vm.prank(user);
        vm.expectRevert(MidnightRoller.TargetDebtNotZero.selector);
        roller.roll(params);

        assertEq(MIDNIGHT.debt(IdLib.toId(_market(firstMaturity)), user), FACE, "old debt changed");
        assertEq(MIDNIGHT.debt(IdLib.toId(_market(secondMaturity)), user), FACE, "target debt changed");
    }

    function testRollRejectsZeroEconomicInputs() public {
        _openPosition(user, firstMaturity, FACE, COLLATERAL, oldLender);
        vm.prank(user);
        MIDNIGHT.setIsAuthorized(address(roller), true, user);

        MidnightRoller.RollParams memory params =
            _rollParams(firstMaturity, secondMaturity, FACE, COLLATERAL, FACE * 2, 0, newLender);

        params.oldUnits = 0;
        vm.prank(user);
        vm.expectRevert(MidnightRoller.InvalidRoll.selector);
        roller.roll(params);

        params.oldUnits = FACE;
        params.collateralAmount = 0;
        vm.prank(user);
        vm.expectRevert(MidnightRoller.InvalidRoll.selector);
        roller.roll(params);

        params.collateralAmount = COLLATERAL;
        params.maxNewUnits = 0;
        vm.prank(user);
        vm.expectRevert(MidnightRoller.InvalidRoll.selector);
        roller.roll(params);
    }

    function testRollRevertsWhenPriceTooLow() public {
        _openPosition(user, firstMaturity, FACE, COLLATERAL, oldLender);
        vm.prank(user);
        MIDNIGHT.setIsAuthorized(address(roller), true, user);

        Offer memory nextOffer = _offer(secondMaturity, tick, newLender);
        bytes memory ratifierData = _ratifyEoa(nextOffer, newLender);

        MidnightRoller.RollParams memory params = MidnightRoller.RollParams({
            oldMarket: _market(firstMaturity),
            oldCollateralIndex: 0,
            newCollateralIndex: 0,
            collateralAmount: COLLATERAL,
            oldUnits: FACE,
            maxNewUnits: FACE, // too tight: the discount forces newUnits > FACE
            maxLtv: 0,
            newOffer: nextOffer,
            ratifierData: ratifierData
        });
        vm.prank(user);
        vm.expectRevert();
        roller.roll(params);

        bytes32 oldId = IdLib.toId(_market(firstMaturity));
        bytes32 newId = IdLib.toId(_market(secondMaturity));
        assertEq(MIDNIGHT.debt(oldId, user), FACE, "failed roll changed old debt");
        assertEq(MIDNIGHT.collateral(oldId, user, 0), COLLATERAL, "failed roll moved collateral");
        assertEq(MIDNIGHT.debt(newId, user), 0, "failed roll created new debt");
    }

    function testRollRevertsWhenLtvTooHigh() public {
        _openPosition(user, firstMaturity, FACE, COLLATERAL, oldLender);
        vm.prank(user);
        MIDNIGHT.setIsAuthorized(address(roller), true, user);

        Offer memory nextOffer = _offer(secondMaturity, tick, newLender);
        bytes memory ratifierData = _ratifyEoa(nextOffer, newLender);

        // Oracle price is 1e36 and collateral == COLLATERAL, so the post-roll LTV is FACE / COLLATERAL ≈ 0.909e18.
        // A 0.5e18 cap must reject.
        MidnightRoller.RollParams memory params = MidnightRoller.RollParams({
            oldMarket: _market(firstMaturity),
            oldCollateralIndex: 0,
            newCollateralIndex: 0,
            collateralAmount: COLLATERAL,
            oldUnits: FACE,
            maxNewUnits: FACE * 2,
            maxLtv: 0.5e18,
            newOffer: nextOffer,
            ratifierData: ratifierData
        });
        vm.prank(user);
        vm.expectRevert();
        roller.roll(params);
    }

    function testRollRevertsWhenCollateralMismatch() public {
        _openPosition(user, firstMaturity, FACE, COLLATERAL, oldLender);
        vm.prank(user);
        MIDNIGHT.setIsAuthorized(address(roller), true, user);

        MockCollateral otherCollateral = new MockCollateral();
        Market memory badNewMarket = _market(secondMaturity);
        badNewMarket.collateralParams[0].token = address(otherCollateral);

        Offer memory nextOffer = _offer(secondMaturity, tick, newLender);
        nextOffer.market = badNewMarket;
        bytes memory ratifierData = _ratifyEoa(nextOffer, newLender);

        MidnightRoller.RollParams memory params = MidnightRoller.RollParams({
            oldMarket: _market(firstMaturity),
            oldCollateralIndex: 0,
            newCollateralIndex: 0,
            collateralAmount: COLLATERAL,
            oldUnits: FACE,
            maxNewUnits: FACE * 2,
            maxLtv: 0,
            newOffer: nextOffer,
            ratifierData: ratifierData
        });
        vm.prank(user);
        vm.expectRevert(MidnightRoller.CollateralMismatch.selector);
        roller.roll(params);
    }

    function testRollRevertsWhenCollateralIndexOutOfBounds() public {
        _openPosition(user, firstMaturity, FACE, COLLATERAL, oldLender);
        vm.prank(user);
        MIDNIGHT.setIsAuthorized(address(roller), true, user);

        Offer memory nextOffer = _offer(secondMaturity, tick, newLender);
        bytes memory ratifierData = _ratifyEoa(nextOffer, newLender);

        MidnightRoller.RollParams memory params = MidnightRoller.RollParams({
            oldMarket: _market(firstMaturity),
            oldCollateralIndex: 5, // both markets have a single collateral (index 0)
            newCollateralIndex: 0,
            collateralAmount: COLLATERAL,
            oldUnits: FACE,
            maxNewUnits: FACE * 2,
            maxLtv: 0,
            newOffer: nextOffer,
            ratifierData: ratifierData
        });
        vm.prank(user);
        vm.expectRevert(MidnightRoller.CollateralIndexOutOfBounds.selector);
        roller.roll(params);
    }

    function testRollRevertsWhenMaturityNotLater() public {
        _openPosition(user, firstMaturity, FACE, COLLATERAL, oldLender);
        vm.prank(user);
        MIDNIGHT.setIsAuthorized(address(roller), true, user);

        // Same-maturity offer: invalid.
        Offer memory sameMaturityOffer = _offer(firstMaturity, tick, newLender);
        bytes memory ratifierData = _ratifyEoa(sameMaturityOffer, newLender);

        MidnightRoller.RollParams memory params = MidnightRoller.RollParams({
            oldMarket: _market(firstMaturity),
            oldCollateralIndex: 0,
            newCollateralIndex: 0,
            collateralAmount: COLLATERAL,
            oldUnits: FACE,
            maxNewUnits: FACE * 2,
            maxLtv: 0,
            newOffer: sameMaturityOffer,
            ratifierData: ratifierData
        });
        vm.prank(user);
        vm.expectRevert(MidnightRoller.InvalidMaturity.selector);
        roller.roll(params);
    }

    /// -------------------------------------------------------------------- ///
    /// Helpers                                                              ///
    /// -------------------------------------------------------------------- ///

    function _openPosition(address who, uint256 maturity, uint256 units, uint256 collateralAmount, address lender)
        internal
    {
        collateral.mint(who, collateralAmount);
        vm.startPrank(who);
        collateral.approve(address(MIDNIGHT), type(uint256).max);
        MIDNIGHT.supplyCollateral(_market(maturity), 0, collateralAmount, who);
        vm.stopPrank();

        Offer memory openingOffer = _offer(maturity, tick, lender);
        bytes memory ratifierData = _ratifyEoa(openingOffer, lender);

        vm.prank(who);
        MIDNIGHT.take(openingOffer, ratifierData, units, who, who, address(0), "");
    }

    function _prepareLender(address lender) internal {
        vm.prank(lender);
        MIDNIGHT.setIsAuthorized(SETTER_RATIFIER, true, lender);

        // In the general case each lender supplies only its own facility amount; neither needs a second advance.
        deal(address(USDC), lender, FACE, true);
        vm.prank(lender);
        USDC.approve(address(MIDNIGHT), type(uint256).max);
    }

    function _rollParams(
        uint256 oldMaturity,
        uint256 newMaturity,
        uint256 oldUnits,
        uint256 collateralAmount,
        uint256 maxNewUnits,
        uint256 maxLtv,
        address lender
    ) internal returns (MidnightRoller.RollParams memory params) {
        Offer memory nextOffer = _offer(newMaturity, tick, lender);
        params = MidnightRoller.RollParams({
            oldMarket: _market(oldMaturity),
            oldCollateralIndex: 0,
            newCollateralIndex: 0,
            collateralAmount: collateralAmount,
            oldUnits: oldUnits,
            maxNewUnits: maxNewUnits,
            maxLtv: maxLtv,
            newOffer: nextOffer,
            ratifierData: _ratifyEoa(nextOffer, lender)
        });
    }

    function _market(uint256 maturity) internal view returns (Market memory market) {
        CollateralParams[] memory params = new CollateralParams[](1);
        params[0] = CollateralParams({
            token: address(collateral), lltv: LLTV, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
        });
        market = Market({
            chainId: block.chainid,
            midnight: address(MIDNIGHT),
            loanToken: address(USDC),
            collateralParams: params,
            maturity: maturity,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }

    function _offer(uint256 maturity, uint256 offerTick, address maker) internal view returns (Offer memory offer) {
        offer = Offer({
            market: _market(maturity),
            buy: true,
            maker: maker,
            start: 0,
            expiry: maturity,
            tick: offerTick,
            group: bytes32(maturity),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: SETTER_RATIFIER,
            reduceOnly: false,
            maxUnits: MAX_OFFER_UNITS,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
    }

    function _ratifyEoa(Offer memory offer, address maker) internal returns (bytes memory ratifierData) {
        bytes32 root = HashLib.hashOffer(offer);
        vm.prank(maker);
        ISetterRatifier(SETTER_RATIFIER).setIsRootRatified(maker, root, true);
        return abi.encode(root, uint256(0), new bytes32[](0));
    }

    function _tick() internal pure returns (uint256) {
        uint256 targetPrice = WAD * WAD / (WAD + APR / 365);
        return TickLib.priceToTick(targetPrice, TICK_SPACING);
    }
}
