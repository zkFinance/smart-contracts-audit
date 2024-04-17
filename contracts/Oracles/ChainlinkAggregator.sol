// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract ChainlinkAggregator {

    mapping(string => address) public priceFeeds;

    constructor(){
        priceFeeds["USDT/USD"] = 0xB615075979AE1836B476F651f1eB79f0Cd3956a9;
        priceFeeds["BTC/USD"] = 0x4Cba285c15e3B540C474A114a7b135193e4f1EA6;
        priceFeeds["WBTC/USD"] = 0x4Cba285c15e3B540C474A114a7b135193e4f1EA6;
        priceFeeds["ETH/USD"] = 0x6D41d1dc818112880b40e26BD6FD347E41008eDA;
        priceFeeds["USDC/USD"] = 0x1824D297C6d6D311A204495277B63e943C2D376E;
        priceFeeds["DAI/USD"] = 0x5d336664b5D7A332Cd256Bf68CbF2270C6202fc6;
    }

    function getPrice(string memory key) external view returns (int256, uint256) {
        (, int256 price, , uint256 timestampLastPriceUpdate,) = AggregatorV3Interface(priceFeeds[key]).latestRoundData();
        return (price, timestampLastPriceUpdate);
    }
}
