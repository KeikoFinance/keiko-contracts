/*
__/\\\________/\\\__/\\\\\\\\\\\\\\\__/\\\\\\\\\\\__/\\\________/\\\_______/\\\\\______        
 _\/\\\_____/\\\//__\/\\\///////////__\/////\\\///__\/\\\_____/\\\//______/\\\///\\\____       
  _\/\\\__/\\\//_____\/\\\_________________\/\\\_____\/\\\__/\\\//_______/\\\/__\///\\\__      
   _\/\\\\\\//\\\_____\/\\\\\\\\\\\_________\/\\\_____\/\\\\\\//\\\______/\\\______\//\\\_     
    _\/\\\//_\//\\\____\/\\\///////__________\/\\\_____\/\\\//_\//\\\____\/\\\_______\/\\\_    
     _\/\\\____\//\\\___\/\\\_________________\/\\\_____\/\\\____\//\\\___\//\\\______/\\\__   
      _\/\\\_____\//\\\__\/\\\_________________\/\\\_____\/\\\_____\//\\\___\///\\\__/\\\____  
       _\/\\\______\//\\\_\/\\\\\\\\\\\\\\\__/\\\\\\\\\\\_\/\\\______\//\\\____\///\\\\\/_____ 
        _\///________\///__\///////////////__\///////////__\///________\///_______\/////_______
*/

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./dependencies/ERC20.sol";
import "./dependencies/Ownable.sol";

contract KEIKO is Ownable, ERC20 {

    uint8 private constant DECIMALS = 18;

    address public keikoDeployer;
    address public communityIncentives;
    address public protocolTreasury;
    address public tokenDistributor;

    constructor() ERC20("KEIKO Token", "KEIKO", DECIMALS) {
        tgeBatchMint();
        renounceOwnership();
    }

    // is this alpha? (｡◕‿◕｡)
    function tgeBatchMint() public onlyOwner {

        _mint(protocolTreasury, 20 * 1e6 * 1e18); // Protocol Treasury
        _mint(protocolTreasury, 30 * 1e6 * 1e18); // Future Distribution Rounds
        _mint(communityIncentives, 20 * 1e6 * 1e18); // Community Incentives
        _mint(keikoDeployer, 15 * 1e6 * 1e18); // Team Allocation
        _mint(tokenDistributor, 15 * 1e6 * 1e18); // #1 Airdrop Round
 
    }
}