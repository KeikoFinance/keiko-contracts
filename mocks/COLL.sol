// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20} from "./dependencies/ERC20.sol";

contract COLL is ERC20 {

    string private constant NAME = "COLL TOKEN";
    string private constant SYMBOL = "COLL";
    uint8 private constant DECIMALS = 18;

    constructor() ERC20(NAME, SYMBOL, DECIMALS) {
        _mint(msg.sender, 10000000 * 1e18);
    }
}