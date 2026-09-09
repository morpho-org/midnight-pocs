// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IMidnight, Market, Offer} from "midnight/interfaces/IMidnight.sol";
import {IOracle} from "midnight/interfaces/IOracle.sol";
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
    uint256 internal constant BPS = 10_000;
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;

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
    uint256 public immutable seniorCommitment;
    uint256 public immutable availabilityEnd;

    State public state;
    bytes32 public activeMarketId;
    uint256 public collateralIndex;
    bool public marketConfigured;
    address public facilityOracle;
    uint16 public facilityAdvanceRateBps;
    uint256 public marketMaturity;
    address public seniorBeneficiary;
    uint256 public seniorClaim;
    uint256 public juniorDeposited;
    uint256 public juniorWithdrawn;

    event JuniorDeposited(uint256 amount);
    event ReceivablesDeposited(uint256 amount);
    event ReceivablesPledged(bytes32 indexed marketId, uint256 amount);
    event SeniorDrawn(bytes32 indexed marketId, uint256 face, uint256 proceeds);
    event OriginationsFunded(address indexed recipient, uint256 amount);
    event CollectionDeposited(address indexed payer, uint256 amount);
    event ReceivablesSettled(
        address indexed payer,
        address indexed recipient,
        uint256 collectionAmount,
        uint256 seniorRepayment,
        uint256 receivableAmount
    );
    event SeniorRepaid(bytes32 indexed marketId, uint256 units);
    event SeniorLossPaid(address indexed beneficiary, uint256 amount);
    event SeniorLossWaived(address indexed beneficiary, uint256 amount);
    event CollectionsSweptToSenior(bytes32 indexed marketId, uint256 units);
    event ReceivablesReleased(address indexed recipient, uint256 amount);
    event UnpledgedReceivablesReleased(address indexed recipient, uint256 amount);
    event StateChanged(State indexed previousState, State indexed newState);
    event JuniorResidualWithdrawn(address indexed recipient, uint256 amount);

    error OnlyOperator();
    error OnlyJuniorProvider();
    error OnlySeniorBeneficiary();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidContract();
    error InvalidMarket();
    error MarketNotConfigured();
    error MarketAlreadyConfigured();
    error InvalidOffer();
    error InvalidSettlement();
    error InvalidState();
    error FacilityDeficient();
    error FacilityNotDeficient();
    error SeniorOutstanding();
    error UnresolvedSeniorLoss(uint256 seniorClaim, uint256 seniorDebt);
    error InvalidSeniorLossAmount();
    error SeniorCommitmentExceeded(uint256 seniorDebt, uint256 seniorCommitment);
    error InsufficientProceeds(uint256 proceeds, uint256 minimumProceeds);
    error BorrowingBaseExceeded(uint256 seniorDebt, uint256 borrowingBase);

    constructor(
        address _midnight,
        address _loanToken,
        address _receivableToken,
        address _assetRegistry,
        address _operator,
        address _juniorProvider,
        address _cashRecipient,
        uint256 _seniorCommitment,
        uint256 _availabilityEnd
    ) {
        if (
            _midnight == address(0) || _loanToken == address(0) || _receivableToken == address(0)
                || _assetRegistry == address(0) || _operator == address(0) || _juniorProvider == address(0)
                || _cashRecipient == address(0)
        ) revert ZeroAddress();
        if (_seniorCommitment == 0 || _availabilityEnd <= block.timestamp) revert InvalidState();
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
        seniorCommitment = _seniorCommitment;
        availabilityEnd = _availabilityEnd;

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
        if (state != State.Active || facilityExpired()) revert InvalidState();
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
        if (state == State.RunOff || facilityExpired()) revert InvalidState();
        if (amount == 0) revert ZeroAmount();
        if (!assetRegistry.inRegistry(receivableToken)) revert InvalidMarket();
        SafeTransferLib.safeTransferFrom(receivableToken, msg.sender, address(this), amount);
        emit ReceivablesDeposited(amount);
    }

    /// @notice Pledge receivables to one fixed Midnight market. This POC intentionally supports one market.
    function pledgeReceivables(Market calldata market, uint256 index, uint256 amount) external onlyOperator {
        if (state == State.RunOff || facilityExpired()) revert InvalidState();
        if (amount == 0) revert ZeroAmount();
        bytes32 id = _validateMarket(market, index);

        if (!marketConfigured) {
            (bool eligible, uint16 advanceRateBps, address oracle) = assetRegistry.registry(receivableToken);
            if (!eligible || availabilityEnd > market.maturity) revert InvalidMarket();
            activeMarketId = id;
            collateralIndex = index;
            facilityOracle = oracle;
            facilityAdvanceRateBps = advanceRateBps;
            marketMaturity = market.maturity;
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
    function borrow(Offer calldata offer, bytes calldata ratifierData, uint256 units, uint256 minProceeds)
        external
        onlyOperator
        onlyActive
        returns (uint256 proceeds)
    {
        if (units == 0 || !offer.buy || !marketConfigured) revert InvalidOffer();
        if (seniorBeneficiary != address(0) && offer.maker != seniorBeneficiary) revert InvalidOffer();
        uint256 debtAfter = seniorDebt() + units;
        if (debtAfter > seniorCommitment) revert SeniorCommitmentExceeded(debtAfter, seniorCommitment);
        _requireMarket(offer.market);
        _validateMarket(offer.market, collateralIndex);
        _requireCompliant();

        (, proceeds) = midnight.take(offer, ratifierData, units, address(this), address(this), address(0), "");
        if (proceeds < minProceeds) revert InsufficientProceeds(proceeds, minProceeds);
        if (seniorBeneficiary == address(0)) seniorBeneficiary = offer.maker;
        seniorClaim += units;
        _requireCompliant();

        emit SeniorDrawn(activeMarketId, units, proceeds);
    }

    /// @notice Deploy facility cash to the fixed use-of-proceeds account while the borrowing base is sound.
    function fundOriginations(uint256 amount) external onlyOperator onlyActive {
        if (amount == 0) revert ZeroAmount();
        if (!marketConfigured) revert MarketNotConfigured();
        if (!assetRegistry.inRegistry(receivableToken)) revert InvalidMarket();
        _requireCompliant();
        SafeTransferLib.safeTransfer(loanToken, cashRecipient, amount);
        emit OriginationsFunded(cashRecipient, amount);
    }

    /// @notice Add cash to the trapped account after a deficiency, availability end, or run-off.
    function depositCollection(uint256 amount) external {
        if (state == State.Active && !facilityExpired()) revert InvalidState();
        if (amount == 0) revert ZeroAmount();
        SafeTransferLib.safeTransferFrom(loanToken, msg.sender, address(this), amount);
        emit CollectionDeposited(msg.sender, amount);
    }

    /// @notice Atomically receive a takeout or borrower payment, repay senior, and remove the settled receivables.
    function settleReceivables(
        Market calldata market,
        address payer,
        uint256 collectionAmount,
        uint256 seniorRepayment,
        uint256 receivableAmount,
        address recipient
    ) external onlyOperator {
        if (
            payer == address(0) || recipient == address(0) || collectionAmount == 0 || receivableAmount == 0
                || seniorRepayment > collectionAmount
        ) revert InvalidSettlement();
        _requireMarket(market);

        SafeTransferLib.safeTransferFrom(loanToken, payer, address(this), collectionAmount);
        emit CollectionDeposited(payer, collectionAmount);

        if (seniorRepayment > 0) {
            midnight.repay(market, seniorRepayment, address(this), address(0), "");
            seniorClaim -= seniorRepayment;
            emit SeniorRepaid(activeMarketId, seniorRepayment);
        }

        midnight.withdrawCollateral(market, collateralIndex, receivableAmount, address(this), address(this));
        SafeTransferLib.safeTransfer(receivableToken, recipient, receivableAmount);
        _requireCompliant();

        emit ReceivablesReleased(recipient, receivableAmount);
        emit ReceivablesSettled(payer, recipient, collectionAmount, seniorRepayment, receivableAmount);
    }

    /// @notice Apply collected or junior cash to the senior position in every facility state.
    function repaySenior(Market calldata market, uint256 units) external onlyOperator {
        if (units == 0) revert ZeroAmount();
        _requireMarket(market);
        midnight.repay(market, units, address(this), address(0), "");
        seniorClaim -= units;
        emit SeniorRepaid(activeMarketId, units);
    }

    /// @notice During a deficiency or run-off, trap all facility cash and apply as much as possible to senior.
    /// @dev Any cash above the outstanding face remains trapped because `fundOriginations` is Active-only and
    ///      junior cannot withdraw until run-off has begun and senior debt is zero.
    function sweepCollectionsToSenior(Market calldata market) external returns (uint256 units) {
        if (state == State.Active && !facilityExpired()) revert InvalidState();
        _requireMarket(market);

        uint256 cash = cashBalance();
        uint256 debt = seniorDebt();
        units = cash < debt ? cash : debt;
        if (units == 0) revert ZeroAmount();

        midnight.repay(market, units, address(this), address(0), "");
        seniorClaim -= units;
        emit CollectionsSweptToSenior(activeMarketId, units);
    }

    /// @notice Apply trapped warehouse cash directly to a claim that Midnight wrote down during liquidation.
    function paySeniorLoss(uint256 amount) external {
        uint256 loss = unresolvedSeniorLoss();
        if (amount == 0 || amount > loss) revert InvalidSeniorLossAmount();

        seniorClaim -= amount;
        SafeTransferLib.safeTransfer(loanToken, seniorBeneficiary, amount);
        emit SeniorLossPaid(seniorBeneficiary, amount);
    }

    /// @notice Let the fixed senior beneficiary acknowledge an externally settled or waived liquidation loss.
    function waiveSeniorLossClaim(uint256 amount) external {
        if (msg.sender != seniorBeneficiary) revert OnlySeniorBeneficiary();
        uint256 loss = unresolvedSeniorLoss();
        if (amount == 0 || amount > loss) revert InvalidSeniorLossAmount();

        seniorClaim -= amount;
        emit SeniorLossWaived(msg.sender, amount);
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

    /// @notice Recover receivables that were deposited but never pledged once the facility is fully run off.
    function releaseUnpledgedReceivables(uint256 amount, address recipient) external onlyOperator {
        if (state != State.RunOff) revert InvalidState();
        if (seniorClaim != 0) revert SeniorOutstanding();
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        SafeTransferLib.safeTransfer(receivableToken, recipient, amount);
        emit UnpledgedReceivablesReleased(recipient, amount);
    }

    // -------------------------------------------------------------------------- state and waterfall

    /// @notice A public, objective test using the facility's pinned oracle and advance rate.
    function checkDeficiency() public view returns (bool) {
        uint256 debt = seniorDebt();
        return debt > borrowingBase() || seniorClaim != debt;
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
        if (facilityExpired()) revert InvalidState();
        if (!assetRegistry.inRegistry(receivableToken)) revert InvalidMarket();
        if (checkDeficiency()) revert FacilityDeficient();
        _setState(State.Active);
    }

    /// @notice Permanently stop new draws and originations. Collections and senior repayment remain enabled.
    function enterRunOff() external onlyOperator {
        _enterRunOff();
    }

    /// @notice Anyone can close the revolving period after the availability end or market maturity.
    function enterExpiredRunOff() external {
        if (!facilityExpired()) revert InvalidState();
        _enterRunOff();
    }

    function _enterRunOff() internal {
        if (state == State.RunOff) revert InvalidState();
        _setState(State.RunOff);
    }

    /// @notice Junior receives cash only after the facility is in run-off and the senior debt is zero.
    function withdrawJuniorResidual(uint256 amount, address recipient) external onlyJuniorProvider {
        if (state != State.RunOff) revert InvalidState();
        if (seniorClaim != 0) revert SeniorOutstanding();
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
        return unpledgedReceivables() + pledgedReceivables();
    }

    function unpledgedReceivables() public view returns (uint256) {
        return IERC20Like(receivableToken).balanceOf(address(this));
    }

    function pledgedReceivables() public view returns (uint256) {
        return marketConfigured ? midnight.collateral(activeMarketId, address(this), collateralIndex) : 0;
    }

    function collateralValue() public view returns (uint256) {
        if (!marketConfigured) return assetRegistry.value(receivableToken, totalReceivables());
        return totalReceivables() * IOracle(facilityOracle).price() / ORACLE_PRICE_SCALE;
    }

    function borrowingBase() public view returns (uint256) {
        if (!marketConfigured || !assetRegistry.inRegistry(receivableToken)) return 0;
        uint256 pledgedValue = pledgedReceivables() * IOracle(facilityOracle).price() / ORACLE_PRICE_SCALE;
        return pledgedValue * facilityAdvanceRateBps / BPS;
    }

    function seniorDebt() public view returns (uint256) {
        return marketConfigured ? midnight.debt(activeMarketId, address(this)) : 0;
    }

    function unresolvedSeniorLoss() public view returns (uint256) {
        uint256 debt = seniorDebt();
        return seniorClaim > debt ? seniorClaim - debt : 0;
    }

    function equity() external view returns (uint256) {
        uint256 assets = cashBalance() + collateralValue();
        return assets > seniorClaim ? assets - seniorClaim : 0;
    }

    function availableToDraw() external view returns (uint256) {
        if (facilityExpired() || seniorClaim != seniorDebt()) return 0;
        uint256 base = borrowingBase();
        uint256 debt = seniorDebt();
        uint256 limit = base < seniorCommitment ? base : seniorCommitment;
        return limit > debt ? limit - debt : 0;
    }

    function facilityExpired() public view returns (bool) {
        return block.timestamp >= availabilityEnd || (marketConfigured && block.timestamp >= marketMaturity);
    }

    /// @notice Midnight enter-gate hook: lenders may enter, but this market has exactly one borrower.
    function canIncreaseCredit(address) external pure returns (bool) {
        return true;
    }

    /// @notice Midnight enter-gate hook that isolates senior credit from unrelated warehouse borrowers.
    function canIncreaseDebt(address account) external view returns (bool) {
        return account == address(this);
    }

    // -------------------------------------------------------------------------- internal validation

    function _validateMarket(Market calldata market, uint256 index) internal view returns (bytes32) {
        if (
            market.chainId != block.chainid || market.midnight != address(midnight) || market.loanToken != loanToken
                || market.enterGate != address(this) || index >= market.collateralParams.length
        ) revert InvalidMarket();

        (bool eligible, uint16 advanceRateBps, address oracle) = assetRegistry.registry(receivableToken);
        if (marketConfigured) {
            advanceRateBps = facilityAdvanceRateBps;
            oracle = facilityOracle;
        }
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
        if (seniorClaim != debt) revert UnresolvedSeniorLoss(seniorClaim, debt);
        uint256 base = borrowingBase();
        if (debt > base) revert BorrowingBaseExceeded(debt, base);
    }

    function _setState(State newState) internal {
        State previous = state;
        state = newState;
        emit StateChanged(previous, newState);
    }
}
