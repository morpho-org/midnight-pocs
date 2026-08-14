
contract AssetRegistry{
    mapping(address => bool) public registry;
    address public immutable operator;

    modifier onlyOperator(){
        require(msg.sender == operator);
        _;
    }

    constructor(address _operator){
        operator = _operator;
    }
    
    function inRegistry(address token) public view returns (bool) {
        return registry[token];
    }

    function addToRegistry(address token) public onlyOperator {
        require (registry[token] != true, "Token already in registry");
        registry[token] = true;
    }

    function price(address asset) public view returns (uint256){
        return 1;
        //For POC, this will just return $1. However, this can be made more advanced using tokenized 
        //offchain receivables or some other methodogy.
    }

    function advanceRate(address asset) public view returns (uint256){
        return 7_500;
        //Same as above.
    }
}