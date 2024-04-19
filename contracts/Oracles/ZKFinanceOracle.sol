pragma solidity 0.8.19;

import "../PriceOracle.sol";
import "../EIP20Interface.sol";
import "../ZKErc20.sol";

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "./ChainlinkAggregator.sol";
//import "hardhat/console.sol";

interface IDIAOracle {
    function getValue(string memory) external view returns (uint128, uint128);
}

contract ZKFinanceOracle is PriceOracle {

    ChainlinkAggregator public immutable chainlinkAggregator;
    address public immutable diaOraclePriceFeed;

    mapping(string => uint256) public lastKnownPrice;

    constructor(address _diaOraclePriceFeed) {
        chainlinkAggregator = new ChainlinkAggregator();
        diaOraclePriceFeed = _diaOraclePriceFeed;

        initializePriceForPair("ETH/USD");
        initializePriceForPair("USDT/USD");
        initializePriceForPair("BTC/USD");
        initializePriceForPair("WBTC/USD");
        initializePriceForPair("USDC/USD");
        initializePriceForPair("DAI/USD");
        initializePriceForPair("BUSD/USD");
    }

    function initializePriceForPair(string memory pair) internal {
        (uint128 diaPrice, , int256 chainlinkPrice,) = fetchPrice(pair);

        if (chainlinkPrice > 0) {
            lastKnownPrice[pair] = uint256(chainlinkPrice);
        } else if (diaPrice > 0) {
            lastKnownPrice[pair] = diaPrice;
        }
    }

    function fetchPrice(string memory pair) public view returns (uint128, uint128, int256, uint256){
        uint128 diaPrice;
        uint128 diaTimestampLastPriceUpdate;

        try IDIAOracle(diaOraclePriceFeed).getValue(pair) returns (uint128 price, uint128 timestamp) {
            diaPrice = price;
            diaTimestampLastPriceUpdate = timestamp;
        } catch {}

        int256 chainlinkPrice;
        uint256 chainlinkTimestampLastPriceUpdate;

        try chainlinkAggregator.getPrice(pair) returns (int256 price, uint256 timestamp) {
            chainlinkPrice = price;
            chainlinkTimestampLastPriceUpdate = timestamp;
        } catch {}

        return (diaPrice, diaTimestampLastPriceUpdate, chainlinkPrice, chainlinkTimestampLastPriceUpdate);
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
        else if (compareStrings(zkToken.symbol(), "zkWBTC")) {
            symbol = 'WBTC';
            baseUnit = 1e8;
        }
        else if (compareStrings(zkToken.symbol(), "zkUSDC") || compareStrings(zkToken.symbol(), "zkUSDC.e")){
            symbol = 'USDC';
            baseUnit = 1e6;
        }
        else {
            address underlying = ZKErc20(address(zkToken)).underlying();
            symbol = EIP20Interface(underlying).symbol();
            baseUnit = 10 ** EIP20Interface(underlying).decimals();
        }

        string memory pair = string.concat(symbol, "/USD");
        (uint128 diaPrice, uint128 diaTimestampLastPriceUpdate, int256 chainlinkPrice, uint256 chainlinkTimestampLastPriceUpdate) = fetchPrice(pair);

        uint256 price = lastKnownPrice[pair];

        if (chainlinkPrice > 0 && validPriceChange(uint256(chainlinkPrice), lastKnownPrice[pair]) && block.timestamp - chainlinkTimestampLastPriceUpdate < 4 hours) {
            price = uint256(chainlinkPrice);
        } else if (diaPrice > 0 && validPriceChange(diaPrice, lastKnownPrice[pair]) && block.timestamp - diaTimestampLastPriceUpdate < 4 hours) {
            price = diaPrice;
        }
        // Comptroller needs prices in the format: ${raw price} * 1e(36 - baseUnit)
        // Since the prices in this view have 8 decimals, we must scale them by 1e(36 - 8 - baseUnit)
        return mul(1e28, price) / baseUnit;
    }

    function validPriceChange(uint256 newPrice, uint256 lastKnownPrice) internal pure returns (bool) {
        uint256 maxPossiblePrice = lastKnownPrice + (lastKnownPrice / 2); // price went up 50%
        uint256 lowestPossiblePrice = lastKnownPrice - (lastKnownPrice / 2); // price went down 50%
        return lowestPossiblePrice <= newPrice && newPrice <= maxPossiblePrice;
    }

    function updateCommonPairs() external {
        updateLastKnownPrice("ETH/USD");
        updateLastKnownPrice("USDT/USD");
        updateLastKnownPrice("WBTC/USD");
        updateLastKnownPrice("BTC/USD");
        updateLastKnownPrice("USDC/USD");
        updateLastKnownPrice("DAI/USD");
        updateLastKnownPrice("BUSD/USD");
    }

    function updateLastKnownPrice(string memory pair) public {

        (uint128 diaPrice, uint128 diaTimestampLastPriceUpdate, int256 chainlinkPrice, uint256 chainlinkTimestampLastPriceUpdate) = fetchPrice(pair);
        uint256 price = 0;

        if (chainlinkPrice > 0 && validPriceChange(uint256(chainlinkPrice), lastKnownPrice[pair]) && block.timestamp - chainlinkTimestampLastPriceUpdate < 4 hours) {
            price = uint256(chainlinkPrice);
            lastKnownPrice[pair] = price;
        } else if (diaPrice > 0 && validPriceChange(diaPrice, lastKnownPrice[pair]) && block.timestamp - diaTimestampLastPriceUpdate < 4 hours) {
            price = diaPrice;
            lastKnownPrice[pair] = price;
        } else {
            revert("No valid and up to date price available");
        }
    }

    function getDiaPriceInfo(string memory key) external view returns (uint256, uint256) {
        (uint256 price, uint256 timestampLastPrice) = IDIAOracle(diaOraclePriceFeed).getValue(key);
        return (price, timestampLastPrice);
    }

    function getChainlinkPriceInfo(string memory key) external view returns (int256, uint256) {
        (int256 price, uint256 timestampLastPrice) = chainlinkAggregator.getPrice(key);
        return (price, timestampLastPrice);
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