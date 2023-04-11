pragma solidity ^0.8.10;

import "../ZKErc20.sol";
import "../ZKToken.sol";
import "../EIP20Interface.sol";
import "../PriceOracle.sol";
import "../ErrorReporter.sol";
import "../Comptroller.sol";

contract ComptrollerLens is ComptrollerLensInterface, ComptrollerErrorReporter, ExponentialNoError {

    /** liquidate seize calculation **/
    function liquidateCalculateSeizeTokens(
        address comptroller, 
        address zkTokenBorrowed,
        address zkTokenCollateral,
        uint actualRepayAmount
    ) external view returns (uint, uint) {
        /* Read oracle prices for borrowed and collateral markets */
        uint priceBorrowedMantissa = Comptroller(comptroller).oracle().getUnderlyingPrice(ZKToken(zkTokenBorrowed));
        uint priceCollateralMantissa = Comptroller(comptroller).oracle().getUnderlyingPrice(ZKToken(zkTokenCollateral));
        if (priceBorrowedMantissa == 0 || priceCollateralMantissa == 0) {
            return (uint(Error.PRICE_ERROR), 0);
        }

        /*
         * Get the exchange rate and calculate the number of collateral tokens to seize:
         *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
         *  seizeTokens = seizeAmount / exchangeRate
         *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
         */
        uint exchangeRateMantissa = ZKToken(zkTokenCollateral).exchangeRateStored(); // Note: reverts on error
        uint seizeTokens;
        Exp memory numerator;
        Exp memory denominator;
        Exp memory ratio;

        numerator = mul_(Exp({mantissa: Comptroller(comptroller).liquidationIncentiveMantissa()}), Exp({mantissa: priceBorrowedMantissa}));
        denominator = mul_(Exp({mantissa: priceCollateralMantissa}), Exp({mantissa: exchangeRateMantissa}));
        ratio = div_(numerator, denominator);

        seizeTokens = mul_ScalarTruncate(ratio, actualRepayAmount);

        return (uint(Error.NO_ERROR), seizeTokens);
    }

    /** liquidity calculation **/
    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account liquidity.
     *  Note that `zkTokenBalance` is the number of vTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     */
    struct AccountLiquidityLocalVars {
        uint sumCollateral;
        uint sumBorrowPlusEffects;
        uint zkTokenBalance;
        uint borrowBalance;
        uint exchangeRateMantissa;
        uint oraclePriceMantissa;
        Exp collateralFactor;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;
    }

    function getHypotheticalAccountLiquidity(
        address comptroller,
        address account,
        ZKToken zkTokenModify,
        uint redeemTokens,
        uint borrowAmount) public view returns (uint, uint, uint) {

        AccountLiquidityLocalVars memory vars; // Holds all our calculation results
        uint oErr;

        // For each asset the account is in
        ZKToken[] memory assets = Comptroller(comptroller).getAssetsIn(account);
        uint assetsCount = assets.length;
        for (uint i = 0; i < assetsCount; i++) {
            ZKToken asset = assets[i];

            // Read the balances and exchange rate from the zkToken
            (oErr, vars.zkTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) = asset.getAccountSnapshot(account);
            if (oErr != 0) { // semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
                return (uint(Error.SNAPSHOT_ERROR), 0, 0);
            }

            (, uint collateralFactorMantissa) = Comptroller(comptroller).markets(address(asset));
            vars.collateralFactor = Exp({mantissa: collateralFactorMantissa});
            vars.exchangeRate = Exp({mantissa: vars.exchangeRateMantissa});

            // Get the normalized price of the asset
            vars.oraclePriceMantissa = Comptroller(comptroller).oracle().getUnderlyingPrice(asset);
            if (vars.oraclePriceMantissa == 0) {
                return (uint(Error.PRICE_ERROR), 0, 0);
            }
            vars.oraclePrice = Exp({mantissa: vars.oraclePriceMantissa});

            // Pre-compute a conversion factor from tokens -> ether (normalized price value)
            vars.tokensToDenom = mul_(mul_(vars.collateralFactor, vars.exchangeRate), vars.oraclePrice);

            // sumCollateral += tokensToDenom * zkTokenBalance
            vars.sumCollateral = mul_ScalarTruncateAddUInt(vars.tokensToDenom, vars.zkTokenBalance, vars.sumCollateral);

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.oraclePrice, vars.borrowBalance, vars.sumBorrowPlusEffects);

            // Calculate effects of interacting with zkTokenModify
            if (asset == zkTokenModify) {
                // redeem effect
                // sumBorrowPlusEffects += tokensToDenom * redeemTokens
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.tokensToDenom, redeemTokens, vars.sumBorrowPlusEffects);

                // borrow effect
                // sumBorrowPlusEffects += oraclePrice * borrowAmount
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(vars.oraclePrice, borrowAmount, vars.sumBorrowPlusEffects);
            }
        }

        // These are safe, as the underflow condition is checked first
        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            return (uint(Error.NO_ERROR), vars.sumCollateral - vars.sumBorrowPlusEffects, 0);
        } else {
            return (uint(Error.NO_ERROR), 0, vars.sumBorrowPlusEffects - vars.sumCollateral);
        }
    }

     function liquidateBorrowAllowed(
        address comptroller,
        address zkTokenBorrowed,
        address zkTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount
    ) external view returns (uint) {
        if (Comptroller(comptroller).liquidatorContract() != address(0) && liquidator != Comptroller(comptroller).liquidatorContract()) {
            return uint(Error.UNAUTHORIZED);
        }

        (bool zkTokenBorrowedIsListed, ) = Comptroller(comptroller).markets(zkTokenBorrowed);
        (bool zkTokenCollateralIsListed, ) = Comptroller(comptroller).markets(zkTokenCollateral);
        require(zkTokenBorrowedIsListed && zkTokenCollateralIsListed, "market not listed");

        uint borrowBalance = ZKToken(zkTokenBorrowed).borrowBalanceStored(borrower);

        /* allow accounts to be liquidated if the market is deprecated */
        if (Comptroller(comptroller).isDeprecated(ZKToken(zkTokenBorrowed))) {
            require(borrowBalance >= repayAmount, "Can not repay more than the total borrow");
        } else {
            /* The borrower must have shortfall in order to be liquidatable */
            (uint err, , uint shortfall) = getHypotheticalAccountLiquidity(comptroller, borrower, ZKToken(address(0)), 0, 0);
            if (Error(err) != Error.NO_ERROR) {
                return err;
            }

            if (shortfall == 0) {
                return uint(Error.INSUFFICIENT_SHORTFALL);
            }

            /* The liquidator may not repay more than what is allowed by the closeFactor */
            uint maxClose = mul_ScalarTruncate(Exp({mantissa: Comptroller(comptroller).closeFactorMantissa()}), borrowBalance);
            if (repayAmount > maxClose) {
                return uint(Error.TOO_MUCH_REPAY);
            }
        }
        return uint(Error.NO_ERROR);
    }

    function redeemAllowed(
        address comptroller,
        address zkToken,
        address redeemer,
        uint redeemTokens
    ) external view returns (uint) {
        (bool isListed,) = Comptroller(comptroller).markets(address(zkToken));
        require(isListed, "market not listed");

        /* If the redeemer is not 'in' the market, then we can bypass the liquidity check */
        if (!Comptroller(comptroller).accountHasMembership(zkToken, redeemer)) {
            return uint(Error.NO_ERROR);
        }

        /* Otherwise, perform a hypothetical liquidity check to guard against shortfall */
        (uint err, , uint shortfall) = getHypotheticalAccountLiquidity(comptroller, redeemer, ZKToken(zkToken), redeemTokens, 0);
        if (Error(err) != Error.NO_ERROR) {
            return err;
        }

        if (shortfall > 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        return uint(Error.NO_ERROR);
    }

    function seizeAllowed(
        address comptroller,
        address zkTokenCollateral,
        address zkTokenBorrowed,
        uint seizeTokens) external view returns (uint) {

        // Pausing is a very serious situation - we revert to sound the alarms
        require(!Comptroller(comptroller).seizeGuardianPaused(), "seize paused");

        // Shh - currently unused
        seizeTokens;

        (bool zkTokenCollateralIsListed,) = Comptroller(comptroller).markets(zkTokenCollateral);
        (bool zkTokenBorrowedIsListed,) = Comptroller(comptroller).markets(zkTokenBorrowed);
        if (!zkTokenCollateralIsListed || !zkTokenBorrowedIsListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (ZKToken(zkTokenCollateral).comptroller() != ZKToken(zkTokenBorrowed).comptroller()) {
            return uint(Error.COMPTROLLER_MISMATCH);
        }
        return uint(Error.NO_ERROR);
    }

    function checkPartialBorrowAllowedAndReturn(address comptroller, address zkToken, address borrower, uint borrowAmount) override external view returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!Comptroller(comptroller).borrowGuardianPaused(zkToken), "borrow is paused");
        
        if (Comptroller(comptroller).oracle().getUnderlyingPrice(ZKToken(zkToken)) == 0) {
            return uint(Error.PRICE_ERROR);
        }

        uint borrowCap = Comptroller(comptroller).borrowCaps(zkToken);
        // Borrow cap of 0 corresponds to unlimited borrowing
        if (borrowCap != 0) {
            uint totalBorrows = ZKToken(zkToken).totalBorrows();
            uint nextTotalBorrows = add_(totalBorrows, borrowAmount);
            require(nextTotalBorrows < borrowCap, "market borrow cap reached");
        }

        (uint err, , uint shortfall) = getHypotheticalAccountLiquidity(comptroller, borrower, ZKToken(zkToken), 0, borrowAmount);
        if (err != uint(Error.NO_ERROR)) {
            return err;
        }
        if (shortfall > 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        return uint(Error.NO_ERROR);
    }

    function isDeprecated(address comptroller, ZKToken zkToken) external view returns (bool) {
        (, uint collateralFactorMantissa) = Comptroller(comptroller).markets(address(zkToken));

        return
            collateralFactorMantissa == 0 &&
            Comptroller(comptroller).borrowGuardianPaused(address(zkToken)) == true &&
            zkToken.reserveFactorMantissa() == 1e18
        ;
    }
}

