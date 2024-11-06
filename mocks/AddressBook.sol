// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./dependencies/Ownable.sol";
import "./dependencies/VaultMath.sol";

contract AddressBook is Ownable {
	address public debtToken;
	address public priceFeed;
	address public vaultSorter;
	address public stabilityPool;
	address public treasuryAddress;
	address public vaultManager;
	address public vaultOperations;
	address public keikoDeployer;

	bool public isAddressSetupInitialized;

	function setAddresses(address[] calldata _addresses) external onlyOwner {
		require(!isAddressSetupInitialized, "Setup is already initialized");

		/*for (uint i = 0; i < 7; i++) {
			require(_addresses[i] != address(0), "Invalid address");
		}*/

		debtToken = _addresses[0];
		priceFeed = _addresses[1];
		vaultSorter = _addresses[2];
		stabilityPool = _addresses[3];
		vaultManager = _addresses[4];
		vaultOperations = _addresses[5];
		treasuryAddress = _addresses[6];
		keikoDeployer = msg.sender;

		isAddressSetupInitialized = true;
	}

	modifier onlyVaultOperations() {
        require(msg.sender == vaultOperations, "Only callable by VaultOperations");
        _;
    }

	modifier onlyVaultManager() {
        require(msg.sender == vaultManager, "Only callable by VaultManager");
        _;
    }

	modifier onlyStabilityPool() {
        require(msg.sender == stabilityPool, "Only callable by SP");
        _;
    }
}