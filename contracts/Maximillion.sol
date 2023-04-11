// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./ZKEther.sol";

/**
 * @title zkFinance's Maximillion Contract
 * @author zkFinance
 */
contract Maximillion {
    /**
     * @notice The default zkEther market to repay in
     */
    ZKEther public zkEther;

    /**
     * @notice Construct a Maximillion to repay max in a ZKEther market
     */
    constructor(ZKEther zkEther_) public {
        zkEther = zkEther_;
    }

    /**
     * @notice msg.sender sends Ether to repay an account's borrow in the zkEther market
     * @dev The provided Ether is applied towards the borrow balance, any excess is refunded
     * @param borrower The address of the borrower account to repay on behalf of
     */
    function repayBehalf(address borrower) public payable {
        repayBehalfExplicit(borrower, zkEther);
    }

    /**
     * @notice msg.sender sends Ether to repay an account's borrow in a zkEther market
     * @dev The provided Ether is applied towards the borrow balance, any excess is refunded
     * @param borrower The address of the borrower account to repay on behalf of
     * @param zkEther_ The address of the zkEther contract to repay in
     */
    function repayBehalfExplicit(address borrower, ZKEther zkEther_) public payable {
        uint received = msg.value;
        uint borrows = zkEther_.borrowBalanceCurrent(borrower);
        if (received > borrows) {
            zkEther_.repayBorrowBehalf{value: borrows}(borrower);
            payable(msg.sender).transfer(received - borrows);
        } else {
            zkEther_.repayBorrowBehalf{value: received}(borrower);
        }
    }
}
