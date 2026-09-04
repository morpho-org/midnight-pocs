// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Minimal tokenized receivable used by the warehouse demonstration.
contract MockReceivable {
    string public constant name = "Mock Receivable";
    string public constant symbol = "mREC";
    uint8 public constant decimals = 6;

    address public immutable issuer;
    uint256 public totalSupply;
    mapping(address account => uint256 balance) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    constructor(address _issuer) {
        issuer = _issuer;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == issuer, "only issuer");
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        require(msg.sender == issuer, "only issuer");
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice Mutable valuation lets tests demonstrate a borrowing-base deficiency and its cure.
contract MockReceivableOracle {
    address public immutable administrator;
    uint256 public price;

    constructor(address _administrator, uint256 _price) {
        administrator = _administrator;
        price = _price;
    }

    function setPrice(uint256 newPrice) external {
        require(msg.sender == administrator, "only administrator");
        price = newPrice;
    }
}
