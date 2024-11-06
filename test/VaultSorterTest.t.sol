// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../mocks/VaultOperations.sol";
import "../mocks/VaultManager.sol";
import "../mocks/VaultSorter.sol";
import "../mocks/StabilityPool.sol";
import "../mocks/KEI.sol";
import "../mocks/COLL.sol";

contract VaultSorterTest is Test {
    VaultOperations public vaultOperations;
    VaultManager public vaultManager;
    VaultSorter public vaultSorter;
    StabilityPool public stabilityPool;
    KEI public keiToken;
    COLL public collToken;

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public carol = address(0x3);
    address public constant dave = address(0x4);
    address public treasury = address(0x7777777777777777777777777777777777777777);
    uint256 public constant INITIAL_BALANCE = 10000e18;

    function setUp() public {
        // Deploy contracts
        vaultManager = new VaultManager();
        vaultSorter = new VaultSorter();
        stabilityPool = new StabilityPool();
        keiToken = new KEI();
        collToken = new COLL();
        vaultOperations = new VaultOperations();

        // Set up addresses
        address[] memory addresses = new address[](7);
        addresses[0] = address(keiToken);
        addresses[1] = address(0); // No PriceFeed, we'll use collPrice
        addresses[2] = address(vaultSorter);
        addresses[3] = address(stabilityPool);
        addresses[4] = address(vaultManager);
        addresses[5] = address(vaultOperations);
        addresses[6] = treasury;

        vaultOperations.setAddresses(addresses);
        vaultManager.setAddresses(addresses);
        vaultSorter.setAddresses(addresses);
        stabilityPool.setAddresses(addresses);

        // Whitelist contracts for minting/burning
        keiToken.addWhitelist(address(vaultOperations));
        keiToken.addWhitelist(address(stabilityPool));
        keiToken.addWhitelist(address(this)); // Whitelist the test contract for minting

        // Set up collateral
        vaultManager.addNewCollateral(address(collToken), 18);
        vaultManager.setCollateralParameters(
            address(collToken),
            110e18,  // MIN MCR RANGE - 110%
            150e18,  // MAX MCR RANGE - 150%
            25e16,   // MCR FACTOR - 0.25
            25e15,   // BASE FEE - 2.5%
            200e15,  // MAX FEE - 20%
            300e18,  // MINDEBT - 300 KEI
            50000e18, // MINTCAP - 50,000 KEI
            25e15    // Liquidation Penalty - 2.5%
        );

        // Set initial collPrice
        vaultOperations.changePrice(6 * 1e18); // Set initial price to 6 KEI per COLL
        vaultManager.changePrice(6 * 1e18);

        // Fund test accounts
        collToken.transfer(alice, INITIAL_BALANCE);
        collToken.transfer(bob, INITIAL_BALANCE);
        collToken.transfer(carol, INITIAL_BALANCE);
        keiToken.mint(alice, INITIAL_BALANCE);
        keiToken.mint(bob, INITIAL_BALANCE);
        keiToken.mint(carol, INITIAL_BALANCE);

        // Approve collateral
        vm.startPrank(alice);
        collToken.approve(address(vaultOperations), type(uint256).max);
        keiToken.approve(address(vaultOperations), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        collToken.approve(address(vaultOperations), type(uint256).max);
        keiToken.approve(address(vaultOperations), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(carol);
        collToken.approve(address(vaultOperations), type(uint256).max);
        keiToken.approve(address(vaultOperations), type(uint256).max);
        vm.stopPrank();
        
        stabilityPool.addCollateralType(address(collToken));
    }

    function testInsertVaultsInOrder() public {
        _createVault(alice, 1000e18, 5000e18, 110e18);
        _createVault(bob, 1000e18, 2000e18, 110e18); 
        _createVault(carol, 1000e18, 3000e18, 110e18);

        assertEq(vaultSorter.getFirst(address(collToken)), bob, "bob should be first (highest collateral-to-debt ratio)");
        assertEq(vaultSorter.getLast(address(collToken)), alice, "alice should be last (lowest collateral-to-debt ratio)");
        assertEq(vaultSorter.getNext(address(collToken), bob), carol, "carol should be after bob");
        assertEq(vaultSorter.getNext(address(collToken), carol), alice, "alice should be after carol");

        // Additional checks
        assertEq(vaultSorter.getPrev(address(collToken), alice), carol, "carol should be before alice");
        assertEq(vaultSorter.getPrev(address(collToken), carol), bob, "bob should be before carol");
    }

    function testReInsertVault() public {
        _createVault(alice, 3001e18, 3000e18, 130e18);
        _createVault(bob, 3000e18, 3000e18, 130e18);

        assertEq(vaultSorter.getFirst(address(collToken)), alice, "alice should be first initially");

        // Adjust alice's vault to have a lower ARS
        vm.prank(alice);
        vaultOperations.adjustVaultMCR(address(collToken), 110e18, address(0), address(0));

        // Now alice should be last
        assertEq(vaultSorter.getFirst(address(collToken)), bob, "bob should be first after alice's adjustment");
        assertEq(vaultSorter.getLast(address(collToken)), alice, "alice should be last after adjustment");
    }

    function testRemoveVault() public {
        _createVault(alice, 1000e18, 3000e18, 110e18);
        _createVault(bob, 1000e18, 2000e18, 110e18);
        _createVault(carol, 1000e18, 2500e18, 110e18);

        // Remove carol's vault
        vm.prank(carol);
        vaultOperations.closeVault(address(collToken));

        // Check the new order: alice -> bob
        assertEq(vaultSorter.getFirst(address(collToken)), bob, "bob should be first");
        assertEq(vaultSorter.getLast(address(collToken)), alice, "alice should be last");
        assertEq(vaultSorter.getNext(address(collToken), bob), alice, "alice should be after bob");
        assertTrue(!vaultSorter.contains(address(collToken), carol), "carol's vault should be removed");
    }

    function testGetPrevAndNext() public {
        _createVault(alice, 1000e18, 3000e18, 110e18);
        _createVault(bob, 1000e18, 2000e18, 110e18);
        _createVault(carol, 1000e18, 2500e18, 110e18);

        assertEq(vaultSorter.getPrev(address(collToken), alice), carol, "alice should be before carol");
        assertEq(vaultSorter.getNext(address(collToken), bob), carol, "bob should be after carol");
    }

    function testInsertAndRetrieveMultipleVaults() public {
        _createVault(alice, 1000e18, 3000e18, 110e18);
        _createVault(bob, 1000e18, 2000e18, 110e18);
        _createVault(carol, 1000e18, 2500e18, 110e18);
        _createVault(dave, 1000e18, 1800e18, 110e18);

        address[] memory expectedOrder = new address[](4);
        expectedOrder[0] = dave;
        expectedOrder[1] = bob;
        expectedOrder[2] = carol;
        expectedOrder[3] = alice;

        address current = vaultSorter.getFirst(address(collToken));
        for (uint i = 0; i < 4; i++) {
            assertEq(current, expectedOrder[i], string(abi.encodePacked("Incorrect order at position ", i)));
            current = vaultSorter.getNext(address(collToken), current);
        }
    }

    function testGetSizeAndIsEmpty() public {
        assertTrue(vaultSorter.isEmpty(address(collToken)), "List should be empty initially");

        _createVault(alice, 1000e18, 3000e18, 120e18);
        _createVault(bob, 1000e18, 2000e18, 150e18);

        assertEq(vaultSorter.getSize(address(collToken)), 2, "Size should be 2 after adding two vaults");
        assertTrue(!vaultSorter.isEmpty(address(collToken)), "List should not be empty");

        vm.prank(alice);
        vaultOperations.closeVault(address(collToken));

        assertEq(vaultSorter.getSize(address(collToken)), 1, "Size should be 1 after removing one vault");
    }

    // Helper function to create a vault
    function _createVault(address user, uint256 collateral, uint256 debt, uint256 mcr) internal {
        vm.startPrank(user);
        deal(address(collToken), user, collateral);
        collToken.approve(address(vaultOperations), collateral);
        vaultOperations.createVault(address(collToken), collateral, debt, mcr, address(0), address(0));
        vm.stopPrank();
    }
}