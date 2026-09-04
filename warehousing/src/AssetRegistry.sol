// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IOracle} from "midnight/interfaces/IOracle.sol";

/// @title AssetRegistry
/// @notice Administrator-maintained eligibility and borrowing-base terms for warehouse collateral.
/// @dev Prices use Midnight's 1e36 oracle scale. The POC assumes the receivable and loan token use the same
///      decimals; production facilities would need explicit decimal normalization and independent valuation.
contract AssetRegistry {
    uint256 public constant BPS = 10_000;
    uint256 public constant ORACLE_PRICE_SCALE = 1e36;

    struct AssetConfig {
        bool eligible;
        uint16 advanceRateBps;
        address oracle;
    }

    address public immutable operator;
    mapping(address asset => AssetConfig config) public registry;

    event AssetConfigured(address indexed asset, address indexed oracle, uint256 advanceRateBps, bool eligible);

    error OnlyOperator();
    error ZeroAddress();
    error InvalidAdvanceRate();
    error InvalidOracle();
    error AssetNotConfigured();

    constructor(address _operator) {
        if (_operator == address(0)) revert ZeroAddress();
        operator = _operator;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert OnlyOperator();
        _;
    }

    /// @notice Add an eligible asset or update its valuation terms. Setting `eligible` false disables new use.
    function setAsset(address asset, address oracle, uint16 advanceRateBps, bool eligible) external onlyOperator {
        if (asset == address(0)) revert ZeroAddress();
        if (advanceRateBps > BPS) revert InvalidAdvanceRate();
        if (eligible && (oracle == address(0) || oracle.code.length == 0)) revert InvalidOracle();

        registry[asset] = AssetConfig({eligible: eligible, advanceRateBps: advanceRateBps, oracle: oracle});
        emit AssetConfigured(asset, oracle, advanceRateBps, eligible);
    }

    function inRegistry(address asset) public view returns (bool) {
        return registry[asset].eligible;
    }

    function price(address asset) public view returns (uint256) {
        AssetConfig memory config = registry[asset];
        if (config.oracle == address(0)) revert AssetNotConfigured();
        return IOracle(config.oracle).price();
    }

    /// @notice Gross collateral value in loan-token units.
    function value(address asset, uint256 amount) public view returns (uint256) {
        return amount * price(asset) / ORACLE_PRICE_SCALE;
    }

    /// @notice Maximum senior face supported by `amount` under the configured advance rate.
    function borrowingBase(address asset, uint256 amount) external view returns (uint256) {
        AssetConfig memory config = registry[asset];
        if (!config.eligible) return 0;
        return value(asset, amount) * config.advanceRateBps / BPS;
    }
}
