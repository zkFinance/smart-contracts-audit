// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./ZKErc20.sol";

/**
 * @title zkFinance's ZKErc20Delegate Contract
 * @notice ZKTokens which wrap an EIP-20 underlying and are delegated to
 * @author zkFinance
 */
contract ZKErc20Delegate is ZKErc20, ZKDelegateInterface {
    /**
     * @notice Construct an empty delegate
     */
    constructor() {}

    /**
     * @notice Called by the delegator on a delegate to initialize it for duty
     * @param data The encoded bytes data for any initialization
     */
    function _becomeImplementation(bytes memory data) virtual override public {
        // Shh -- currently unused
        data;

        // Shh -- we don't ever want this hook to be marked pure
        if (false) {
            implementation = address(0);
        }

        require(msg.sender == admin, "only the admin may call _becomeImplementation");
    }

    /**
     * @notice Called by the delegator on a delegate to forfeit its responsibility
     */
    function _resignImplementation() virtual override public {
        // Shh -- we don't ever want this hook to be marked pure
        if (false) {
            implementation = address(0);
        }

        require(msg.sender == admin, "only the admin may call _resignImplementation");
    }
}
