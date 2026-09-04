// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IMidnight, Market, Offer} from "midnight/interfaces/IMidnight.sol";
import {IdLib} from "midnight/libraries/IdLib.sol";
import {SafeTransferLib} from "midnight/libraries/SafeTransferLib.sol";
import {AssetRegistry} from "./AssetRegistry.sol";

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title WarehouseAccount
/// @notice A deliberately small warehouse SPV: junior cash and one eligible receivable pool support a senior
///         Midnight draw, the operator deploys that cash, collections repay senior first, and junior receives
///         only the residual in run-off.
contract WarehouseAccount {
    enum State {
        Active,
        Deficiency,
        RunOff
    }

    IMidnight public immutable midnight;
    address public immutable loanToken;
    address public immutable receivableToken;
    AssetRegistry public immutable assetRegistry;
    address public immutable operator;
    address public immutable juniorProvider;
    address public immutable cashRecipient;

    State public state;
    bytes32 public activeMarketId;
    uint256 public collateralIndex;
    bool public marketConfigured;
    uint256 public juniorDeposited;
    uint256 public juniorWithdrawn;

    event JuniorDeposited(uint256 amount);
    event ReceivablesDeposited(uint256 amount);
    event ReceivablesPledged(bytes32 indexed marketId, uint256 amount);
    event SeniorDrawn(bytes32 indexed marketId, uint256 face, uint256 proceeds);
    event CashSwept(address indexed recipient, uint256 amount);
    event CollectionDeposited(address indexed payer, uint256 amount);
    event SeniorRepaid(bytes32 indexed marketId, uint256 units);
    event ReceivablesReleased(address indexed recipient, uint256 amount);
    event StateChanged(State indexed previousState, State indexed newState);
    event JuniorResidualWithdrawn(address indexed recipient, uint256 amount);

    error OnlyOperator();
    error OnlyJuniorProvider();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidContract();
    error InvalidMarket();
    error MarketNotConfigured();
    error MarketAlreadyConfigured();
    error InvalidOffer();
    error InvalidState();
    error FacilityDeficient();
    error FacilityNotDeficient();
    error SeniorOutstanding();
    error BorrowingBaseExceeded(uint256 seniorDebt, uint256 borrowingBase);

    constructor(
        address _midnight,
        address _loanToken,
        address _receivableToken,
        address _assetRegistry,
        address _operator,
        address _juniorProvider,
        address _cashRecipient
    ) {
        if (
            _midnight == address(0) || _loanToken == address(0) || _receivableToken == address(0)
                || _assetRegistry == address(0) || _operator == address(0) || _juniorProvider == address(0)
                || _cashRecipient == address(0)
        ) revert ZeroAddress();
        if (
            _midnight.code.length == 0 || _loanToken.code.length == 0 || _receivableToken.code.length == 0
                || _assetRegistry.code.length == 0
        ) revert InvalidContract();

        midnight = IMidnight(_midnight);
        loanToken = _loanToken;
        receivableToken = _receivableToken;
        assetRegistry = AssetRegistry(_assetRegistry);
        operator = _operator;
        juniorProvider = _juniorProvider;
        cashRecipient = _cashRecipient;

        require(IERC20Like(_loanToken).approve(_midnight, type(uint256).max), "loan approval failed");
        require(IERC20Like(_receivableToken).approve(_midnight, type(uint256).max), "collateral approval failed");
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert OnlyOperator();
        _;
    }

    modifier onlyJuniorProvider() {
        if (msg.sender != juniorProvider) revert OnlyJuniorProvider();
        _;
    }

    modifier onlyActive() {
        if (state != State.Active) revert InvalidState();
        _;
    }

    // -------------------------------------------------------------------------- funding and collateral

    /// @notice First-loss cash supplied by the named junior provider. Deposits remain open during a deficiency
    ///         so junior can fund a senior paydown and cure the facility.
    function juniorDeposit(uint256 amount) external onlyJuniorProvider {
        if (amount == 0) revert ZeroAmount();
        SafeTransferLib.safeTransferFrom(loanToken, msg.sender, address(this), amount);
        juniorDeposited += amount;
        emit JuniorDeposited(amount);
    }

    /// @notice Move newly originated, tokenized receivables into the SPV. Disabled only after run-off begins.
    function depositReceivables(uint256 amount) external onlyOperator {
        if (state == State.RunOff) revert InvalidState();
        if (amount == 0) revert ZeroAmount();
        if (!assetRegistry.inRegistry(receivableToken)) revert InvalidMarket();
        SafeTransferLib.safeTransferFrom(receivableToken, msg.sender, address(this), amount);
        emit ReceivablesDeposited(amount);
    }

    /// @notice Pledge receivables to one fixed Midnight market. This POC intentionally supports one market.
    function pledgeReceivables(Market calldata market, uint256 index, uint256 amount) external onlyOperator {
        if (state == State.RunOff) revert InvalidState();
        if (amount == 0) revert ZeroAmount();
        bytes32 id = _validateMarket(market, index);

        if (!marketConfigured) {
            activeMarketId = id;
            collateralIndex = index;
            marketConfigured = true;
        } else if (id != activeMarketId || index != collateralIndex) {
            revert MarketAlreadyConfigured();
        }

        midnight.supplyCollateral(market, index, amount, address(this));
        emit ReceivablesPledged(id, amount);
    }

    // -------------------------------------------------------------------------- senior funding and cash

    /// @notice Take the lender's buy offer. The debt face, rather than discounted proceeds, is capped by the
    ///         facility borrowing base.
    function borrow(Offer calldata offer, bytes calldata ratifierData, uint256 units)
        external
        onlyOperator
        onlyActive
        returns (uint256 proceeds)
    {
        if (units == 0 || !offer.buy || !marketConfigured) revert InvalidOffer();
        _requireMarket(offer.market);
        _validateMarket(offer.market, collateralIndex);
        _requireCompliant();

        (, proceeds) = midnight.take(offer, ratifierData, units, address(this), address(this), address(0), "");
        _requireCompliant();

        emit SeniorDrawn(activeMarketId, units, proceeds);
    }

    /// @notice Deploy facility cash to the fixed use-of-proceeds account while the borrowing base is sound.
    function sweepCash(uint256 amount) external onlyOperator onlyActive {
        if (amount == 0) revert ZeroAmount();
        if (!marketConfigured) revert MarketNotConfigured();
        _requireCompliant();
        SafeTransferLib.safeTransfer(loanToken, cashRecipient, amount);
        emit CashSwept(cashRecipient, amount);
    }

    /// @notice Record borrower/takeout collections as actual cash. No authored accounting entry is used.
    function depositCollection(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        SafeTransferLib.safeTransferFrom(loanToken, msg.sender, address(this), amount);
        emit CollectionDeposited(msg.sender, amount);
    }

    /// @notice Apply collected or junior cash to the senior position in every facility state.
    function repaySenior(Market calldata market, uint256 units) external onlyOperator {
        if (units == 0) revert ZeroAmount();
        _requireMarket(market);
        midnight.repay(market, units, address(this), address(0), "");
        emit SeniorRepaid(activeMarketId, units);
    }

    /// @notice Release settled receivables only when the remaining pool still supports all senior debt.
    function releaseReceivables(Market calldata market, uint256 amount, address recipient) external onlyOperator {
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        _requireMarket(market);

        midnight.withdrawCollateral(market, collateralIndex, amount, address(this), address(this));
        SafeTransferLib.safeTransfer(receivableToken, recipient, amount);
        _requireCompliant();

        emit ReceivablesReleased(recipient, amount);
    }

    // -------------------------------------------------------------------------- state and waterfall

    /// @notice A public, objective test using the registry's current oracle price and advance rate.
    function checkDeficiency() public view returns (bool) {
        return seniorDebt() > borrowingBase();
    }

    /// @notice Anyone can freeze new draws and outward cash sweeps once the borrowing base is breached.
    function flagDeficiency() external {
        if (state != State.Active) revert InvalidState();
        if (!checkDeficiency()) revert FacilityNotDeficient();
        _setState(State.Deficiency);
    }

    /// @notice Return to active operation after added collateral, a senior paydown, or a valuation recovery.
    function cureDeficiency() external onlyOperator {
        if (state != State.Deficiency) revert InvalidState();
        if (checkDeficiency()) revert FacilityDeficient();
        _setState(State.Active);
    }

    /// @notice Permanently stop new draws and originations. Collections and senior repayment remain enabled.
    function enterRunOff() external onlyOperator {
        if (state == State.RunOff) revert InvalidState();
        _setState(State.RunOff);
    }

    /// @notice Junior receives cash only after the facility is in run-off and the senior debt is zero.
    function withdrawJuniorResidual(uint256 amount, address recipient) external onlyJuniorProvider {
        if (state != State.RunOff) revert InvalidState();
        if (seniorDebt() != 0) revert SeniorOutstanding();
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        juniorWithdrawn += amount;
        SafeTransferLib.safeTransfer(loanToken, recipient, amount);
        emit JuniorResidualWithdrawn(recipient, amount);
    }

    // -------------------------------------------------------------------------- live accounting views

    function cashBalance() public view returns (uint256) {
        return IERC20Like(loanToken).balanceOf(address(this));
    }

    function totalReceivables() public view returns (uint256 total) {
        total = IERC20Like(receivableToken).balanceOf(address(this));
        if (marketConfigured) total += midnight.collateral(activeMarketId, address(this), collateralIndex);
    }

    function collateralValue() public view returns (uint256) {
        return assetRegistry.value(receivableToken, totalReceivables());
    }

    function borrowingBase() public view returns (uint256) {
        return assetRegistry.borrowingBase(receivableToken, totalReceivables());
    }

    function seniorDebt() public view returns (uint256) {
        return marketConfigured ? midnight.debt(activeMarketId, address(this)) : 0;
    }

    function equity() external view returns (uint256) {
        uint256 assets = cashBalance() + collateralValue();
        uint256 debt = seniorDebt();
        return assets > debt ? assets - debt : 0;
    }

    function availableToDraw() external view returns (uint256) {
        uint256 base = borrowingBase();
        uint256 debt = seniorDebt();
        return base > debt ? base - debt : 0;
    }

    // -------------------------------------------------------------------------- internal validation

    function _validateMarket(Market calldata market, uint256 index) internal view returns (bytes32) {
        if (
            market.chainId != block.chainid || market.midnight != address(midnight) || market.loanToken != loanToken
                || index >= market.collateralParams.length
        ) revert InvalidMarket();

        (bool eligible, uint16 advanceRateBps, address oracle) = assetRegistry.registry(receivableToken);
        if (
            !eligible || market.collateralParams[index].token != receivableToken
                || market.collateralParams[index].oracle != oracle
                || market.collateralParams[index].lltv < uint256(advanceRateBps) * 1e14
        ) revert InvalidMarket();

        return IdLib.toId(market);
    }

    function _requireMarket(Market calldata market) internal view {
        if (!marketConfigured) revert MarketNotConfigured();
        if (IdLib.toId(market) != activeMarketId) revert InvalidMarket();
    }

    function _requireCompliant() internal view {
        uint256 debt = seniorDebt();
        uint256 base = borrowingBase();
        if (debt > base) revert BorrowingBaseExceeded(debt, base);
    }

    function _setState(State newState) internal {
        State previous = state;
        state = newState;
        emit StateChanged(previous, newState);
    }
}
