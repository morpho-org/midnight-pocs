// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IMidnight, Market, Offer} from "midnight/interfaces/IMidnight.sol";
import {ISellCallback} from "midnight/interfaces/ICallbacks.sol";

interface IToken {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address receiver, uint256 amount) external returns (bool);
}

/// @notice Borrower-side adapter that atomically moves debt and collateral from one Midnight maturity to the
///         next. It deliberately contains no warehouse accounting: collateral value comes from the configured
///         market's token and oracle, and the borrower operator approves every economic term.
contract RollingBorrower is ISellCallback {
    bytes32 private constant CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");

    IMidnight public immutable midnight;
    address public immutable operator;

    address public rollExecutor;
    bytes32 public marketConfigHash;
    bool public marketConfigured;

    mapping(bytes32 => bool) public isRollAuthorized;
    bytes32 private expectedRoll;

    error OnlyOperator();
    error OnlyRollOperator();
    error OnlyMidnight();
    error MarketAlreadyConfigured();
    error MarketNotConfigured();
    error InvalidMarket();
    error InvalidOffer();
    error InvalidRoll();
    error RollNotAuthorized();
    error UnexpectedRoll();
    error NotOurPosition();
    error ZeroAddress();
    error InvalidContract();

    event MarketConfigured(bytes32 indexed configHash);
    event RollExecutorSet(address indexed executor);
    event RollAuthorizationSet(bytes32 indexed authorization, bool authorized);

    constructor(address _midnight, address _operator) {
        if (_operator == address(0)) revert ZeroAddress();
        if (_midnight.code.length == 0) revert InvalidContract();
        midnight = IMidnight(_midnight);
        operator = _operator;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert OnlyOperator();
        _;
    }

    modifier onlyRollOperator() {
        if (msg.sender != operator && msg.sender != rollExecutor) revert OnlyRollOperator();
        _;
    }

    /// @notice Pin every market field except maturity. Daily rolls may change only that field.
    function configureMarket(Market calldata template) external onlyOperator {
        if (marketConfigured) revert MarketAlreadyConfigured();
        if (template.chainId != block.chainid || template.midnight != address(midnight)) revert InvalidMarket();
        marketConfigHash = _configHash(template);
        marketConfigured = true;
        emit MarketConfigured(marketConfigHash);
    }

    function isSupportedMarket(Market calldata market) external view returns (bool) {
        return marketConfigured && _configHash(market) == marketConfigHash;
    }

    function setRollExecutor(address executor) external onlyOperator {
        rollExecutor = executor;
        emit RollExecutorSet(executor);
    }

    function setRollAuthorization(bytes32 authorization, bool authorized) external onlyOperator {
        isRollAuthorized[authorization] = authorized;
        emit RollAuthorizationSet(authorization, authorized);
    }

    function rollAuthorizationHash(
        Offer calldata newOffer,
        bytes calldata ratifierData,
        uint256 newUnits,
        Market calldata oldMarket,
        uint256 oldUnits,
        uint256 collateralAmount
    ) external pure returns (bytes32) {
        return keccak256(abi.encode(newOffer, ratifierData, newUnits, oldMarket, oldUnits, collateralAmount));
    }

    function approveToken(address token) external onlyOperator {
        require(IToken(token).approve(address(midnight), type(uint256).max), "approval failed");
    }

    function supplyCollateral(Market calldata market, uint256 amount) external onlyOperator {
        _requireSupported(market);
        midnight.supplyCollateral(market, 0, amount, address(this));
    }

    /// @notice Open the first maturity and route proceeds to the borrower's chosen use-of-proceeds account.
    function open(Offer calldata offer, bytes calldata ratifierData, uint256 units, address proceedsReceiver)
        external
        onlyOperator
        returns (uint256 buyerAssets, uint256 sellerAssets)
    {
        _requireSupported(offer.market);
        if (!offer.buy || units == 0 || proceedsReceiver == address(0)) revert InvalidOffer();
        return midnight.take(offer, ratifierData, units, address(this), proceedsReceiver, address(0), "");
    }

    /// @notice Move a position to a later maturity. Delegated callers need borrower consent to these exact
    ///         parameters; the authorization is consumed before entering Midnight.
    function roll(
        Offer calldata newOffer,
        bytes calldata ratifierData,
        uint256 newUnits,
        Market calldata oldMarket,
        uint256 oldUnits,
        uint256 collateralAmount
    ) external onlyRollOperator {
        _requireSupported(newOffer.market);
        _requireSupported(oldMarket);
        if (!newOffer.buy || newUnits == 0 || oldUnits == 0 || collateralAmount == 0) revert InvalidRoll();
        if (newUnits > oldUnits || newOffer.market.maturity <= oldMarket.maturity) revert InvalidRoll();

        if (msg.sender != operator) {
            bytes32 authorization =
                keccak256(abi.encode(newOffer, ratifierData, newUnits, oldMarket, oldUnits, collateralAmount));
            if (!isRollAuthorized[authorization]) revert RollNotAuthorized();
            delete isRollAuthorized[authorization];
            emit RollAuthorizationSet(authorization, false);
        }

        bytes memory data = abi.encode(oldMarket, oldUnits, collateralAmount);
        expectedRoll = keccak256(abi.encode(newOffer.market, newUnits, oldMarket, oldUnits, collateralAmount));
        midnight.take(newOffer, ratifierData, newUnits, address(this), address(this), address(this), data);
        if (expectedRoll != bytes32(0)) revert UnexpectedRoll();
    }

    function repay(Market calldata market, uint256 units) external onlyOperator {
        _requireSupported(market);
        midnight.repay(market, units, address(this), address(0), "");
    }

    function withdrawCollateral(Market calldata market, uint256 amount, address receiver) external onlyOperator {
        _requireSupported(market);
        midnight.withdrawCollateral(market, 0, amount, address(this), receiver);
    }

    function transferToken(address token, address receiver, uint256 amount) external onlyOperator {
        require(IToken(token).transfer(receiver, amount), "transfer failed");
    }

    function onSell(
        bytes32,
        Market memory newMarket,
        uint256,
        uint256 newUnits,
        uint256,
        address seller,
        address receiver,
        bytes memory data
    ) external returns (bytes32) {
        if (msg.sender != address(midnight)) revert OnlyMidnight();
        if (seller != address(this) || receiver != address(this)) revert NotOurPosition();

        (Market memory oldMarket, uint256 oldUnits, uint256 collateralAmount) =
            abi.decode(data, (Market, uint256, uint256));
        if (keccak256(abi.encode(newMarket, newUnits, oldMarket, oldUnits, collateralAmount)) != expectedRoll) {
            revert UnexpectedRoll();
        }
        expectedRoll = bytes32(0);

        midnight.repay(oldMarket, oldUnits, address(this), address(0), "");
        midnight.withdrawCollateral(oldMarket, 0, collateralAmount, address(this), address(this));
        midnight.supplyCollateral(newMarket, 0, collateralAmount, address(this));
        return CALLBACK_SUCCESS;
    }

    function _requireSupported(Market memory market) internal view {
        if (!marketConfigured) revert MarketNotConfigured();
        if (_configHash(market) != marketConfigHash) revert InvalidMarket();
    }

    function _configHash(Market memory market) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                market.chainId,
                market.midnight,
                market.loanToken,
                market.collateralParams,
                market.rcfThreshold,
                market.enterGate,
                market.liquidatorGate
            )
        );
    }
}
