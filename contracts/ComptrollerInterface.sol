// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

abstract contract ComptrollerInterface {
    /// @notice Indicator that this is a Comptroller contract (for inspection)
    bool public constant isComptroller = true;

    /*** Assets You Are In ***/

    function enterMarkets(address[] calldata zkTokens) virtual external returns (uint[] memory);
    function exitMarket(address zkToken) virtual external returns (uint);

    /*** Policy Hooks ***/

    function mintAllowed(address zkToken, address minter, uint mintAmount) virtual external returns (uint);
    function mintVerify(address zkToken, address minter, uint mintAmount, uint mintTokens) virtual external;

    function redeemAllowed(address zkToken, address redeemer, uint redeemTokens) virtual external returns (uint);
    function redeemVerify(address zkToken, address redeemer, uint redeemAmount, uint redeemTokens) virtual external;

    function borrowAllowed(address zkToken, address borrower, uint borrowAmount) virtual external returns (uint);
    function borrowVerify(address zkToken, address borrower, uint borrowAmount) virtual external;

    function repayBorrowAllowed(
        address zkToken,
        address payer,
        address borrower,
        uint repayAmount) virtual external returns (uint);
    function repayBorrowVerify(
        address zkToken,
        address payer,
        address borrower,
        uint repayAmount,
        uint borrowerIndex) virtual external;

    function liquidateBorrowAllowed(
        address zkTokenBorrowed,
        address zkTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount) virtual external returns (uint);
    function liquidateBorrowVerify(
        address zkTokenBorrowed,
        address zkTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount,
        uint seizeTokens) virtual external;

    function seizeAllowed(
        address zkTokenCollateral,
        address zkTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) virtual external returns (uint);
    function seizeVerify(
        address zkTokenCollateral,
        address zkTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) virtual external;

    function transferAllowed(address zkToken, address src, address dst, uint transferTokens) virtual external returns (uint);
    function transferVerify(address zkToken, address src, address dst, uint transferTokens) virtual external;

    /*** Liquidity/Liquidation Calculations ***/

    function liquidateCalculateSeizeTokens(
        address zkTokenBorrowed,
        address zkTokenCollateral,
        uint repayAmount) virtual external view returns (uint, uint);
}

interface IComptroller {
    function liquidationIncentiveMantissa() external view returns (uint);
}
