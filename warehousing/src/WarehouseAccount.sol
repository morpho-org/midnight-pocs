// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;
import {IERC20} from "./ERC20.sol";
import {AssetRegistry} from "./AssetRegistry.sol";
import {Offer} from "./Midnight.sol";
//fix this  


contract WarehouseAccount{
    enum State{
        Active,
        Deficiency,
        RunOff
    }

    IERC20 public immutable loanToken;
    address public immutable operator;
    address public immutable juniorProvider;
    AssetRegistry public assetRegistry;


    modifier onlyOperator{
        require(msg.sender == operator);
        _;
    }

    modifier onlyJunior{
        require(msg.sender == juniorProvider);
        _;
    }

    constructor(IERC20 token, address borrower, address _operator, address junior){
        loanToken = token;
        warehouseBorrower = borrower;
        operator = _operator;
        juniorProvider = junior;
    }

    public function juniorDeposit(uint256 amount, address token) onlyJunior{
        require(inAssetRegistry(token), "Not a supported token");

        bool success = IERC20(token).transferFrom(msg.sender, address(this), amount);
        require(success, "Transfer Failed);

    }

    private function inAssetRegistry(address token){

    }
}