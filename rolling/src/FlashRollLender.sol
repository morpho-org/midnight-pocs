// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IMidnight, Market, Offer} from "midnight/interfaces/IMidnight.sol";
import {ISetterRatifier} from "midnight/ratifiers/interfaces/ISetterRatifier.sol";
import {RollingBorrower} from "./RollingBorrower.sol";

interface IMorphoBlue {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

interface ILoanAsset {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address receiver, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Lender of record that bridges an entire Midnight maturity roll with a Morpho Blue flash loan.
///         It needs no idle principal buffer: old lender credit is released and withdrawn before Blue pulls
///         the flash principal back.
contract FlashRollLender {
    struct RollParams {
        Offer newOffer;
        bytes ratifierData;
        Market oldMarket;
        uint256 units;
        uint256 collateralAmount;
    }

    IMorphoBlue public immutable morphoBlue;
    IMidnight public immutable midnight;
    ILoanAsset public immutable asset;
    ISetterRatifier public immutable setterRatifier;
    RollingBorrower public immutable borrower;

    address public immutable operator;
    address public immutable capitalOwner;
    address public beneficiary;

    bytes32 private expectedCallback;

    error OnlyOperator();
    error OnlyCapitalOwner();
    error OnlyOperatorOrCapitalOwner();
    error OnlyMorphoBlue();
    error UnexpectedCallback();
    error InvalidOffer();
    error InvalidRoll();
    error ZeroAddress();
    error InvalidContract();

    event RootRatified(bytes32 indexed root, bool ratified);
    event FlashRollExecuted(bytes32 indexed callbackHash, uint256 units, uint256 carry);
    event CreditWithdrawn(uint256 units);
    event BeneficiarySet(address indexed beneficiary);
    event AssetsSwept(address indexed beneficiary, uint256 assets);

    constructor(
        address _morphoBlue,
        address _midnight,
        address _asset,
        address _setterRatifier,
        address _borrower,
        address _operator,
        address _capitalOwner
    ) {
        if (_operator == address(0) || _capitalOwner == address(0) || _capitalOwner == address(this)) {
            revert ZeroAddress();
        }
        if (
            _morphoBlue.code.length == 0 || _midnight.code.length == 0 || _asset.code.length == 0
                || _setterRatifier.code.length == 0 || _borrower.code.length == 0
        ) revert InvalidContract();
        morphoBlue = IMorphoBlue(_morphoBlue);
        midnight = IMidnight(_midnight);
        asset = ILoanAsset(_asset);
        setterRatifier = ISetterRatifier(_setterRatifier);
        borrower = RollingBorrower(_borrower);
        operator = _operator;
        capitalOwner = _capitalOwner;
        beneficiary = _capitalOwner;

        midnight.setIsAuthorized(_setterRatifier, true, address(this));
        require(asset.approve(_midnight, type(uint256).max), "Midnight approval failed");
        require(asset.approve(_morphoBlue, type(uint256).max), "Morpho approval failed");
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert OnlyOperator();
        _;
    }

    modifier onlyCapitalOwner() {
        if (msg.sender != capitalOwner) revert OnlyCapitalOwner();
        _;
    }

    modifier onlyOperatorOrCapitalOwner() {
        if (msg.sender != operator && msg.sender != capitalOwner) revert OnlyOperatorOrCapitalOwner();
        _;
    }

    /// @notice Capital approval is separate from execution authority. The operator cannot ratify unrelated
    ///         offers against this contract's Midnight allowance.
    function setRootRatified(bytes32 root, bool ratified) external onlyCapitalOwner {
        setterRatifier.setIsRootRatified(address(this), root, ratified);
        emit RootRatified(root, ratified);
    }

    function executeRoll(RollParams calldata params) external onlyOperator {
        if (
            !params.newOffer.buy || params.newOffer.maker != address(this)
                || params.newOffer.market.loanToken != address(asset) || params.oldMarket.loanToken != address(asset)
        ) revert InvalidOffer();
        if (
            params.units == 0 || params.collateralAmount == 0
                || params.newOffer.market.maturity <= params.oldMarket.maturity
        ) revert InvalidRoll();
        if (expectedCallback != bytes32(0)) revert UnexpectedCallback();

        bytes memory data = abi.encode(params);
        expectedCallback = keccak256(data);
        morphoBlue.flashLoan(address(asset), params.units, data);
        if (expectedCallback != bytes32(0)) revert UnexpectedCallback();
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        if (msg.sender != address(morphoBlue)) revert OnlyMorphoBlue();
        if (expectedCallback == bytes32(0) || keccak256(data) != expectedCallback) revert UnexpectedCallback();

        RollParams memory params = abi.decode(data, (RollParams));
        if (assets != params.units) revert UnexpectedCallback();
        bytes32 callbackHash = expectedCallback;
        expectedCallback = bytes32(0);

        uint256 balanceBefore = asset.balanceOf(address(this)) - assets;
        borrower.roll(
            params.newOffer, params.ratifierData, params.units, params.oldMarket, params.units, params.collateralAmount
        );

        midnight.withdraw(params.oldMarket, params.units, address(this), address(this));

        // Blue pulls `assets` after this callback; funds above the pre-roll balance and that principal are carry.
        uint256 carry = asset.balanceOf(address(this)) - balanceBefore - assets;
        emit FlashRollExecuted(callbackHash, params.units, carry);
    }

    function withdrawCredit(Market calldata market, uint256 units) external onlyOperatorOrCapitalOwner {
        midnight.withdraw(market, units, address(this), address(this));
        emit CreditWithdrawn(units);
    }

    function setBeneficiary(address newBeneficiary) external onlyCapitalOwner {
        if (newBeneficiary == address(0) || newBeneficiary == address(this)) revert ZeroAddress();
        beneficiary = newBeneficiary;
        emit BeneficiarySet(newBeneficiary);
    }

    function sweepAsset(uint256 assets) external onlyOperatorOrCapitalOwner {
        require(asset.transfer(beneficiary, assets), "Beneficiary transfer failed");
        emit AssetsSwept(beneficiary, assets);
    }
}
