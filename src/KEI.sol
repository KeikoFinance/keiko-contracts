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

contract KEI is Ownable, ERC20 {
    mapping(address => bool) public whitelisted;
    mapping(address => bool) public whitelistRequested;
    mapping(address => uint256) public requestedWhitelistTimestamp;

    uint8 private constant DECIMALS = 18;
    uint256 public constant TIMELOCK_DURATION = 14 days;

    constructor(address vaultOperations, address stabilityPool) ERC20("KEI Stablecoin", "KEI", DECIMALS) {
        whitelisted[vaultOperations] = true;
        whitelisted[stabilityPool] = true;
    }

    /* --------------- OVERRIDDEN ERC20 LOGIC --------------------- */
    
    /*
     * @notice Transfers tokens from one address to another, with special handling for whitelisted addresses
     * @dev Whitelisted contracts can bypass the allowance check and transfer tokens from other addresses
     * @param from The address to transfer tokens from
     * @param to The address to transfer tokens to
     * @param amount The amount of tokens to transfer
     * @return bool Returns true if the transfer was successful
    */
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (whitelisted[msg.sender]) {
            // For whitelisted addresses, we bypass allowance checking
            balanceOf[from] -= amount;
            unchecked {
                balanceOf[to] += amount;
            }
            emit Transfer(from, to, amount);
            return true;
        } else {
            // Uses the standard ERC20 transferFrom for others
            return super.transferFrom(from, to, amount);
        }
    }

    /* --------------- MAIN FUNCTIONS --------------------- */

    function mint(address recipient, uint256 amount) public {
        require(whitelisted[msg.sender], "Not whitelisted to mint");
        _mint(recipient, amount);
    }

    function burn(address from, uint256 amount) public {
        require(whitelisted[msg.sender], "Not whitelisted to burn");
        _burn(from, amount);
    }

    /* --------------- WHITELIST FUNCTIONS --------------------- */

    /*
     * @notice Initiates a request to whitelist an address by starting the timelock period
     * @notice Given the admin key retains the ability to add debttoken minters for future 
               deployments or upgrades a long timelock (14d) is established.
     * @param _address The address to be considered for whitelisting
     * @dev Can only be called by the contract owner
    */
    function requestWhitelist(address _address) external onlyOwner {
        require(!whitelisted[_address], "Address already whitelisted");

        whitelistRequested[_address] = true;
        requestedWhitelistTimestamp[_address] = block.timestamp;
        emit WhitelistRequested(_address, block.timestamp);
    }

    /*
     * @notice Adds an address to the whitelist after the timelock period has passed
     * @param _address The address to be added to the whitelist
     * @dev Can only be called by the contract owner
    */
    function addWhitelist(address _address) external onlyOwner {
        require(!whitelisted[_address], "Address already whitelisted");
        require(whitelistRequested[_address], "Whitelist not requested");
        require(block.timestamp > requestedWhitelistTimestamp[_address] + TIMELOCK_DURATION, "Timelock period has not passed");

        whitelisted[_address] = true;
        delete requestedWhitelistTimestamp[_address];
        emit WhitelistChanged(_address, true);
    }

    /*
     * @notice Removes an address from the whitelist
     * @param _address The address to be removed from the whitelist
     * @dev Can only be called by the contract owner
    */
    function removeWhitelist(address _address) external onlyOwner {
        whitelistRequested[_address] = false;
        whitelisted[_address] = false;
        emit WhitelistChanged(_address, false);
    }

    /*
     * @notice Checks if an address is whitelisted
     * @param addy The address to check
     * @return bool Returns true if the address is whitelisted, false otherwise
    */
    function isWhitelisted(address _address) external view returns (bool) {
        return whitelisted[_address];
    }

    event WhitelistChanged(address indexed _address, bool _status);
    event WhitelistRequested(address indexed _address, uint256 _timestamp);
}
