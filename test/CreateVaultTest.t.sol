// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../mocks/VaultOperations.sol";
import "../mocks/VaultManager.sol";
import "../mocks/VaultSorter.sol";
import "../mocks/StabilityPool.sol";
import "../mocks/KEI.sol";
import "../mocks/COLL.sol";
import "../mocks/PriceFeed.sol";

contract CreateVaultTest is Test {
    VaultOperations public vaultOperations;
    VaultManager public vaultManager;
    VaultSorter public vaultSorter;
    StabilityPool public stabilityPool;
    KEI public keiToken;
    COLL public collToken;

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public treasury = address(0x7777777777777777777777777777777777777777);
    uint256 public constant INITIAL_BALANCE = 1000 ether;

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

        // Whitelist contracts for minting/burning
        keiToken.addWhitelist(address(vaultOperations));
        keiToken.addWhitelist(address(stabilityPool));
        
        // Fund test accounts
        collToken.transfer(alice, INITIAL_BALANCE);
        collToken.transfer(bob, INITIAL_BALANCE);

        // Approve collateral
        vm.startPrank(alice);
        collToken.approve(address(vaultOperations), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        collToken.approve(address(vaultOperations), type(uint256).max);
        vm.stopPrank();
    }

    function test_CreateVault_Success() public {
        uint256 collateralAmount = 100e18;
        uint256 debtAmount = 300e18;
        uint256 vaultMCR = 110e18; // 110% collateralization ratio

        vm.startPrank(alice);
        vaultOperations.createVault(address(collToken), collateralAmount, debtAmount, vaultMCR, address(0), address(0));
        vm.stopPrank();

        (uint256 coll, uint256 debt, uint256 mcr) = vaultManager.getVaultData(address(collToken), alice);
        assertEq(coll, collateralAmount, "Incorrect collateral amount");
        assertEq(debt, debtAmount, "Incorrect debt amount");
        assertEq(mcr, vaultMCR, "Incorrect MCR");
        assertEq(keiToken.balanceOf(alice), debtAmount, "Incorrect KEI balance");
    }

    function test_CreateVault_InsufficientCollateral() public {
        uint256 collateralAmount = 10e18; // Too low for the requested debt
        uint256 debtAmount = 300e18;
        uint256 vaultMCR = 110e18;

        vm.startPrank(alice);
        vm.expectRevert();
        vaultOperations.createVault(address(collToken), collateralAmount, debtAmount, vaultMCR, address(0), address(0));
        vm.stopPrank();
    }

    function test_CreateVault_BelowMinNetDebt() public {
        uint256 collateralAmount = 100e18;
        uint256 debtAmount = 299e18; // Below minNetDebt of 300 KEI
        uint256 vaultMCR = 110e18;

        vm.startPrank(alice);
        vm.expectRevert("Invalid minNetDebt");
        vaultOperations.createVault(address(collToken), collateralAmount, debtAmount, vaultMCR, address(0), address(0));
        vm.stopPrank();
    }

    function test_CreateVault_ExceedMintCap() public {
        uint256 collateralAmount = 10000e18;
        uint256 debtAmount = 50001e18; // Exceeds mintCap of 50,000 KEI
        uint256 vaultMCR = 110e18;

        vm.startPrank(alice);
        vm.expectRevert("Maximum debt for this asset exceeded");
        vaultOperations.createVault(address(collToken), collateralAmount, debtAmount, vaultMCR, address(0), address(0));
        vm.stopPrank();
    }

    function test_CreateVault_PriceChange() public {
        uint256 collateralAmount = 100e18;
        uint256 debtAmount = 300e18;
        uint256 vaultMCR = 110e18;

        // First, create a vault at the initial price
        vm.startPrank(alice);
        vaultOperations.createVault(address(collToken), collateralAmount, debtAmount, vaultMCR, address(0), address(0));
        vm.stopPrank();

        // Now change the price
        vaultOperations.changePrice(3 * 1e18); // Halve the price
        vaultManager.changePrice(3 * 1e18);

        // Try to create another vault with the same parameters
        vm.startPrank(bob);
        vm.expectRevert();
        vaultOperations.createVault(address(collToken), collateralAmount, debtAmount, vaultMCR, address(0), address(0));
        vm.stopPrank();

        // Create a vault with adjusted collateral for the new price
        uint256 adjustedCollateral = 200e18; // Double the collateral to compensate for halved price
        vm.startPrank(bob);
        vaultOperations.createVault(address(collToken), adjustedCollateral, debtAmount, vaultMCR, address(0), address(0));
        vm.stopPrank();

        (uint256 coll, uint256 debt, uint256 mcr) = vaultManager.getVaultData(address(collToken), bob);
        assertEq(coll, adjustedCollateral, "Incorrect collateral amount");
        assertEq(debt, debtAmount, "Incorrect debt amount");
        assertEq(mcr, vaultMCR, "Incorrect MCR");
    }

    function test_CreateVault_DuplicateVault() public {
        uint256 collateralAmount = 1000e18;
        uint256 debtAmount = 500e18;
        uint256 vaultMCR = 150e18;

        vm.startPrank(alice);
        collToken.approve(address(vaultOperations), collateralAmount * 2);
        
        vaultOperations.createVault(address(collToken), collateralAmount, debtAmount, vaultMCR, address(0), address(0));
        
        vm.expectRevert("Vault already exists for this asset");
        vaultOperations.createVault(address(collToken), collateralAmount, debtAmount, vaultMCR, address(0), address(0));
        vm.stopPrank();
    }

    function test_CreateVault_InvalidCollateral() public {
        uint256 collateralAmount = 1000e18;
        uint256 debtAmount = 500e18;
        uint256 vaultMCR = 600e18;

        vm.startPrank(alice);
        vm.expectRevert(); // Expect a revert due to invalid collateral address
        vaultOperations.createVault(address(0x123), collateralAmount, debtAmount, vaultMCR, address(0), address(0));
        vm.stopPrank();
    }

    function test_CreateVault_UpdatesTotalValues() public {
        uint256 collateralAmount = 1000e18;
        uint256 debtAmount = 500e18;
        uint256 vaultMCR = 150e18;

        uint256 initialTotalCollateral = vaultOperations.totalCollateral(address(collToken));
        uint256 initialTotalDebt = vaultOperations.totalDebt(address(collToken));
        uint256 initialProtocolDebt = vaultOperations.totalProtocolDebt();
        uint256 initialActiveVaults = vaultOperations.activeVaults();

        vm.startPrank(alice);
        collToken.approve(address(vaultOperations), collateralAmount);
        vaultOperations.createVault(address(collToken), collateralAmount, debtAmount, vaultMCR, address(0), address(0));
        vm.stopPrank();

        assertEq(vaultOperations.totalCollateral(address(collToken)), initialTotalCollateral + collateralAmount, "Incorrect total collateral");
        assertEq(vaultOperations.totalDebt(address(collToken)), initialTotalDebt + debtAmount, "Incorrect total debt");
        assertEq(vaultOperations.totalProtocolDebt(), initialProtocolDebt + debtAmount, "Incorrect total protocol debt");
        assertEq(vaultOperations.activeVaults(), initialActiveVaults + 1, "Incorrect active vaults count");
    }

    function test_CreateVault_UpdatesVaultSorter() public {
        uint256 collateralAmount = 1000e18;
        uint256 debtAmount = 500e18;
        uint256 vaultMCR = 150e18;

        vm.startPrank(alice);
        collToken.approve(address(vaultOperations), collateralAmount);
        vaultOperations.createVault(address(collToken), collateralAmount, debtAmount, vaultMCR, address(0), address(0));
        vm.stopPrank();

        assertTrue(vaultSorter.contains(address(collToken), alice), "Vault not added to VaultSorter");
        assertEq(vaultSorter.getSize(address(collToken)), 1, "Incorrect VaultSorter size");
    }
}