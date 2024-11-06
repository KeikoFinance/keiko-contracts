// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../mocks/VaultOperations.sol";
import "../mocks/VaultManager.sol";
import "../mocks/VaultSorter.sol";
import "../mocks/StabilityPool.sol";
import "../mocks/KEI.sol";
import "../mocks/COLL.sol";

contract AdjustVaultTest is Test {
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

        // Create initial vaults for testing
        vm.startPrank(alice);
        vaultOperations.createVault(address(collToken), 100e18, 350e18, 110e18, address(0), address(0));
        vm.stopPrank();

        vm.startPrank(bob);
        vaultOperations.createVault(address(collToken), 200e18, 600e18, 110e18, address(0), address(0));
        vm.stopPrank();
    }

    function test_AdjustVault_AddCollateral() public {
        uint256 addCollateral = 50e18;

        vm.startPrank(alice);
        vaultOperations.adjustVault(address(collToken), addCollateral, 0, 0, 0, address(0), address(0));
        vm.stopPrank();

        (uint256 coll, uint256 debt, ) = vaultManager.getVaultData(address(collToken), alice);
        assertEq(coll, 150e18, "Incorrect collateral amount after adjustment");
        assertEq(debt, 350e18, "Debt should remain unchanged");
    }

    function test_AdjustVault_WithdrawCollateral() public {
        uint256 withdrawCollateral = 20e18;

        vm.startPrank(alice);
        vaultOperations.adjustVault(address(collToken), 0, withdrawCollateral, 0, 0, address(0), address(0));
        vm.stopPrank();

        (uint256 coll, uint256 debt, ) = vaultManager.getVaultData(address(collToken), alice);
        assertEq(coll, 80e18, "Incorrect collateral amount after withdrawal");
        assertEq(debt, 350e18, "Debt should remain unchanged");
    }

    function test_AdjustVault_AddDebt() public {
        uint256 addDebt = 100e18;

        vm.startPrank(alice);
        vaultOperations.adjustVault(address(collToken), 0, 0, addDebt, 0, address(0), address(0));
        vm.stopPrank();

        (uint256 coll, uint256 debt, ) = vaultManager.getVaultData(address(collToken), alice);
        assertEq(coll, 100e18, "Collateral should remain unchanged");
        assertEq(debt, 450e18, "Incorrect debt amount after adjustment");
    }

    function test_AdjustVault_RepayDebt() public {
        uint256 repayDebt = 50e18;

        vm.startPrank(alice);
        keiToken.approve(address(vaultOperations), repayDebt);
        vaultOperations.adjustVault(address(collToken), 0, 0, 0, repayDebt, address(0), address(0));
        vm.stopPrank();

        (uint256 coll, uint256 debt, ) = vaultManager.getVaultData(address(collToken), alice);
        assertEq(coll, 100e18, "Collateral should remain unchanged");
        assertEq(debt, 300e18, "Incorrect debt amount after repayment");
    }

    function test_AdjustVault_MultipleActions() public {
        uint256 addCollateral = 50e18;
        uint256 addDebt = 100e18;

        vm.startPrank(alice);
        vaultOperations.adjustVault(address(collToken), addCollateral, 0, addDebt, 0, address(0), address(0));
        vm.stopPrank();

        (uint256 coll, uint256 debt, ) = vaultManager.getVaultData(address(collToken), alice);
        assertEq(coll, 150e18, "Incorrect collateral amount after adjustment");
        assertEq(debt, 450e18, "Incorrect debt amount after adjustment");
    }

    function test_AdjustVault_ExceedMintCap() public {
        uint256 largeDebtAmount = 49500e18; // This will exceed the 50,000 KEI mint cap when added to existing debt

        vm.startPrank(alice);
        vm.expectRevert("Maximum debt for this asset exceeded");
        vaultOperations.adjustVault(address(collToken), 0, 0, largeDebtAmount, 0, address(0), address(0));
        vm.stopPrank();
    }

    function test_AdjustVault_BelowMinNetDebt() public {
        uint256 largeRepayment = 250e18; // This will bring the debt below the 300 KEI minimum

        vm.startPrank(alice);
        keiToken.approve(address(vaultOperations), largeRepayment);
        vm.expectRevert("Invalid minNetDebt");
        vaultOperations.adjustVault(address(collToken), 0, 0, 0, largeRepayment, address(0), address(0));
        vm.stopPrank();
    }

    function test_AdjustVault_InsufficientCollateral() public {
        uint256 largeWithdrawal = 90e18; // This will make the vault undercollateralized

        vm.startPrank(alice);
        vm.expectRevert();
        vaultOperations.adjustVault(address(collToken), 0, largeWithdrawal, 0, 0, address(0), address(0));
        vm.stopPrank();
    }

    function test_AdjustVault_UpdatesVaultSorter() public {
        uint256 addCollateral = 50e18;

        uint256 initialSize = vaultSorter.getSize(address(collToken));
        
        vm.startPrank(alice);
        vaultOperations.adjustVault(address(collToken), addCollateral, 0, 0, 0, address(0), address(0));
        vm.stopPrank();

        assertTrue(vaultSorter.contains(address(collToken), alice), "Vault should still be in VaultSorter");
        assertEq(vaultSorter.getSize(address(collToken)), initialSize, "VaultSorter size should not change");
    }
}