/*
________/\\\__________________/\\\________/\\\__/\\\\\\\\\\\\\\\__/\\\\\\\\\\\__________________/\\\_______        
 ____/\\\\\\\\\\\_____________\/\\\_____/\\\//__\/\\\///////////__\/////\\\///_______________/\\\\\\\\\\\___       
  __/\\\///\\\////\\___________\/\\\__/\\\//_____\/\\\_________________\/\\\________________/\\\///\\\////\\_      
   _\////\\\\\\__\//____________\/\\\\\\//\\\_____\/\\\\\\\\\\\_________\/\\\_______________\////\\\\\\__\//__     
    ____\////\\\\\\______________\/\\\//_\//\\\____\/\\\///////__________\/\\\__________________\////\\\\\\____    
     __/\\__\/\\\///\\\___________\/\\\____\//\\\___\/\\\_________________\/\\\________________/\\__\/\\\///\\\_   
      _\///\\\\\\\\\\\/____________\/\\\_____\//\\\__\/\\\_________________\/\\\_______________\///\\\\\\\\\\\/__  
       ___\/////\\\///______________\/\\\______\//\\\_\/\\\\\\\\\\\\\\\__/\\\\\\\\\\\_____________\/////\\\///___  
        _______\///__________________\///________\///__\///////////////__\///////////__________________\///________

*/

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./dependencies/ERC20.sol";
import "./dependencies/Ownable.sol";
import "./AddressBook.sol";

contract KEI is Ownable, ERC20, AddressBook {
    uint8 private constant DECIMALS = 18;
    address private constant acc2 = 0xAb8483F64d9C6d1EcF9b849Ae677dD3315835cb2; // REMOVE IN PROD

    mapping(address => uint256) public timelock;
    mapping(address => bool) public allowanceWhitelist;
    mapping(address => bool) public mintWhitelist;

    bool public emergencyStopMinting;
    bool public emergencyStopBurn;

    constructor() ERC20("KEI Stablecoin", "KEI", DECIMALS) {
        _mint(msg.sender, 1000000000000000000000000); // 1000
        _mint(acc2, 5000 * 1e18);
    }

    /* --------------- OVERRIDDEN ERC20 LOGIC --------------------- */

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (allowanceWhitelist[msg.sender]) {
            // For whitelisted addresses, we bypass allowance checking
            balanceOf[from] -= amount;
            unchecked {
                balanceOf[to] += amount;
            }
            emit Transfer(from, to, amount);
            return true;
        } else {
            // Use the standard ERC20 transferFrom for others
            return super.transferFrom(from, to, amount);
        }
    }

    /* --------------- MAIN FUNCTIONS --------------------- */

    function mint(address recipient, uint256 amount) public {
        require(mintWhitelist[msg.sender], "Not whitelisted to mint");
        _mint(recipient, amount);
    }

    function burn(address from, uint256 amount) public {
        //require(!emergencyStopBurn, "Burning has been stopped");
        _burn(from, amount);
    }

    /* --------------- WHITELIST FUNCTIONS --------------------- */

    function isWhitelisted(address addy) public view returns(bool) {
        return allowanceWhitelist[addy];
    }

    function addWhitelist(address _address) public {
        //require(block.timestamp > timelock[_address], "Address is still timelocked");
        allowanceWhitelist[_address] = true;
        mintWhitelist[_address] = true;

        // Emit an event for changing the whitelist status
        emit WhitelistChanged(_address, true);
    }

    function removeWhitelist(address _address) external {
        allowanceWhitelist[_address] = false;
        mintWhitelist[_address] = true;

        // Emit an event for changing the whitelist status
        emit WhitelistChanged(_address, false);
    }

    event WhitelistChanged(address indexed _address, bool _status);
}