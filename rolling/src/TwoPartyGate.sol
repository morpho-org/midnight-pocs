// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IEnterGate, ILiquidatorGate} from "midnight/interfaces/IGate.sol";

/// @notice Minimal Midnight gate for a single lender, borrower and liquidator.
contract TwoPartyGate is IEnterGate, ILiquidatorGate {
    address public immutable lender;
    address public immutable borrower;
    address public immutable liquidator;

    error ZeroAddress();

    constructor(address _lender, address _borrower, address _liquidator) {
        if (_lender == address(0) || _borrower == address(0) || _liquidator == address(0)) revert ZeroAddress();
        lender = _lender;
        borrower = _borrower;
        liquidator = _liquidator;
    }

    function canIncreaseCredit(address account) external view returns (bool) {
        return account == lender;
    }

    function canIncreaseDebt(address account) external view returns (bool) {
        return account == borrower;
    }

    function canLiquidate(address account) external view returns (bool) {
        return account == liquidator;
    }
}
