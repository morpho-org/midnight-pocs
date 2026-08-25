// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;
import {IERC20} from "./ERC20.sol";
import {AssetRegistry} from "./AssetRegistry.sol";
import {Offer} from "./Midnight.sol";
import {MockReceivable} from "./test/mocks/MockReceivable.sol";

//fix this  
interface Midnight{
    Offer offer 
    // forget how to do this but read about it.
}

contract WarehouseAccount{
    enum State{
        Active,
        RunOff
    }

    IERC20 public immutable loanToken;
    ReceivableToken public immutable receivableToken;
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
    
    function juniorDeposit(uint256 amount, address token) public onlyJunior {
        require(amount > 0, "Amount must be positive");
        bool success = loanToken.transferFrom(msg.sender, address(this), amount);
        require(success, "Transfer Failed");
    }

    function inAssetRegistry(address token) private {
        reuqire(assetRegistry.inRegistry(token));
    }

    function borrow(Offer offer) public onlyOperator{
        // Approe colalteral via midnight bundles
        // AUthroize midngiht bundles
        // execute borrow bundle
    }

    function repay() public onlyOperator{

    }


    //
    // Read Only Function
    //

    function checkDeficiency() public {

    }

    function sweepCash() {

    }


}