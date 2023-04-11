pragma solidity ^0.8.10;

import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../ExponentialNoError.sol";
import "./ZKFinanceLensInterface.sol";
import "../Oracles/AggregatorV2V3Interface.sol";
import "../Utils/SafeMath.sol";

contract ZKFinanceLens is ExponentialNoError {
        
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IZGTToken public zgt;

    constructor(IZGTToken _zgt) {
        zgt = _zgt;
    }

    struct ZKTokenBalances {
        address zkToken;
        address underlying;
        uint256 balanceOf;
        uint256 borrowBalanceCurrent;
        uint256 borrowBalanceCurrentUsd;
        uint256 balanceOfUnderlying;
        uint256 balanceOfUnderlyingUsd;
        uint256 tokenBalance;
        uint256 tokenBalanceUsd;
        uint256 tokenAllowance;
        uint256 underlyingPrice;
    }

    function zkTokenBalances(
        address comptroller,
        address zkToken,
        address payable account
    ) public returns (ZKTokenBalances memory) {
        address underlying = address(0);
        uint256 balanceOf = IZKToken(zkToken).balanceOf(account);
        uint256 borrowBalanceCurrent = IZKToken(zkToken).borrowBalanceStored(account);
        uint256 balanceOfUnderlying = IZKToken(zkToken).balanceOfUnderlying(account);
        uint256 tokenBalance;
        uint256 tokenAllowance;

        if (isBaseToken(zkToken)) {
            tokenBalance = account.balance;
            tokenAllowance = account.balance;
        } else {
            underlying = IZKToken(zkToken).underlying();
            tokenBalance = IERC20(underlying).balanceOf(account);
            tokenAllowance = IERC20(underlying).allowance(account, address(zkToken));
        }

        uint256 oraclePriceMantissa = IPriceOracle(IComptroller(comptroller).oracle()).getUnderlyingPrice(zkToken);
        Exp memory underlyingPrice = Exp({mantissa: oraclePriceMantissa});

        return
            ZKTokenBalances({
                zkToken: zkToken,
                underlying: underlying,
                balanceOf: balanceOf,
                borrowBalanceCurrent: borrowBalanceCurrent,
                borrowBalanceCurrentUsd: mul_(borrowBalanceCurrent, underlyingPrice),
                balanceOfUnderlying: balanceOfUnderlying,
                balanceOfUnderlyingUsd: mul_(balanceOfUnderlying, underlyingPrice),
                tokenBalance: tokenBalance,
                tokenBalanceUsd: mul_(tokenBalance, underlyingPrice),
                tokenAllowance: tokenAllowance,
                underlyingPrice: underlyingPrice.mantissa
            });
    }

    function zkTokenBalancesAll(
        address _comptroller,
        address[] calldata zkTokens,
        address payable account
    ) external returns (ZKTokenBalances[] memory) {
        uint256 zkTokenCount = zkTokens.length;
        ZKTokenBalances[] memory res = new ZKTokenBalances[](zkTokenCount);
        for (uint256 i = 0; i < zkTokenCount; i++) {
            res[i] = zkTokenBalances(_comptroller, zkTokens[i], account);
        }
        return res;
    }

    struct ZKTokenMetadata {
        address zkToken;
        uint256 exchangeRateCurrent;
        uint256 supplyRatePerBlock;
        uint256 borrowRatePerBlock;
        uint256 reserveFactorMantissa;
        uint256 totalBorrows;
        uint256 totalReserves;
        uint256 totalSupply;
        uint256 totalCash;
        bool isListed;
        uint256 collateralFactorMantissa;
        address underlyingAssetAddress;
        uint256 zkTokenDecimals;
        uint256 underlyingDecimals;
        uint256 zgtSupplySpeed;
        uint256 zgtBorrowSpeed;
        uint256 borrowCap;
        bool borrowPaused;
        int256 utilizationRate;
        uint256 underlyingPrice;
    }

    function zkTokenMetadata(
        address _comptroller,
        address _zkToken
    ) public returns (ZKTokenMetadata memory) {
        IComptroller comptroller = IComptroller(_comptroller);
        IComptroller.Market memory market = comptroller.markets(address(_zkToken));
        IPriceOracle oracle = IPriceOracle(comptroller.oracle());
        uint256 oraclePriceMantissa = oracle.getUnderlyingPrice(_zkToken);
        uint256 zgtSupplySpeed = comptroller.zgtSupplySpeeds(_zkToken);
        uint256 zgtBorrowSpeed = comptroller.zgtBorrowSpeeds(_zkToken);

        ZKTokenMetadata memory meta;
        meta = ZKTokenMetadata({
            zkToken: _zkToken,
            exchangeRateCurrent: IZKToken(_zkToken).exchangeRateStored(),
            supplyRatePerBlock: IZKToken(_zkToken).supplyRatePerBlock(),
            borrowRatePerBlock: IZKToken(_zkToken).borrowRatePerBlock(),
            reserveFactorMantissa: IZKToken(_zkToken).reserveFactorMantissa(),
            totalBorrows: IZKToken(_zkToken).totalBorrows(),
            totalReserves: IZKToken(_zkToken).totalReserves(),
            totalSupply: IZKToken(_zkToken).totalSupply(),
            totalCash: IZKToken(_zkToken).getCash(),
            isListed: market.isListed,
            collateralFactorMantissa: market.collateralFactorMantissa,
            underlyingAssetAddress: isBaseToken(_zkToken) ? address(0) : IZKToken(_zkToken).underlying(),
            zkTokenDecimals: IZKToken(_zkToken).decimals(),
            underlyingDecimals: isBaseToken(_zkToken) ? 18 : IERC20Extented(IZKToken(_zkToken).underlying()).decimals(),
            zgtSupplySpeed: zgtSupplySpeed,
            zgtBorrowSpeed: zgtBorrowSpeed,
            borrowCap: comptroller.borrowCaps(_zkToken),
            borrowPaused: comptroller.borrowGuardianPaused(_zkToken),
            utilizationRate: _getUtilizationRate(_zkToken),
            underlyingPrice: oraclePriceMantissa
        });
        return meta;
    }

    function zkTokenMetadataAll(
        address _comptroller,
        address[] calldata zkTokens
    ) external returns (ZKTokenMetadata[] memory) {
        uint256 zkTokenCount = zkTokens.length;
        ZKTokenMetadata[] memory res = new ZKTokenMetadata[](zkTokenCount);
        for (uint256 i = 0; i < zkTokenCount; i++) {
            res[i] = zkTokenMetadata(_comptroller, zkTokens[i]);
        }
        return res;
    }

    struct AccountLimits {
        address[] markets;
        uint256 liquidity;
        uint256 shortfall;
    }

    function getAccountLimits(address _comptroller, address account) external view returns (AccountLimits memory) {
        IComptroller comptroller = IComptroller(_comptroller);
        (uint256 errorCode, uint256 liquidity, uint256 shortfall) = comptroller.getAccountLiquidity(account);
        require(errorCode == 0);

        return AccountLimits({markets: comptroller.getAssetsIn(account), liquidity: liquidity, shortfall: shortfall});
    }

    struct ZGTBalanceMetadataExt {
        uint256 balance;
        uint256 votes;
        address delegate;
        uint256 allocated;
    }

    function getZGTBalanceMetadataExt(
        address _comptroller,
        address account,
        bool includeGovernanceVotes
    ) external returns (ZGTBalanceMetadataExt memory) {
        uint256 balance = IZGTToken(zgt).balanceOf(account);
        IComptroller comptroller = IComptroller(_comptroller);
        comptroller.claimZGT(account);

        uint256 newBalance = IZGTToken(zgt).balanceOf(account);
        uint256 accrued = comptroller.zgtAccrued(account);
        uint256 total = accrued.add(newBalance);
        uint256 allocated = total.sub(balance);

        if (includeGovernanceVotes) {
            return ZGTBalanceMetadataExt({
                        balance: balance,
                        votes: uint256(IZGTToken(zgt).getCurrentVotes(account)),
                        delegate: IZGTToken(zgt).delegates(account),
                        allocated: allocated
            });
        } else {
            return ZGTBalanceMetadataExt({balance: balance, votes: 0, delegate: address(0), allocated: allocated});
        }
    }

    function estimateSupplyRateAfterChange(
        address zkToken,
        uint256 change,
        bool redeem,
        address comptroller
    )
        external
        view
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        uint256 cashPriorNew;

        if (redeem) {
            cashPriorNew = sub_(IZKToken(zkToken).getCash(), change);
        } else {
            cashPriorNew = add_(IZKToken(zkToken).getCash(), change);
        }

        uint256 supplyInterestRate = IInterestRateModel(IZKToken(zkToken).interestRateModel()).getSupplyRate(
            cashPriorNew,
            IZKToken(zkToken).totalBorrows(),
            IZKToken(zkToken).totalReserves(),
            IZKToken(zkToken).reserveFactorMantissa()
        );
        
        uint256 zgtSupplySpeed = IComptroller(comptroller).zgtSupplySpeeds(zkToken);
        uint256 oraclePriceMantissa = IPriceOracle(IComptroller(comptroller).oracle()).getUnderlyingPrice(zkToken);
        return (supplyInterestRate, zgtSupplySpeed, oraclePriceMantissa);
    }

    function estimateBorrowRateAfterChange(
        address zkToken,
        uint256 change,
        bool repay,
        address comptroller
    )
        external
        view
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        uint256 cashPriorNew;
        uint256 totalBorrowsNew;

        if (repay) {
            cashPriorNew = add_(IZKToken(zkToken).getCash(), change);
            totalBorrowsNew = sub_(IZKToken(zkToken).totalBorrows(), change);
        } else {
            cashPriorNew = sub_(IZKToken(zkToken).getCash(), change);
            totalBorrowsNew = add_(IZKToken(zkToken).totalBorrows(), change);
        }

        uint256 borrowInterestRate = IInterestRateModel(IZKToken(zkToken).interestRateModel()).getBorrowRate(cashPriorNew, totalBorrowsNew, IZKToken(zkToken).totalReserves());
        uint256 zgtBorrowSpeed = IComptroller(comptroller).zgtBorrowSpeeds(zkToken);

        uint256 oraclePriceMantissa = IPriceOracle(IComptroller(comptroller).oracle()).getUnderlyingPrice(zkToken);
        return (borrowInterestRate, zgtBorrowSpeed, oraclePriceMantissa);
    }

    function getSupplyAndBorrowRate(
        address zkToken,
        uint256 cash,
        uint256 totalBorrows,
        uint256 totalReserves,
        uint256 reserveFactorMantissa
    ) external view returns (uint256, uint256) {
        return (
            IInterestRateModel(IZKToken(zkToken).interestRateModel()).getSupplyRate(cash, totalBorrows, totalReserves, reserveFactorMantissa),
            IInterestRateModel(IZKToken(zkToken).interestRateModel()).getBorrowRate(cash, totalBorrows, totalReserves)
        );
    }

    function _getUtilizationRate(address zkToken) internal returns (int256) {
        (bool success, bytes memory returnData) = IZKToken(zkToken).interestRateModel().call(
            abi.encodePacked(
                IJumpRateModelV2(IZKToken(zkToken).interestRateModel()).utilizationRate.selector,
                abi.encode(IZKToken(zkToken).getCash(), IZKToken(zkToken).totalBorrows(), IZKToken(zkToken).totalReserves())
            )
        );

        int256 utilizationRate;
        if (success) {
            utilizationRate = abi.decode(returnData, (int256));
        } else {
            utilizationRate = -1;
        }

        return utilizationRate;
    }

    function isBaseToken(address zkToken) internal view returns (bool) {
        return _compareStrings(IZKToken(zkToken).symbol(), "zkETH");
    }

    function _compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }
}
