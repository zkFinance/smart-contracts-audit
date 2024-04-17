pragma solidity ^0.8.17;

import "../PriceOracle.sol";
import "../EIP20Interface.sol";
import "../ZKErc20.sol";

interface IDIAOracle {
    function getValue(string memory) external view returns (uint128, uint128);
}


contract ZKFinanceDIAOracle is PriceOracle {

    event NewOraclePriceFeed(address newOraclePriceFeed);

    address immutable public oracleUpdater;
    address public oraclePriceFeed;

    constructor() {
        oracleUpdater = msg.sender;
    }

    /**
 * @notice Get the underlying price of a ZKToken asset
     * @dev Implements the PriceOracle interface.
     * @param zkToken The ZKToken address for price retrieval
     * @return Price denominated in USD, with 18 decimals, for the given ZKToken address
     */
    function getUnderlyingPrice(ZKToken zkToken) override view public returns (uint256) {
        string memory symbol;
        uint256 baseUnit;
        if (compareStrings(zkToken.symbol(), "zkETH")) {
            symbol = 'ETH';
            baseUnit = 1e18;
        }
        else {
            address underlying = ZKErc20(address(zkToken)).underlying();
            symbol = EIP20Interface(underlying).symbol();
            baseUnit = 10 **  EIP20Interface(underlying).decimals();

        }
        string memory pair = string.concat(symbol, "/USD");
        (uint256 price, uint256 timestampLastPrice) = IDIAOracle(oraclePriceFeed).getValue(pair);

        // Comptroller needs prices in the format: ${raw price} * 1e(36 - baseUnit)
        // Since the prices in this view have 8 decimals, we must scale them by 1e(36 - 8 - baseUnit)
        return mul(1e28, price) / baseUnit;
    }

    function getPriceInfo(string memory key) external view returns (uint256, uint256) {
        (uint256 price, uint256 timestampLastPrice) = IDIAOracle(oraclePriceFeed).getValue(key);
        return (price, timestampLastPrice);
    }

    function updateOraclePriceFeed(address newOraclePriceFeed) public {
        require(msg.sender == oracleUpdater);
        oraclePriceFeed = newOraclePriceFeed;
        emit NewOraclePriceFeed(newOraclePriceFeed);
    }

    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }

    /// @dev Overflow proof multiplication
    function mul(uint a, uint b) internal pure returns (uint) {
        if (a == 0) return 0;
        uint c = a * b;
        require(c / a == b, "multiplication overflow");
        return c;
    }
}