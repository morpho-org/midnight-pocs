// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IMidnight, Market, CollateralParams, Offer} from "midnight/interfaces/IMidnight.sol";
import {ISetterRatifier} from "midnight/ratifiers/interfaces/ISetterRatifier.sol";
import {HashLib} from "midnight/ratifiers/libraries/HashLib.sol";
import {TickLib} from "midnight/libraries/TickLib.sol";
import {AssetRegistry} from "../src/AssetRegistry.sol";
import {WarehouseAccount} from "../src/WarehouseAccount.sol";
import {MockReceivable, MockReceivableOracle} from "./mocks/MockReceivable.sol";

abstract contract WarehouseForkBase is Test {
    IMidnight internal constant MIDNIGHT = IMidnight(0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A);
    address internal constant SETTER_RATIFIER = 0x800B5F12A61B8198a5a6EfD794Cac6699B294d63;
    IERC20 internal constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    uint256 internal constant WAD = 1e18;
    uint256 internal constant PAR = 1e36;
    uint256 internal constant LLTV = 0.965e18;
    uint256 internal constant LIQUIDATION_CURSOR = 0.3e18;
    uint16 internal constant ADVANCE_RATE_BPS = 7_500;
    uint256 internal constant TICK_SPACING = 4;
    uint256 internal constant APR = 0.05e18;
    uint128 internal constant POOL_FACE = 1_000_000e6;
    uint128 internal constant SENIOR_FACE = 750_000e6;

    address internal administrator = makeAddr("administrator");
    address internal operator = makeAddr("operator");
    address internal sponsor = makeAddr("sponsor");
    address internal originator = makeAddr("originator");
    address internal lender = makeAddr("lender");
    address internal takeout = makeAddr("takeout");
    address internal stranger = makeAddr("stranger");

    AssetRegistry internal registry;
    WarehouseAccount internal warehouse;
    MockReceivable internal receivable;
    MockReceivableOracle internal oracle;

    Market internal market;
    bytes32 internal marketId;
    uint256 internal maturity;
    uint256 internal tick;

    function setUp() public virtual {
        _fork();

        receivable = new MockReceivable(address(this));
        oracle = new MockReceivableOracle(administrator, PAR);
        registry = new AssetRegistry(administrator);
        vm.prank(administrator);
        registry.setAsset(address(receivable), address(oracle), ADVANCE_RATE_BPS, true);

        warehouse = new WarehouseAccount(
            address(MIDNIGHT), address(USDC), address(receivable), address(registry), operator, sponsor, originator
        );

        maturity = block.timestamp + 30 days;
        market = _market(maturity);
        marketId = MIDNIGHT.touchMarket(market);
        tick = _calibratedTick(maturity - block.timestamp);
    }

    function _fork() internal {
        string memory forkBlock = vm.envOr("FORK_BLOCK", string(""));
        if (bytes(forkBlock).length == 0) {
            vm.createSelectFork(vm.envString("BASE_RPC"));
        } else {
            vm.createSelectFork(vm.envString("BASE_RPC"), vm.parseUint(forkBlock));
        }
    }

    function _market(uint256 marketMaturity) internal view returns (Market memory result) {
        CollateralParams[] memory params = new CollateralParams[](1);
        params[0] = CollateralParams({
            token: address(receivable), lltv: LLTV, liquidationCursor: LIQUIDATION_CURSOR, oracle: address(oracle)
        });
        result = Market({
            chainId: block.chainid,
            midnight: address(MIDNIGHT),
            loanToken: address(USDC),
            collateralParams: params,
            maturity: marketMaturity,
            rcfThreshold: 0,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }

    function _offer(uint128 maxUnits, bytes32 group) internal view returns (Offer memory result) {
        result = Offer({
            market: market,
            buy: true,
            maker: lender,
            start: 0,
            expiry: maturity,
            tick: tick,
            group: group,
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: SETTER_RATIFIER,
            reduceOnly: false,
            maxUnits: maxUnits,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
    }

    function _ratify(Offer memory offer) internal returns (bytes memory ratifierData) {
        bytes32 root = HashLib.hashOffer(offer);
        vm.startPrank(lender);
        MIDNIGHT.setIsAuthorized(SETTER_RATIFIER, true, lender);
        ISetterRatifier(SETTER_RATIFIER).setIsRootRatified(lender, root, true);
        vm.stopPrank();
        return abi.encode(root, uint256(0), new bytes32[](0));
    }

    function _calibratedTick(uint256 timeToMaturity) internal pure returns (uint256) {
        uint256 targetPrice = WAD * WAD / (WAD + APR * timeToMaturity / 365 days);
        return TickLib.priceToTick(targetPrice, TICK_SPACING);
    }

    function _expectedProceeds(uint256 units) internal view returns (uint256) {
        uint256 sellerPrice = TickLib.tickToPrice(tick) - MIDNIGHT.settlementFee(marketId, maturity - block.timestamp);
        return units * sellerPrice / WAD;
    }

    function _fundLender(uint256 amount) internal {
        deal(address(USDC), lender, amount, true);
        vm.prank(lender);
        USDC.approve(address(MIDNIGHT), type(uint256).max);
    }

    function _depositJunior(uint256 amount) internal {
        deal(address(USDC), sponsor, amount, true);
        vm.startPrank(sponsor);
        USDC.approve(address(warehouse), amount);
        warehouse.juniorDeposit(amount);
        vm.stopPrank();
    }

    function _depositAndPledge(uint256 amount) internal {
        receivable.mint(operator, amount);
        vm.startPrank(operator);
        receivable.approve(address(warehouse), amount);
        warehouse.depositReceivables(amount);
        warehouse.pledgeReceivables(market, 0, amount);
        vm.stopPrank();
    }

    /// @dev Opens the canonical $1m pool at a 75% senior advance and pays the originator the full face value.
    function _openWarehouse() internal returns (uint256 proceeds, uint256 junior) {
        proceeds = _expectedProceeds(SENIOR_FACE);
        junior = uint256(POOL_FACE) - proceeds;

        _fundLender(uint256(SENIOR_FACE) + 100_000e6);
        _depositJunior(junior);
        _depositAndPledge(POOL_FACE);

        Offer memory offer = _offer(SENIOR_FACE, keccak256("opening draw"));
        bytes memory ratifierData = _ratify(offer);
        vm.prank(operator);
        uint256 actualProceeds = warehouse.borrow(offer, ratifierData, SENIOR_FACE);
        assertEq(actualProceeds, proceeds, "unexpected opening proceeds");

        vm.prank(operator);
        warehouse.sweepCash(POOL_FACE);
    }
}
