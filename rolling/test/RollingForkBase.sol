// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IMidnight, Market, CollateralParams, Offer} from "midnight/interfaces/IMidnight.sol";
import {ISetterRatifier} from "midnight/ratifiers/interfaces/ISetterRatifier.sol";
import {HashLib} from "midnight/ratifiers/libraries/HashLib.sol";
import {TickLib} from "midnight/libraries/TickLib.sol";
import {RollingBorrower} from "../src/RollingBorrower.sol";
import {TwoPartyGate} from "../src/TwoPartyGate.sol";
import {MockCollateral, FixedOracle} from "./mocks/MockCollateral.sol";

abstract contract RollingForkBase is Test {
    IMidnight internal constant MIDNIGHT = IMidnight(0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A);
    address internal constant SETTER_RATIFIER = 0x800B5F12A61B8198a5a6EfD794Cac6699B294d63;
    IERC20 internal constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address internal constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant ORACLE_PRICE = 1e36;
    uint256 internal constant LLTV = 0.965e18;
    uint256 internal constant LIQUIDATION_CURSOR = 0.3e18;
    uint256 internal constant APR = 0.05e18;
    uint256 internal constant TICK_SPACING = 4;
    uint128 internal constant FACE = 1_000_000e6;
    uint256 internal constant COLLATERAL = 1_100_000e6;

    address internal borrowerOperator = makeAddr("borrowerOperator");
    address internal lenderOperator = makeAddr("lenderOperator");
    address internal capitalOwner = makeAddr("capitalOwner");
    address internal liquidator = makeAddr("liquidator");
    address internal useOfProceeds = makeAddr("useOfProceeds");
    address internal sponsor = makeAddr("sponsor");
    address internal stranger = makeAddr("stranger");

    RollingBorrower internal borrower;
    TwoPartyGate internal gate;
    MockCollateral internal collateral;
    FixedOracle internal oracle;

    function _fork() internal {
        string memory forkBlock = vm.envOr("FORK_BLOCK", string(""));
        if (bytes(forkBlock).length == 0) {
            vm.createSelectFork(vm.envString("BASE_RPC"));
        } else {
            vm.createSelectFork(vm.envString("BASE_RPC"), vm.parseUint(forkBlock));
        }
    }

    function _deployBorrower() internal {
        borrower = new RollingBorrower(address(MIDNIGHT), borrowerOperator);
        collateral = new MockCollateral();
        oracle = new FixedOracle(ORACLE_PRICE);
    }

    function _configure(address lender, uint256 firstMaturity) internal {
        gate = new TwoPartyGate(lender, address(borrower), liquidator);
        vm.prank(borrowerOperator);
        borrower.configureMarket(_market(firstMaturity));

        collateral.mint(address(borrower), COLLATERAL);
        vm.startPrank(borrowerOperator);
        borrower.approveToken(address(collateral));
        borrower.approveToken(address(USDC));
        borrower.supplyCollateral(_market(firstMaturity), COLLATERAL);
        vm.stopPrank();
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
            enterGate: address(gate),
            liquidatorGate: address(gate)
        });
    }

    function _offer(uint256 maturity, uint256 tick, address maker) internal view returns (Offer memory offer) {
        offer = Offer({
            market: _market(maturity),
            buy: true,
            maker: maker,
            start: 0,
            expiry: maturity,
            tick: tick,
            group: bytes32(maturity),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: SETTER_RATIFIER,
            reduceOnly: false,
            maxUnits: FACE,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
    }

    function _ratifyEoa(Offer memory offer, address lender) internal returns (bytes memory ratifierData) {
        bytes32 root = HashLib.hashOffer(offer);
        vm.startPrank(lender);
        MIDNIGHT.setIsAuthorized(SETTER_RATIFIER, true, lender);
        ISetterRatifier(SETTER_RATIFIER).setIsRootRatified(lender, root, true);
        vm.stopPrank();
        return abi.encode(root, uint256(0), new bytes32[](0));
    }

    function _tick() internal pure returns (uint256) {
        uint256 targetPrice = WAD * WAD / (WAD + APR / 365);
        return TickLib.priceToTick(targetPrice, TICK_SPACING);
    }

    function _advance(uint256 tick) internal pure returns (uint256) {
        return uint256(FACE) * TickLib.tickToPrice(tick) / WAD;
    }

    function _fundReserve(uint256 amount) internal {
        deal(address(USDC), sponsor, amount, true);
        vm.prank(sponsor);
        assertTrue(USDC.transfer(address(borrower), amount), "reserve transfer failed");
    }
}
