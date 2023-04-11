pragma solidity ^0.8.10;

import "../PriceOracle.sol";
import "../ZKErc20.sol";
import "../EIP20Interface.sol";
import "../Utils/SafeMath.sol";
import "./AggregatorV2V3Interface.sol";
import "../Utils/WithAdmin.sol";

contract ZKFinanceChainlinkOracle is WithAdmin, PriceOracle {
    using SafeMath for uint256;

    mapping(address => uint256) internal prices;
    mapping(bytes32 => AggregatorV2V3Interface) internal feeds;

    event PricePosted(address asset, uint256 previousPriceMantissa, uint256 requestedPriceMantissa, uint256 newPriceMantissa);
    event FeedSet(address feed, string symbol);

    constructor() WithAdmin(msg.sender) {}

    function getUnderlyingPrice(ZKToken zkToken) override public view returns (uint256) {
        string memory symbol = zkToken.symbol();

        if (compareStrings(symbol, "zkETH")) {

            // TODO: refactor this before mainnet release
            return prices[address(zkToken)];
            // return getChainlinkPrice(getFeed(symbol));
        } 
        else if (compareStrings(symbol, "ZGT")) {
            return prices[address(zkToken)];
        } else {
            return getPrice(zkToken);
        }
    }

    function getPrice(ZKToken zkToken) internal view returns (uint256 price) {
        EIP20Interface token = EIP20Interface(ZKErc20(address(zkToken)).underlying());

        if (prices[address(token)] != 0) {
            price = prices[address(token)];
        } else {
            price = getChainlinkPrice(getFeed(token.symbol()));
        }

        uint256 decimalDelta = uint256(18).sub(uint256(token.decimals()));
        // Ensure that we don't multiply the result by 0
        if (decimalDelta > 0) {
            return price.mul(10**decimalDelta);
        } else {
            return price;
        }
    }

    function getChainlinkPrice(AggregatorV2V3Interface feed) internal view returns (uint256) {
        // Chainlink USD-denominated feeds store answers at 8 decimals
        uint256 decimalDelta = uint256(18).sub(feed.decimals());
        // Ensure that we don't multiply the result by 0
        if (decimalDelta > 0) {
            return uint256(feed.latestAnswer()).mul(10**decimalDelta);
        } else {
            return uint256(feed.latestAnswer());
        }
    }

    function setUnderlyingPrice(ZKToken zkToken, uint256 underlyingPriceMantissa) external onlyAdmin() {
        address asset = address(ZKErc20(address(zkToken)).underlying());
        emit PricePosted(asset, prices[asset], underlyingPriceMantissa, underlyingPriceMantissa);
        prices[asset] = underlyingPriceMantissa;
    }

    function setDirectPrice(address asset, uint256 price) external onlyAdmin() {
        emit PricePosted(asset, prices[asset], price, price);
        prices[asset] = price;
    }

    function setFeed(string calldata symbol, address feed) external onlyAdmin() {
        require(feed != address(0) && feed != address(this), "invalid feed address");
        emit FeedSet(feed, symbol);
        feeds[keccak256(abi.encodePacked(symbol))] = AggregatorV2V3Interface(feed);
    }

    function getFeed(string memory symbol) public view returns (AggregatorV2V3Interface) {
        return feeds[keccak256(abi.encodePacked(symbol))];
    }

    function assetPrices(address asset) external view returns (uint256) {
        return prices[asset];
    }

    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }
}