pragma solidity ^0.8.10;

import "./ZKToken.sol";

interface ComptrollerLensInterface {
    function liquidateCalculateSeizeTokens(
        address comptroller,
        address zkTokenBorrowed,
        address zkTokenCollateral,
        uint actualRepayAmount
    ) external view returns (uint, uint);

    function getHypotheticalAccountLiquidity(
        address comptroller,
        address account,
        ZKToken zkTokenModify,
        uint redeemTokens,
        uint borrowAmount
    )
        external
        view
        returns (
            uint,
            uint,
            uint
        );

    function liquidateBorrowAllowed(
        address comptroller,
        address zkTokenBorrowed,
        address zkTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount
    ) external view returns (uint);

    function redeemAllowed(
        address comptroller,
        address zkToken,
        address redeemer,
        uint redeemTokens
    ) external view returns (uint);

    function seizeAllowed(
        address comptroller,
        address zkTokenCollateral,
        address zkTokenBorrowed,
        uint seizeTokens
    ) external returns (uint);

    function checkPartialBorrowAllowedAndReturn(
        address comptroller,
        address zkToken,
        address borrower,
        uint borrowAmount
    ) external returns (uint);

    function isDeprecated(address comptroller, ZKToken zkToken)
        external
        view
        returns (bool);
}
