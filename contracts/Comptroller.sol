// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./ZKToken.sol";
import "./ErrorReporter.sol";
import "./PriceOracle.sol";
import "./ComptrollerInterface.sol";
import "./ComptrollerStorage.sol";
import "./Unitroller.sol";
import "./Governance/ZGT.sol";
import "./ComptrollerLensInterface.sol";

/**
 * @title zkFinance's Comptroller Contract
 * @author zkFinance
 */
contract Comptroller is ComptrollerStorage, ComptrollerInterface, ComptrollerErrorReporter, ExponentialNoError {
    /// @notice Emitted when an admin supports a market
    event MarketListed(ZKToken zkToken);

    /// @notice Emitted when an account enters a market
    event MarketEntered(ZKToken zkToken, address account);

    /// @notice Emitted when an account exits a market
    event MarketExited(ZKToken zkToken, address account);

    /// @notice Emitted when close factor is changed by admin
    event NewCloseFactor(uint oldCloseFactorMantissa, uint newCloseFactorMantissa);

    /// @notice Emitted when a collateral factor is changed by admin
    event NewCollateralFactor(ZKToken zkToken, uint oldCollateralFactorMantissa, uint newCollateralFactorMantissa);

    /// @notice Emitted when liquidation incentive is changed by admin
    event NewLiquidationIncentive(uint oldLiquidationIncentiveMantissa, uint newLiquidationIncentiveMantissa);

    /// @notice Emitted when price oracle is changed
    event NewPriceOracle(PriceOracle oldPriceOracle, PriceOracle newPriceOracle);

    /// @notice Emitted when pause guardian is changed
    event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);

    /// @notice Emitted when an action is paused globally
    event ActionPaused(string action, bool pauseState);

    /// @notice Emitted when an action is paused on a market
    event ActionPaused(ZKToken zkToken, string action, bool pauseState);

    /// @notice Emitted when a new borrow-side ZGT speed is calculated for a market
    event ZGTBorrowSpeedUpdated(ZKToken indexed zkToken, uint newSpeed);

    /// @notice Emitted when a new supply-side ZGT speed is calculated for a market
    event ZGTSupplySpeedUpdated(ZKToken indexed zkToken, uint newSpeed);

    /// @notice Emitted when a new ZGT speed is set for a contributor
    event ContributorZGTSpeedUpdated(address indexed contributor, uint newSpeed);

    /// @notice Emitted when ZGT is distributed to a supplier
    event DistributedSupplierZGT(ZKToken indexed zkToken, address indexed supplier, uint zgtDelta, uint zgtSupplyIndex);

    /// @notice Emitted when ZGT is distributed to a borrower
    event DistributedBorrowerZGT(ZKToken indexed zkToken, address indexed borrower, uint zgtDelta, uint zgtBorrowIndex);

    /// @notice Emitted when borrow cap for a zkToken is changed
    event NewBorrowCap(ZKToken indexed zkToken, uint newBorrowCap);

    /// @notice Emitted when borrow cap guardian is changed
    event NewBorrowCapGuardian(address oldBorrowCapGuardian, address newBorrowCapGuardian);

    /// @notice Emitted when ZGT is granted by admin
    event ZGTGranted(address recipient, uint amount);

    /// @notice Emitted whe ComptrollerLens address is changed
    event NewComptrollerLens(address oldComptrollerLens, address newComptrollerLens);
    
    /// @notice Emitted when ZGT accrued for a user has been manually adjusted.
    event ZGTAccruedAdjusted(address indexed user, uint oldCompAccrued, uint newCompAccrued);

    /// @notice Emitted when ZGT receivable for a user has been updated.
    event ZGTReceivableUpdated(address indexed user, uint oldZGTReceivable, uint newZGTReceivable);

    // @notice Emitted when liquidator adress is changed
    event NewLiquidatorContract(address oldLiquidatorContract, address newLiquidatorContract);
    
    /// @notice Emitted when ZGT claiming state is changed by admin
    event ActionZGTClaimingPaused(bool state);

    /// @notice The initial ZGT index for a market
    uint224 public constant zgtInitialIndex = 1e36;

    // closeFactorMantissa must be strictly greater than this value
    uint internal constant closeFactorMinMantissa = 0.05e18; // 0.05

    // closeFactorMantissa must not exceed this value
    uint internal constant closeFactorMaxMantissa = 0.9e18; // 0.9

    // No collateralFactorMantissa may exceed this value
    uint internal constant collateralFactorMaxMantissa = 0.9e18; // 0.9

    constructor() {
        admin = msg.sender;
    }

    /// @notice Reverts if the caller is not admin
    function ensureAdmin() private view {
        require(msg.sender == admin, "only admin");
    }

    /// @notice Checks the passed address is nonzero
    function ensureNonzeroAddress(address someone) private pure {
        require(someone != address(0), "can't be zero address");
    }

    /// @notice Reverts if the market is not listed
    function ensureListed(Market storage market) private view {
        require(market.isListed, "market not listed");
    }

    /*** Assets You Are In ***/

    /**
     * @notice Returns the assets an account has entered
     * @param account The address of the account to pull assets for
     * @return A dynamic list with the assets the account has entered
     */
    function getAssetsIn(address account) external view returns (ZKToken[] memory) {
        ZKToken[] memory assetsIn = accountAssets[account];

        return assetsIn;
    }

    /**
     * @notice Returns whether the given account is entered in the given asset
     * @param account The address of the account to check
     * @param zkToken The zkToken to check
     * @return True if the account is in the asset, otherwise false.
     */
    function checkMembership(address account, ZKToken zkToken) external view returns (bool) {
        return markets[address(zkToken)].accountMembership[account];
    }

    /**
     * @notice Add assets to be included in account liquidity calculation
     * @param zkTokens The list of addresses of the zkToken markets to be enabled
     * @return Success indicator for whether each corresponding market was entered
     */
    function enterMarkets(address[] memory zkTokens) override public returns (uint[] memory) {
        uint len = zkTokens.length;

        uint[] memory results = new uint[](len);
        for (uint i = 0; i < len; i++) {
            ZKToken zkToken = ZKToken(zkTokens[i]);

            results[i] = uint(addToMarketInternal(zkToken, msg.sender));
        }

        return results;
    }

    /**
     * @notice Add the market to the borrower's "assets in" for liquidity calculations
     * @param zkToken The market to enter
     * @param borrower The address of the account to modify
     * @return Success indicator for whether the market was entered
     */
    function addToMarketInternal(ZKToken zkToken, address borrower) internal returns (Error) {
        Market storage marketToJoin = markets[address(zkToken)];
        ensureListed(marketToJoin);

        if (marketToJoin.accountMembership[borrower] == true) {
            // already joined
            return Error.NO_ERROR;
        }

        // survived the gauntlet, add to list
        // NOTE: we store these somewhat redundantly as a significant optimization
        //  this avoids having to iterate through the list for the most common use cases
        //  that is, only when we need to perform liquidity checks
        //  and not whenever we want to check if an account is in a particular market
        marketToJoin.accountMembership[borrower] = true;
        accountAssets[borrower].push(zkToken);

        emit MarketEntered(zkToken, borrower);

        return Error.NO_ERROR;
    }

    /**
     * @notice Removes asset from sender's account liquidity calculation
     * @dev Sender must not have an outstanding borrow balance in the asset,
     *  or be providing necessary collateral for an outstanding borrow.
     * @param zkTokenAddress The address of the asset to be removed
     * @return Whether or not the account successfully exited the market
     */
    function exitMarket(address zkTokenAddress) override external returns (uint) {
        /* Get sender tokensHeld and amountOwed underlying from the zkToken */
        (uint oErr, uint tokensHeld, uint amountOwed, ) = ZKToken(zkTokenAddress).getAccountSnapshot(msg.sender);
        require(oErr == 0, "getAccountSnapshot failed"); // semi-opaque error code

        /* Fail if the sender has a borrow balance */
        if (amountOwed != 0) {
            return fail(Error.NONZERO_BORROW_BALANCE, FailureInfo.EXIT_MARKET_BALANCE_OWED);
        }

        /* Fail if the sender is not permitted to redeem all of their tokens */
        uint allowed = redeemAllowedInternal(zkTokenAddress, msg.sender, tokensHeld);
        if (allowed != 0) {
            return failOpaque(Error.REJECTION, FailureInfo.EXIT_MARKET_REJECTION, allowed);
        }

        Market storage marketToExit = markets[address(zkTokenAddress)];

        /* Return true if the sender is not already ‘in’ the market */
        if (!marketToExit.accountMembership[msg.sender]) {
            return uint(Error.NO_ERROR);
        }

        /* Set zkToken account membership to false */
        delete marketToExit.accountMembership[msg.sender];

        /* Delete zkToken from the account’s list of assets */
        // load into memory for faster iteration
        ZKToken[] memory userAssetList = accountAssets[msg.sender];
        uint len = userAssetList.length;
        uint assetIndex = len;
        for (uint i = 0; i < len; i++) {
            if (userAssetList[i] == ZKToken(zkTokenAddress)) {
                assetIndex = i;
                break;
            }
        }

        // We *must* have found the asset in the list or our redundant data structure is broken
        assert(assetIndex < len);

        // copy last item in list to location of item to be removed, reduce length by 1
        ZKToken[] storage storedList = accountAssets[msg.sender];
        storedList[assetIndex] = storedList[storedList.length - 1];
        storedList.pop();

        emit MarketExited(ZKToken(zkTokenAddress), msg.sender);

        return uint(Error.NO_ERROR);
    }

    /*** Policy Hooks ***/

    /**
     * @notice Checks if the account should be allowed to mint tokens in the given market
     * @param zkToken The market to verify the mint against
     * @param minter The account which would get the minted tokens
     * @param mintAmount The amount of underlying being supplied to the market in exchange for tokens
     * @return 0 if the mint is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function mintAllowed(address zkToken, address minter, uint mintAmount) override external returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!mintGuardianPaused[zkToken], "mint paused");

        // Shh - currently unused
        minter;
        mintAmount;

        ensureListed(markets[zkToken]);

        // Keep the flywheel moving
        updateZGTSupplyIndex(zkToken);
        distributeSupplierZGT(zkToken, minter);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates mint and reverts on rejection. May emit logs.
     * @param zkToken Asset being minted
     * @param minter The address minting the tokens
     * @param actualMintAmount The amount of the underlying asset being minted
     * @param mintTokens The number of tokens being minted
     */
    function mintVerify(address zkToken, address minter, uint actualMintAmount, uint mintTokens) override external {
        // Shh - currently unused
        zkToken;
        minter;
        actualMintAmount;
        mintTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to redeem tokens in the given market
     * @param zkToken The market to verify the redeem against
     * @param redeemer The account which would redeem the tokens
     * @param redeemTokens The number of zkTokens to exchange for the underlying asset in the market
     * @return 0 if the redeem is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function redeemAllowed(address zkToken, address redeemer, uint redeemTokens) override external returns (uint) {
        uint allowed = redeemAllowedInternal(zkToken, redeemer, redeemTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateZGTSupplyIndex(zkToken);
        distributeSupplierZGT(zkToken, redeemer);

        return uint(Error.NO_ERROR);
    }

    function redeemAllowedInternal(address zkToken, address redeemer, uint redeemTokens) internal view returns (uint) {
       (uint err) = comptrollerLens.redeemAllowed(
            address(this), 
            zkToken, 
            redeemer, 
            redeemTokens
        );
        return err;
    }

    /**
     * @notice Validates redeem and reverts on rejection. May emit logs.
     * @param zkToken Asset being redeemed
     * @param redeemer The address redeeming the tokens
     * @param redeemAmount The amount of the underlying asset being redeemed
     * @param redeemTokens The number of tokens being redeemed
     */
    function redeemVerify(address zkToken, address redeemer, uint redeemAmount, uint redeemTokens) override external pure {
        // Shh - currently unused
        zkToken;
        redeemer;

        // Require tokens is zero or amount is also zero
        if (redeemTokens == 0 && redeemAmount > 0) {
            revert("redeemTokens zero");
        }
    }

    /**
     * @notice Checks if the account should be allowed to borrow the underlying asset of the given market
     * @param zkToken The market to verify the borrow against
     * @param borrower The account which would borrow the asset
     * @param borrowAmount The amount of underlying the account would borrow
     * @return 0 if the borrow is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function borrowAllowed(address zkToken, address borrower, uint borrowAmount) override external returns (uint) {


        // ensureListed(markets[zkToken]);

        if (!markets[zkToken].accountMembership[borrower]) {
            // only zkTokens may call borrowAllowed if borrower not in market
            require(msg.sender == zkToken, "sender must be zkToken");

            // attempt to add borrower to the market
            Error err = addToMarketInternal(ZKToken(msg.sender), borrower);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }

            // it should be impossible to break the important invariant
            assert(markets[zkToken].accountMembership[borrower]);
        }

        uint err = comptrollerLens.checkPartialBorrowAllowedAndReturn(address(this), zkToken, borrower, borrowAmount);
        if (err != uint(Error.NO_ERROR)) {
            return err;
        }

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({mantissa: ZKToken(zkToken).borrowIndex()});
        updateZGTBorrowIndex(zkToken, borrowIndex);
        distributeBorrowerZGT(zkToken, borrower, borrowIndex);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates borrow and reverts on rejection. May emit logs.
     * @param zkToken Asset whose underlying is being borrowed
     * @param borrower The address borrowing the underlying
     * @param borrowAmount The amount of the underlying asset requested to borrow
     */
    function borrowVerify(address zkToken, address borrower, uint borrowAmount) override external {
        // Shh - currently unused
        zkToken;
        borrower;
        borrowAmount;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to repay a borrow in the given market
     * @param zkToken The market to verify the repay against
     * @param payer The account which would repay the asset
     * @param borrower The account which would borrowed the asset
     * @param repayAmount The amount of the underlying asset the account would repay
     * @return 0 if the repay is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function repayBorrowAllowed(
        address zkToken,
        address payer,
        address borrower,
        uint repayAmount) override external returns (uint) {
        // Shh - currently unused
        payer;
        borrower;
        repayAmount;

        ensureListed(markets[zkToken]);

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({mantissa: ZKToken(zkToken).borrowIndex()});
        updateZGTBorrowIndex(zkToken, borrowIndex);
        distributeBorrowerZGT(zkToken, borrower, borrowIndex);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates repayBorrow and reverts on rejection. May emit logs.
     * @param zkToken Asset being repaid
     * @param payer The address repaying the borrow
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function repayBorrowVerify(
        address zkToken,
        address payer,
        address borrower,
        uint actualRepayAmount,
        uint borrowerIndex) override external {
        // Shh - currently unused
        zkToken;
        payer;
        borrower;
        actualRepayAmount;
        borrowerIndex;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the liquidation should be allowed to occur
     * @param zkTokenBorrowed Asset which was borrowed by the borrower
     * @param zkTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param repayAmount The amount of underlying being repaid
     */
    function liquidateBorrowAllowed(
        address zkTokenBorrowed,
        address zkTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount) override external view returns (uint) {
        return comptrollerLens.liquidateBorrowAllowed(
            address(this),
            zkTokenBorrowed,
            zkTokenCollateral,
            liquidator,
            borrower,
            repayAmount
        );
    }

    /**
     * @notice Validates liquidateBorrow and reverts on rejection. May emit logs.
     * @param zkTokenBorrowed Asset which was borrowed by the borrower
     * @param zkTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function liquidateBorrowVerify(
        address zkTokenBorrowed,
        address zkTokenCollateral,
        address liquidator,
        address borrower,
        uint actualRepayAmount,
        uint seizeTokens) override external {
        // Shh - currently unused
        zkTokenBorrowed;
        zkTokenCollateral;
        liquidator;
        borrower;
        actualRepayAmount;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the seizing of assets should be allowed to occur
     * @param zkTokenCollateral Asset which was used as collateral and will be seized
     * @param zkTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeAllowed(
        address zkTokenCollateral,
        address zkTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) override external returns (uint) {
        uint err = comptrollerLens.seizeAllowed(address(this), zkTokenCollateral, zkTokenBorrowed, seizeTokens);
        if (err != uint(Error.NO_ERROR)) {
            return err;
        }

        // Keep the flywheel moving
        updateZGTSupplyIndex(zkTokenCollateral);
        distributeSupplierZGT(zkTokenCollateral, borrower);
        distributeSupplierZGT(zkTokenCollateral, liquidator);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates seize and reverts on rejection. May emit logs.
     * @param zkTokenCollateral Asset which was used as collateral and will be seized
     * @param zkTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeVerify(
        address zkTokenCollateral,
        address zkTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) override external {
        // Shh - currently unused
        zkTokenCollateral;
        zkTokenBorrowed;
        liquidator;
        borrower;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to transfer tokens in the given market
     * @param zkToken The market to verify the transfer against
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of zkTokens to transfer
     * @return 0 if the transfer is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function transferAllowed(address zkToken, address src, address dst, uint transferTokens) override external returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!transferGuardianPaused, "transfer is paused");

        // Currently the only consideration is whether or not
        //  the src is allowed to redeem this many tokens
        uint allowed = redeemAllowedInternal(zkToken, src, transferTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateZGTSupplyIndex(zkToken);
        distributeSupplierZGT(zkToken, src);
        distributeSupplierZGT(zkToken, dst);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates transfer and reverts on rejection. May emit logs.
     * @param zkToken Asset being transferred
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of zkTokens to transfer
     */
    function transferVerify(address zkToken, address src, address dst, uint transferTokens) override external {
        // Shh - currently unused
        zkToken;
        src;
        dst;
        transferTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /*** Liquidity/Liquidation Calculations ***/

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code (semi-opaque),
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidity(address account) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, ZKToken(address(0)), 0, 0);

        return (uint(err), liquidity, shortfall);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param zkTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @return (possible error code (semi-opaque),
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidity(
        address account,
        address zkTokenModify,
        uint redeemTokens,
        uint borrowAmount) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, ZKToken(zkTokenModify), redeemTokens, borrowAmount);
        return (uint(err), liquidity, shortfall);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param zkTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @dev Note that we calculate the exchangeRateStored for each collateral zkToken using stored data,
     *  without calculating accumulated interest.
     * @return (possible error code,
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidityInternal(
        address account,
        ZKToken zkTokenModify,
        uint redeemTokens,
        uint borrowAmount) internal view returns (Error, uint, uint) {
        (uint err, uint liquidity, uint shortfall) = comptrollerLens.getHypotheticalAccountLiquidity(
            address(this),
            account,
            zkTokenModify,
            redeemTokens,
            borrowAmount
        );
        return (Error(err), liquidity, shortfall);
    }

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an underlying amount
     * @dev Used in liquidation (called in zkToken.liquidateBorrowFresh)
     * @param zkTokenBorrowed The address of the borrowed zkToken
     * @param zkTokenCollateral The address of the collateral zkToken
     * @param actualRepayAmount The amount of zkTokenBorrowed underlying to convert into zkTokenCollateral tokens
     * @return (errorCode, number of zkTokenCollateral tokens to be seized in a liquidation)
     */
    function liquidateCalculateSeizeTokens(address zkTokenBorrowed, address zkTokenCollateral, uint actualRepayAmount) override external view returns (uint, uint) {
        (uint err, uint seizeTokens) = comptrollerLens.liquidateCalculateSeizeTokens(
            address(this), 
            zkTokenBorrowed, 
            zkTokenCollateral, 
            actualRepayAmount
        );
        return (err, seizeTokens);
    }

    /*** Admin Functions ***/

    /**
      * @notice Sets a new price oracle for the comptroller
      * @dev Admin function to set a new price oracle
      * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function _setPriceOracle(PriceOracle newOracle) public returns (uint) {
       // Check caller is admin
        ensureAdmin();
        ensureNonzeroAddress(address(newOracle));

        // Track the old oracle for the comptroller
        PriceOracle oldOracle = oracle;

        // Set comptroller's oracle to newOracle
        oracle = newOracle;

        // Emit NewPriceOracle(oldOracle, newOracle)
        emit NewPriceOracle(oldOracle, newOracle);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets the closeFactor used when liquidating borrows
      * @dev Admin function to set closeFactor
      * @param newCloseFactorMantissa New close factor, scaled by 1e18
      * @return uint 0=success, otherwise a failure
      */
    function _setCloseFactor(uint newCloseFactorMantissa) external returns (uint) {
        // Check caller is admin
        ensureAdmin();

        uint oldCloseFactorMantissa = closeFactorMantissa;
        closeFactorMantissa = newCloseFactorMantissa;
        emit NewCloseFactor(oldCloseFactorMantissa, closeFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets the collateralFactor for a market
      * @dev Admin function to set per-market collateralFactor
      * @param zkToken The market to set the factor on
      * @param newCollateralFactorMantissa The new collateral factor, scaled by 1e18
      * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
      */
    function _setCollateralFactor(ZKToken zkToken, uint newCollateralFactorMantissa) external returns (uint) {
        // Check caller is admin
        ensureAdmin();
        ensureNonzeroAddress(address(zkToken));

        // Verify market is listed
        Market storage market = markets[address(zkToken)];
        ensureListed(market);

        Exp memory newCollateralFactorExp = Exp({mantissa: newCollateralFactorMantissa});

        // Check collateral factor <= 0.9
        Exp memory highLimit = Exp({mantissa: collateralFactorMaxMantissa});
        if (lessThanExp(highLimit, newCollateralFactorExp)) {
            return fail(Error.INVALID_COLLATERAL_FACTOR, FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION);
        }

        // If collateral factor != 0, fail if price == 0
        if (newCollateralFactorMantissa != 0 && oracle.getUnderlyingPrice(zkToken) == 0) {
            return fail(Error.PRICE_ERROR, FailureInfo.SET_COLLATERAL_FACTOR_WITHOUT_PRICE);
        }

        // Set market's collateral factor to new collateral factor, remember old value
        uint oldCollateralFactorMantissa = market.collateralFactorMantissa;
        market.collateralFactorMantissa = newCollateralFactorMantissa;

        // Emit event with asset, old collateral factor, and new collateral factor
        emit NewCollateralFactor(zkToken, oldCollateralFactorMantissa, newCollateralFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets liquidationIncentive
      * @dev Admin function to set liquidationIncentive
      * @param newLiquidationIncentiveMantissa New liquidationIncentive scaled by 1e18
      * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
      */
    function _setLiquidationIncentive(uint newLiquidationIncentiveMantissa) external returns (uint) {
        // Check caller is admin
        ensureAdmin();

        require(newLiquidationIncentiveMantissa >= 1e18, "incentive must be over 1e18");

        // Save current value for use in log
        uint oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;

        // Set liquidation incentive to new incentive
        liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;

        // Emit event with old incentive, new incentive
        emit NewLiquidationIncentive(oldLiquidationIncentiveMantissa, newLiquidationIncentiveMantissa);

        return uint(Error.NO_ERROR);
    }

    function _setLiquidatorContract(address newLiquidatorContract_) external {
        // Check caller is admin
        require(msg.sender == admin, "only admin");
        
        address oldLiquidatorContract = liquidatorContract;
        liquidatorContract = newLiquidatorContract_;
        emit NewLiquidatorContract(oldLiquidatorContract, newLiquidatorContract_);
    }

    /**
      * @notice Add the market to the markets mapping and set it as listed
      * @dev Admin function to set isListed and add support for the market
      * @param zkToken The address of the market (token) to list
      * @return uint 0=success, otherwise a failure. (See enum Error for details)
      */
    function _supportMarket(ZKToken zkToken) external returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SUPPORT_MARKET_OWNER_CHECK);
        }

        if (markets[address(zkToken)].isListed) {
            return fail(Error.MARKET_ALREADY_LISTED, FailureInfo.SUPPORT_MARKET_EXISTS);
        }

        zkToken.isZKToken(); // Sanity check to make sure its really a ZKToken

        // Note that is not in active use anymore
        Market storage newMarket = markets[address(zkToken)];
        newMarket.isListed = true;
        newMarket.collateralFactorMantissa = 0;

        _addMarketInternal(address(zkToken));
        _initializeMarket(address(zkToken));

        emit MarketListed(zkToken);

        return uint(Error.NO_ERROR);
    }

    function _addMarketInternal(address zkToken) internal {
        for (uint i = 0; i < allMarkets.length; i ++) {
            require(allMarkets[i] != ZKToken(zkToken), "market already added");
        }
        allMarkets.push(ZKToken(zkToken));
    }

    function _initializeMarket(address zkToken) internal {
        uint32 blockNumber = safe32(getBlockNumber(), "block number exceeds 32 bits");

        ZGTMarketState storage supplyState = zgtSupplyState[zkToken];
        ZGTMarketState storage borrowState = zgtBorrowState[zkToken];

        /*
         * Update market state indices
         */
        if (supplyState.index == 0) {
            // Initialize supply state index with default value
            supplyState.index = zgtInitialIndex;
        }

        if (borrowState.index == 0) {
            // Initialize borrow state index with default value
            borrowState.index = zgtInitialIndex;
        }

        /*
         * Update market state block numbers
         */
         supplyState.block = borrowState.block = blockNumber;
    }


    /**
      * @notice Set the given borrow caps for the given zkToken markets. Borrowing that brings total borrows to or above borrow cap will revert.
      * @dev Admin or borrowCapGuardian function to set the borrow caps. A borrow cap of 0 corresponds to unlimited borrowing.
      * @param zkTokens The addresses of the markets (tokens) to change the borrow caps for
      * @param newBorrowCaps The new borrow cap values in underlying to be set. A value of 0 corresponds to unlimited borrowing.
      */
    function _setMarketBorrowCaps(ZKToken[] calldata zkTokens, uint[] calldata newBorrowCaps) external {
    	require(msg.sender == admin || msg.sender == borrowCapGuardian, "only admin or guardian");

        uint numMarkets = zkTokens.length;
        uint numBorrowCaps = newBorrowCaps.length;

        require(numMarkets != 0 && numMarkets == numBorrowCaps, "invalid input");

        for(uint i = 0; i < numMarkets; i++) {
            borrowCaps[address(zkTokens[i])] = newBorrowCaps[i];
            emit NewBorrowCap(zkTokens[i], newBorrowCaps[i]);
        }
    }

    /**
     * @notice Admin function to change the Borrow Cap Guardian
     * @param newBorrowCapGuardian The address of the new Borrow Cap Guardian
     */
    function _setBorrowCapGuardian(address newBorrowCapGuardian) external {
        require(msg.sender == admin, "only admin");

        // Save current value for inclusion in log
        address oldBorrowCapGuardian = borrowCapGuardian;

        // Store borrowCapGuardian with value newBorrowCapGuardian
        borrowCapGuardian = newBorrowCapGuardian;

        // Emit NewBorrowCapGuardian(OldBorrowCapGuardian, NewBorrowCapGuardian)
        emit NewBorrowCapGuardian(oldBorrowCapGuardian, newBorrowCapGuardian);
    }

    /**
     * @notice Admin function to change the Pause Guardian
     * @param newPauseGuardian The address of the new Pause Guardian
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
     */
    function _setPauseGuardian(address newPauseGuardian) public returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PAUSE_GUARDIAN_OWNER_CHECK);
        }

        // Save current value for inclusion in log
        address oldPauseGuardian = pauseGuardian;

        // Store pauseGuardian with value newPauseGuardian
        pauseGuardian = newPauseGuardian;

        // Emit NewPauseGuardian(OldPauseGuardian, NewPauseGuardian)
        emit NewPauseGuardian(oldPauseGuardian, pauseGuardian);

        return uint(Error.NO_ERROR);
    }

    function _setMintPaused(ZKToken zkToken, bool state) public returns (bool) {
        require(markets[address(zkToken)].isListed, "market not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin");
        require(msg.sender == admin || state == true, "only admin");

        mintGuardianPaused[address(zkToken)] = state;
        emit ActionPaused(zkToken, "Mint", state);
        return state;
    }

    function _setBorrowPaused(ZKToken zkToken, bool state) public returns (bool) {
        require(markets[address(zkToken)].isListed, "market not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian");
        require(msg.sender == admin || state == true, "only admin");

        borrowGuardianPaused[address(zkToken)] = state;
        emit ActionPaused(zkToken, "Borrow", state);
        return state;
    }

    function _setTransferPaused(bool state) public returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian");
        require(msg.sender == admin || state == true, "only admin");

        transferGuardianPaused = state;
        emit ActionPaused("Transfer", state);
        return state;
    }

    function _setSeizePaused(bool state) public returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian");
        require(msg.sender == admin || state == true, "only admin");

        seizeGuardianPaused = state;
        emit ActionPaused("Seize", state);
        return state;
    }

    function _become(Unitroller unitroller) public {
        require(msg.sender == unitroller.admin(), "only unitroller admin");
        require(unitroller._acceptImplementation() == 0, "change not authorized");
    }

    /**
     * @notice Checks caller is admin, or this contract is becoming the new implementation
     */
    function adminOrInitializing() internal view returns (bool) {
        return msg.sender == admin || msg.sender == comptrollerImplementation;
    }

    /*** ZGT Distribution ***/

    /**
     * @notice Set ZGT speed for a single market
     * @param zkToken The market whose ZGT speed to update
     * @param supplySpeed New supply-side ZGT speed for market
     * @param borrowSpeed New borrow-side ZGT speed for market
     */
    function setZGTSpeedInternal(ZKToken zkToken, uint supplySpeed, uint borrowSpeed) internal {
        ensureListed(markets[address(zkToken)]);

        if (zgtSupplySpeeds[address(zkToken)] != supplySpeed) {
            // Supply speed updated so let's update supply state to ensure that
            //  1. ZGT accrued properly for the old speed, and
            //  2. ZGT accrued at the new speed starts after this block.
            updateZGTSupplyIndex(address(zkToken));

            // Update speed and emit event
            zgtSupplySpeeds[address(zkToken)] = supplySpeed;
            emit ZGTSupplySpeedUpdated(zkToken, supplySpeed);
        }

        if (zgtBorrowSpeeds[address(zkToken)] != borrowSpeed) {
            // Borrow speed updated so let's update borrow state to ensure that
            //  1. ZGT accrued properly for the old speed, and
            //  2. ZGT accrued at the new speed starts after this block.
            Exp memory borrowIndex = Exp({mantissa: zkToken.borrowIndex()});
            updateZGTBorrowIndex(address(zkToken), borrowIndex);

            // Update speed and emit event
            zgtBorrowSpeeds[address(zkToken)] = borrowSpeed;
            emit ZGTBorrowSpeedUpdated(zkToken, borrowSpeed);
        }
    }

    /**
     * @notice Accrue ZGT to the market by updating the supply index
     * @param zkToken The market whose supply index to update
     * @dev Index is a cumulative sum of the ZGT per zkToken accrued.
     */
    function updateZGTSupplyIndex(address zkToken) internal {
        ZGTMarketState storage supplyState = zgtSupplyState[zkToken];
        uint supplySpeed = zgtSupplySpeeds[zkToken];
        uint32 blockNumber = safe32(getBlockNumber(), "block number exceeds 32 bits");
        uint deltaBlocks = sub_(uint(blockNumber), uint(supplyState.block));
        if (deltaBlocks > 0 && supplySpeed > 0) {
            uint supplyTokens = ZKToken(zkToken).totalSupply();
            Double memory ratio = supplyTokens > 0 ? fraction( mul_(deltaBlocks, supplySpeed), supplyTokens) : Double({mantissa: 0});
            supplyState.index = safe224(add_(Double({mantissa: supplyState.index}), ratio).mantissa, "exceeds 224 bits");
            supplyState.block = blockNumber;
        } else if (deltaBlocks > 0) {
            supplyState.block = blockNumber;
        }
    }

    /**
     * @notice Accrue ZGT to the market by updating the borrow index
     * @param zkToken The market whose borrow index to update
     * @dev Index is a cumulative sum of the ZGT per zkToken accrued.
     */
    function updateZGTBorrowIndex(address zkToken, Exp memory marketBorrowIndex) internal {
        ZGTMarketState storage borrowState = zgtBorrowState[zkToken];
        uint borrowSpeed = zgtBorrowSpeeds[zkToken];
        uint32 blockNumber = safe32(getBlockNumber(), "block number exceeds 32 bits");
        uint deltaBlocks = sub_(uint(blockNumber), uint(borrowState.block));
        if (deltaBlocks > 0 && borrowSpeed > 0) {
            uint borrowAmount = div_(ZKToken(zkToken).totalBorrows(), marketBorrowIndex);
            Double memory ratio = borrowAmount > 0 ? fraction(mul_(deltaBlocks, borrowSpeed), borrowAmount) : Double({mantissa: 0});
            borrowState.index = safe224(add_(Double({mantissa: borrowState.index}), ratio).mantissa, "exceeds 224 bits");
            borrowState.block = blockNumber;
        } else if (deltaBlocks > 0) {
            borrowState.block = blockNumber;
        }
    }

    /**
     * @notice Calculate ZGT accrued by a supplier and possibly transfer it to them
     * @param zkToken The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute ZGT to
     */
    function distributeSupplierZGT(address zkToken, address supplier) internal {
        // TODO: Don't distribute supplier ZGT if the user is not in the supplier market.
        // This check should be as gas efficient as possible as distributeSupplierComp is called in many places.
        // - We really don't want to call an external contract as that's quite expensive.

        ZGTMarketState storage supplyState = zgtSupplyState[zkToken];
        uint supplyIndex = supplyState.index;
        uint supplierIndex = zgtSupplierIndex[zkToken][supplier];

        // Update supplier's index to the current index since we are distributing accrued ZGT
        zgtSupplierIndex[zkToken][supplier] = supplyIndex;

        if (supplierIndex == 0 && supplyIndex >= zgtInitialIndex) {
            // Covers the case where users supplied tokens before the market's supply state index was set.
            // Rewards the user with ZGT accrued from the start of when supplier rewards were first
            // set for the market.
            supplierIndex = zgtInitialIndex;
        }

        // Calculate change in the cumulative sum of the ZGT per zkToken accrued
        Double memory deltaIndex = Double({mantissa: sub_(supplyIndex, supplierIndex)});

        uint supplierTokens = ZKToken(zkToken).balanceOf(supplier);

        // Calculate ZGT accrued: zkTokenAmount * accruedPerZKToken
        uint supplierDelta = mul_(supplierTokens, deltaIndex);

        uint supplierAccrued = add_(zgtAccrued[supplier], supplierDelta);
        zgtAccrued[supplier] = supplierAccrued;

        emit DistributedSupplierZGT(ZKToken(zkToken), supplier, supplierDelta, supplyIndex);
    }

    /**
     * @notice Calculate ZGT accrued by a borrower and possibly transfer it to them
     * @dev Borrowers will not begin to accrue until after the first interaction with the protocol.
     * @param zkToken The market in which the borrower is interacting
     * @param borrower The address of the borrower to distribute ZGT to
     */
    function distributeBorrowerZGT(address zkToken, address borrower, Exp memory marketBorrowIndex) internal {
        // TODO: Don't distribute supplier ZGT if the user is not in the borrower market.
        // This check should be as gas efficient as possible as distributeBorrowerZGT is called in many places.
        // - We really don't want to call an external contract as that's quite expensive.

        uint borrowIndex = zgtBorrowState[zkToken].index;
        uint borrowerIndex = zgtBorrowerIndex[zkToken][borrower];

        // Update borrowers's index to the current index since we are distributing accrued ZGT
        zgtBorrowerIndex[zkToken][borrower] = borrowIndex;

        if (borrowerIndex == 0 && borrowIndex >= zgtInitialIndex) {
            // Covers the case where users borrowed tokens before the market's borrow state index was set.
            // Rewards the user with ZGT accrued from the start of when borrower rewards were first
            // set for the market.
            borrowerIndex = zgtInitialIndex;
        }

        // Calculate change in the cumulative sum of the ZGT per borrowed unit accrued
        Double memory deltaIndex = Double({mantissa: sub_(borrowIndex, borrowerIndex)});

        uint borrowerAmount = div_(ZKToken(zkToken).borrowBalanceStored(borrower), marketBorrowIndex);

        // Calculate ZGT accrued: zkTokenAmount * accruedPerBorrowedUnit
        uint borrowerDelta = mul_(borrowerAmount, deltaIndex);

        uint borrowerAccrued = add_(zgtAccrued[borrower], borrowerDelta);
        zgtAccrued[borrower] = borrowerAccrued;

        emit DistributedBorrowerZGT(ZKToken(zkToken), borrower, borrowerDelta, borrowIndex);
    }

    /**
     * @notice Calculate additional accrued ZGT for a contributor since last accrual
     * @param contributor The address to calculate contributor rewards for
     */
    function updateContributorRewards(address contributor) public {
        uint zgtSpeed = zgtContributorSpeeds[contributor];
        uint blockNumber = getBlockNumber();
        uint deltaBlocks = sub_(blockNumber, lastContributorBlock[contributor]);
        if (deltaBlocks > 0 && zgtSpeed > 0) {
            uint newAccrued = mul_(deltaBlocks, zgtSpeed);
            uint contributorAccrued = add_(zgtAccrued[contributor], newAccrued);

            zgtAccrued[contributor] = contributorAccrued;
            lastContributorBlock[contributor] = blockNumber;
        }
    }

    /**
     * @notice Claim all the ZGT accrued by holder in all markets
     * @param holder The address to claim ZGT for
     */
    function claimZGT(address holder) public {
        return claimZGT(holder, allMarkets);
    }

    /**
     * @notice Claim all the ZGT accrued by holder in the specified markets
     * @param holder The address to claim ZGT for
     * @param zkTokens The list of markets to claim ZGT in
     */
    function claimZGT(address holder, ZKToken[] memory zkTokens) public {
        address[] memory holders = new address[](1);
        holders[0] = holder;
        claimZGT(holders, zkTokens, true, true);
    }

    /**
     * @notice Claim all ZGT accrued by the holders
     * @param holders The addresses to claim ZGT for
     * @param zkTokens The list of markets to claim ZGT in
     * @param borrowers Whether or not to claim ZGT earned by borrowing
     * @param suppliers Whether or not to claim ZGT earned by supplying
     */
    function claimZGT(address[] memory holders, ZKToken[] memory zkTokens, bool borrowers, bool suppliers) public {
        require(!zgtClaimingPaused, "paused");

        for (uint i = 0; i < zkTokens.length; i++) {
            ZKToken zkToken = zkTokens[i];
            require(markets[address(zkToken)].isListed, "market not listed");
            if (borrowers == true) {
                Exp memory borrowIndex = Exp({mantissa: zkToken.borrowIndex()});
                updateZGTBorrowIndex(address(zkToken), borrowIndex);
                for (uint j = 0; j < holders.length; j++) {
                    distributeBorrowerZGT(address(zkToken), holders[j], borrowIndex);
                }
            }
            if (suppliers == true) {
                updateZGTSupplyIndex(address(zkToken));
                for (uint j = 0; j < holders.length; j++) {
                    distributeSupplierZGT(address(zkToken), holders[j]);
                }
            }
        }
        for (uint j = 0; j < holders.length; j++) {
            zgtAccrued[holders[j]] = grantZGTInternal(holders[j], zgtAccrued[holders[j]]);
        }
    }

    /**
     * @notice Transfer ZGT to the user
     * @dev Note: If there is not enough ZGT, we do not perform the transfer all.
     * @param user The address of the user to transfer ZGT to
     * @param amount The amount of ZGT to (possibly) transfer
     * @return The amount of ZGT which was NOT transferred to the user
     */
    function grantZGTInternal(address user, uint amount) internal returns (uint) {
        uint zgtRemaining = ZGT(getZGTAddress()).balanceOf(address(this));
        if (amount > 0 && amount <= zgtRemaining) {
            ZGT(getZGTAddress()).transfer(user, amount);
            return 0;
        }
        return amount;
    }

    /*** ZGT Distribution Admin ***/

    /**
     * @notice Transfer ZGT to the recipient
     * @dev Note: If there is not enough ZGT, we do not perform the transfer all.
     * @param recipient The address of the recipient to transfer ZGT to
     * @param amount The amount of ZGT to (possibly) transfer
     */
    function _grantZGT(address recipient, uint amount) public {
        require(adminOrInitializing(), "only admin");
        require(grantZGTInternal(recipient, amount) == 0, "insufficient ZGT");
        emit ZGTGranted(recipient, amount);
    }

    /**
     * @notice Set ZGT borrow and supply speeds for the specified markets.
     * @param zkTokens The markets whose ZGT speed to update.
     * @param supplySpeeds New supply-side ZGT speed for the corresponding market.
     * @param borrowSpeeds New borrow-side ZGT speed for the corresponding market.
     */
    function _setZGTSpeeds(ZKToken[] memory zkTokens, uint[] memory supplySpeeds, uint[] memory borrowSpeeds) public {
        require(adminOrInitializing(), "only admin");

        uint numTokens = zkTokens.length;
        require(numTokens == supplySpeeds.length && numTokens == borrowSpeeds.length, "invalid input");

        for (uint i = 0; i < numTokens; ++i) {
            ensureNonzeroAddress(address(zkTokens[i]));
            setZGTSpeedInternal(zkTokens[i], supplySpeeds[i], borrowSpeeds[i]);
        }
    }

    /**
     * @notice Set ZGT speed for a single contributor
     * @param contributor The contributor whose ZGT speed to update
     * @param zgtSpeed New ZGT speed for contributor
     */
    function _setContributorZGTSpeed(address contributor, uint zgtSpeed) public {
        require(adminOrInitializing(), "only admin");

        // note that ZGT speed could be set to 0 to halt liquidity rewards for a contributor
        updateContributorRewards(contributor);
        if (zgtSpeed == 0) {
            // release storage
            delete lastContributorBlock[contributor];
        } else {
            lastContributorBlock[contributor] = getBlockNumber();
        }
        zgtContributorSpeeds[contributor] = zgtSpeed;

        emit ContributorZGTSpeedUpdated(contributor, zgtSpeed);
    }

    /**
     * @notice Set ZGT claiming pause/unpause state
     */
    function _setZGTClaimingPaused(bool state) external {
        // Check caller is admin
    	require(msg.sender == admin, "no admin");

        zgtClaimingPaused = state;
        emit ActionZGTClaimingPaused(state);
    }

    /**
     * @dev Set ComptrollerLens contract address
     */
    function _setComptrollerLens(ComptrollerLensInterface comptrollerLens_) external returns (uint) {
        ensureAdmin();
        ensureNonzeroAddress(address(comptrollerLens_));
        address oldComptrollerLens = address(comptrollerLens);
        comptrollerLens = comptrollerLens_;
        emit NewComptrollerLens(oldComptrollerLens, address(comptrollerLens));

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Return all of the markets
     * @dev The automatic getter may be used to access an individual market.
     * @return The list of market addresses
     */
    function getAllMarkets() public view returns (ZKToken[] memory) {
        return allMarkets;
    }

    function accountHasMembership(address zkToken, address account) external view returns(bool) {
        return markets[zkToken].accountMembership[account];
    }

    /**
     * @notice Returns true if the given zkToken market has been deprecated
     * @dev All borrows in a deprecated zkToken market can be immediately liquidated
     * @param zkToken The market to check if deprecated
     */
    function isDeprecated(ZKToken zkToken) public view returns (bool) {
        return comptrollerLens.isDeprecated(address(this), zkToken);
    }

    function getBlockNumber() virtual public view returns (uint) {
        return block.number;
    }

    /**
     * @notice Return the address of the ZGT token
     * @return The address of ZGT
     */
    function getZGTAddress() virtual public view returns (address) {
        return 0xF2e759BAdEfc958899C2502ddc1521662B0B69A0;
    }
}
