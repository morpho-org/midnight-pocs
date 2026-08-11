// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IMidnight, Market, Offer} from "midnight/interfaces/IMidnight.sol";
import {ISellCallback} from "midnight/interfaces/ICallbacks.sol";
import {IOracle} from "midnight/interfaces/IOracle.sol";
import {IdLib} from "midnight/libraries/IdLib.sol";
import {TickLib} from "midnight/libraries/TickLib.sol";
import {SafeTransferLib} from "midnight/libraries/SafeTransferLib.sol";
import {UtilsLib} from "midnight/libraries/UtilsLib.sol";

interface IERC20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Permissionless singleton that atomically rolls `msg.sender`'s Midnight position from one maturity to
///         another. One contract per chain; every user shares the same instance.
///
///         Setup, done once per user:
///           1. `MIDNIGHT.setIsAuthorized(address(roller), true, user)` — lets the roller act on the user's
///              position inside `onSell`.
///
///         Setup, done once per (loan + collateral) token pair (anyone can call):
///           2. `roller.setApprovalMax(token)` — primes the roller's Midnight allowance for that token.
///
///         The interest gap between the offer proceeds and the old face is closed by *borrowing more units* on
///         the new market — enough so the discounted advance covers the full old face. The caller supplies
///         `maxNewUnits` as a ceiling so a bad offer price cannot silently inflate their debt.
contract MidnightRoller is ISellCallback {
    bytes32 private constant CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");
    uint256 private constant WAD = 1e18;
    uint256 private constant ORACLE_PRICE_SCALE = 1e36;

    IMidnight public immutable MIDNIGHT;

    /// @dev The borrower whose position is being rolled during the current `roll` call. Read back inside
    ///      `onSell` so the callback closes the old position for the exact caller of `roll`, never an address
    ///      supplied by the callback data.
    address private transient _borrower;

    /// @dev Guards `onSell` against callbacks not originated by this contract's active `roll`. The commitment
    ///      binds the borrower, target market, replacement units and migration data.
    bytes32 private transient _expectedCallback;

    struct RollParams {
        Market oldMarket;
        uint256 oldCollateralIndex;
        uint256 newCollateralIndex;
        uint256 collateralAmount;
        uint256 oldUnits;
        uint256 maxNewUnits;
        uint256 maxLtv; // WAD-scaled ceiling on post-roll debt / collateral value. 0 disables the check.
        Offer newOffer;
        bytes ratifierData;
    }

    error OnlyMidnight();
    error UnexpectedCallback();
    error LoanTokenMismatch();
    error WrongMidnight();
    error InvalidMaturity();
    error CollateralMismatch();
    error CollateralIndexOutOfBounds();
    error NotABuyOffer();
    error InvalidRoll();
    error TargetDebtNotZero();
    error PriceTooLow(uint256 requiredUnits, uint256 maxUnits);
    error LtvTooHigh(uint256 actualLtv, uint256 maxLtv);
    error InvalidContract();

    event Rolled(
        address indexed user,
        bytes32 indexed oldMarketId,
        bytes32 indexed newMarketId,
        uint256 oldUnits,
        uint256 newUnits,
        uint256 collateralAmount
    );

    constructor(address _midnight) {
        if (_midnight.code.length == 0) revert InvalidContract();
        MIDNIGHT = IMidnight(_midnight);
    }

    /// @notice Approve Midnight to spend `token` from this contract without limit. Idempotent, permissionless.
    ///         Required once per loan-token and once per collateral-token before that token can be rolled.
    function setApprovalMax(address token) external {
        require(IERC20Approve(token).approve(address(MIDNIGHT), type(uint256).max), "approve failed");
    }

    /// @notice Roll `msg.sender`'s position from `p.oldMarket` to `p.newOffer.market`. Called by the borrower
    ///         directly. The caller must have granted Midnight-level authorization to this contract beforehand.
    /// @return newUnits The units taken on the new market — the smallest amount whose proceeds cover `oldUnits`.
    function roll(RollParams calldata p) external returns (uint256 newUnits) {
        if (_expectedCallback != bytes32(0) || _borrower != address(0)) revert UnexpectedCallback();

        Market calldata newMarket = p.newOffer.market;

        if (p.oldMarket.midnight != address(MIDNIGHT) || newMarket.midnight != address(MIDNIGHT)) {
            revert WrongMidnight();
        }
        if (p.oldMarket.loanToken != newMarket.loanToken) revert LoanTokenMismatch();
        if (newMarket.maturity <= p.oldMarket.maturity) revert InvalidMaturity();
        if (
            p.oldCollateralIndex >= p.oldMarket.collateralParams.length
                || p.newCollateralIndex >= newMarket.collateralParams.length
        ) revert CollateralIndexOutOfBounds();
        if (
            p.oldMarket.collateralParams[p.oldCollateralIndex].token
                != newMarket.collateralParams[p.newCollateralIndex].token
        ) revert CollateralMismatch();
        if (!p.newOffer.buy) revert NotABuyOffer();
        if (p.oldUnits == 0 || p.collateralAmount == 0 || p.maxNewUnits == 0) revert InvalidRoll();

        // Ensure the new market is created so its settlement-fee state is readable.
        bytes32 newMarketId = MIDNIGHT.touchMarket(newMarket);
        if (MIDNIGHT.debt(newMarketId, msg.sender) != 0) revert TargetDebtNotZero();

        newUnits = _minUnitsForFace(p.oldUnits, p.newOffer);
        if (newUnits > p.maxNewUnits) revert PriceTooLow(newUnits, p.maxNewUnits);

        if (p.maxLtv != 0) {
            uint256 price = IOracle(newMarket.collateralParams[p.newCollateralIndex].oracle).price();
            uint256 collateralValue = p.collateralAmount * price / ORACLE_PRICE_SCALE;
            uint256 actualLtv = collateralValue == 0 ? type(uint256).max : newUnits * WAD / collateralValue;
            if (actualLtv > p.maxLtv) revert LtvTooHigh(actualLtv, p.maxLtv);
        }

        bytes memory data =
            abi.encode(p.oldMarket, p.oldCollateralIndex, p.newCollateralIndex, p.collateralAmount, p.oldUnits);
        _borrower = msg.sender;
        _expectedCallback = keccak256(abi.encode(msg.sender, newMarket, newUnits, data));

        MIDNIGHT.take(
            p.newOffer,
            p.ratifierData,
            newUnits,
            msg.sender, // taker: the user is the position holder
            address(this), // proceeds land here so onSell can spend them repaying the old face
            address(this), // takerCallback: onSell fires on this contract
            data
        );
        if (_expectedCallback != bytes32(0) || _borrower != address(0)) revert UnexpectedCallback();

        emit Rolled(
            msg.sender, IdLib.toId(p.oldMarket), IdLib.toId(newMarket), p.oldUnits, newUnits, p.collateralAmount
        );
    }

    /// @inheritdoc ISellCallback
    function onSell(
        bytes32 newMarketId,
        Market memory newMarket,
        uint256 sellerAssets,
        uint256 newUnits,
        uint256,
        address seller,
        address receiver,
        bytes memory data
    ) external returns (bytes32) {
        if (msg.sender != address(MIDNIGHT)) revert OnlyMidnight();
        address user = _borrower;
        if (
            user == address(0) || seller != user || receiver != address(this) || newMarketId != IdLib.toId(newMarket)
                || _expectedCallback != keccak256(abi.encode(user, newMarket, newUnits, data))
        ) revert UnexpectedCallback();
        _expectedCallback = bytes32(0);
        _borrower = address(0);

        (
            Market memory oldMarket,
            uint256 oldColIndex,
            uint256 newColIndex,
            uint256 collateralAmount,
            uint256 oldUnits
        ) = abi.decode(data, (Market, uint256, uint256, uint256, uint256));

        MIDNIGHT.repay(oldMarket, oldUnits, user, address(0), "");
        MIDNIGHT.withdrawCollateral(oldMarket, oldColIndex, collateralAmount, user, address(this));
        MIDNIGHT.supplyCollateral(newMarket, newColIndex, collateralAmount, user);

        uint256 dust = sellerAssets - oldUnits;
        if (dust > 0) SafeTransferLib.safeTransfer(oldMarket.loanToken, user, dust);

        return CALLBACK_SUCCESS;
    }

    /// @dev Smallest `units` such that `units * (offerPrice - settlementFee) / WAD >= face`.
    function _minUnitsForFace(uint256 face, Offer calldata offer) internal view returns (uint256) {
        uint256 offerPrice = TickLib.tickToPrice(offer.tick);
        uint256 timeToMaturity = UtilsLib.zeroFloorSub(offer.market.maturity, block.timestamp);
        uint256 fee = MIDNIGHT.settlementFee(IdLib.toId(offer.market), timeToMaturity);
        uint256 sellerPrice = offerPrice - fee;
        return (face * WAD + sellerPrice - 1) / sellerPrice;
    }
}
