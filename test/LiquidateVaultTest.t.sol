// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../mocks/VaultOperations.sol";
import "../mocks/VaultManager.sol";
import "../mocks/VaultSorter.sol";
import "../mocks/StabilityPool.sol";
import "../mocks/KEI.sol";
import "../mocks/COLL.sol";

import "forge-std/console.sol";

contract LiquidateVaultTest is Test {
    VaultOperations public vaultOperations;
    VaultManager public vaultManager;
    VaultSorter public vaultSorter;
    StabilityPool public stabilityPool;
    KEI public keiToken;
    COLL public collToken;
    COLL public coll2Token;
    COLL public coll3Token;

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public carol = address(0x3);
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
        coll2Token = new COLL();
        coll3Token = new COLL();

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

        // Set up COLL2 and COLL3 similar to COLL
        vaultManager.addNewCollateral(address(coll2Token), 18);
        stabilityPool.addCollateralType(address(coll2Token));

        vaultManager.setCollateralParameters(
            address(coll2Token),
            125e18,  // MIN MCR RANGE - 125%
            160e18,  // MAX MCR RANGE - 160%
            25e16,   // MCR FACTOR - 0.25
            50e15,   // BASE FEE - 2.5%
            150e15,  // MAX FEE - 15%
            200e18,  // MINDEBT - 200 KEI
            50000e18, // MINTCAP - 50,000 KEI
            50e15    // Liquidation Penalty - 5%
        );

        vaultManager.addNewCollateral(address(coll3Token), 18);
        vaultManager.setCollateralParameters(
            address(coll3Token),
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

        // Fund test accounts with COLL
        collToken.transfer(alice, INITIAL_BALANCE);
        collToken.transfer(bob, INITIAL_BALANCE);
        collToken.transfer(carol, INITIAL_BALANCE);

        coll2Token.transfer(alice, INITIAL_BALANCE);
        coll2Token.transfer(bob, INITIAL_BALANCE);
        coll2Token.transfer(carol, INITIAL_BALANCE);

        coll3Token.transfer(alice, INITIAL_BALANCE);
        coll3Token.transfer(bob, INITIAL_BALANCE);
        coll3Token.transfer(carol, INITIAL_BALANCE);

        // Mint KEI tokens for test accounts
        keiToken.mint(alice, INITIAL_BALANCE);
        keiToken.mint(bob, INITIAL_BALANCE);
        keiToken.mint(carol, INITIAL_BALANCE);

        // Approve collateral
        vm.startPrank(alice);
        collToken.approve(address(vaultOperations), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        collToken.approve(address(vaultOperations), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(carol);
        collToken.approve(address(vaultOperations), type(uint256).max);
        vm.stopPrank();
        
        stabilityPool.addCollateralType(address(collToken));
        stabilityPool.addCollateralType(address(coll2Token));
        stabilityPool.addCollateralType(address(coll3Token));
    }

    function test_LiquidateVault_LiquidateVault() public {
        vm.startPrank(alice);
        vaultOperations.createVault(address(collToken), 100e18, 300e18, 110e18, address(0), address(0));
        vm.stopPrank();

        // Setup: Carol deposits to StabilityPool
        vm.startPrank(carol);
        keiToken.approve(address(stabilityPool), 1000e18);
        address[] memory assets = new address[](1);
        assets[0] = address(collToken);
        stabilityPool.deposit(1000e18, assets);
        vm.stopPrank();

        // Reduce price to make Alice's vault undercollateralized
        vaultOperations.changePrice(3 * 1e18); // 3 KEI per COLL
        vaultManager.changePrice(3 * 1e18);

        // Liquidate Alice's vault
        vm.prank(bob);
        vaultOperations.liquidateVault(address(collToken), alice, address(0), address(0));

        // Check if Alice's vault is closed
        (uint256 aliceCollateral, uint256 aliceDebt,) = vaultManager.getVaultData(address(collToken), alice);
        assertEq(aliceCollateral, 0, "Alice's vault should have 0 collateral after liquidation");
        assertEq(aliceDebt, 0, "Alice's vault should have 0 debt after liquidation");

        // Check if StabilityPool balance decreased
        uint256 spBalance = stabilityPool.getTotalDebtTokenDeposits();
        assertEq(spBalance, 700e18, "StabilityPool balance should decrease by 300 KEI");

        // Check if collateral was distributed to StabilityPool
        uint256 spCollateral = collToken.balanceOf(address(stabilityPool));
        assertGt(spCollateral, 0, "StabilityPool should have received collateral");

        // Carol claims her share of the liquidated collateral
        vm.prank(carol);
        stabilityPool.withdraw(0, assets);

        // Check if Carol received the correct amount of collateral
        uint256 carolCollateral = collToken.balanceOf(carol);
        assertGt(carolCollateral, INITIAL_BALANCE, "Carol should have received collateral from liquidation");
    }

    function test_LiquidateVault_MultipleDepositorLiquidation() public {
        vm.startPrank(alice);
        vaultOperations.createVault(address(collToken), 100e18, 300e18, 110e18, address(0), address(0));
        vm.stopPrank();

        // Setup: Carol and Bob deposit to StabilityPool
        vm.startPrank(carol);
        keiToken.approve(address(stabilityPool), 500e18);
        address[] memory assets = new address[](1);
        assets[0] = address(collToken);
        stabilityPool.deposit(500e18, assets);
        vm.stopPrank();

        vm.startPrank(bob);
        keiToken.approve(address(stabilityPool), 500e18);
        stabilityPool.deposit(500e18, assets);
        vm.stopPrank();

        // Record initial collateral balances
        uint256 carolInitialColl = collToken.balanceOf(carol);
        uint256 bobInitialColl = collToken.balanceOf(bob);

        // Get Alice's initial collateral amount
        (uint256 aliceInitialColl, ,) = vaultManager.getVaultData(address(collToken), alice);

        // Reduce price to make Alice's vault undercollateralized
        vaultOperations.changePrice(3 * 1e18); // 3 KEI per COLL
        vaultManager.changePrice(3 * 1e18);

        // Liquidate Alice's vault
        vm.prank(address(this));
        vaultOperations.liquidateVault(address(collToken), alice, address(0), address(0));

        // Carol and Bob claim their share of the liquidated collateral
        vm.prank(carol);
        stabilityPool.withdraw(0, assets);
        vm.prank(bob);
        stabilityPool.withdraw(0, assets);

        // Check if Carol and Bob received the correct amount of collateral
        uint256 carolFinalColl = collToken.balanceOf(carol);
        uint256 bobFinalColl = collToken.balanceOf(bob);

        // Calculate expected rewards (half of Alice's collateral each)
        uint256 expectedReward = aliceInitialColl / 2;

        // Assert that Carol and Bob received their initial balance plus their share of Alice's collateral
        assertEq(carolFinalColl, carolInitialColl + expectedReward, "Carol should have received her initial balance plus half of Alice's collateral");
        assertEq(bobFinalColl, bobInitialColl + expectedReward, "Bob should have received his initial balance plus half of Alice's collateral");

        // Check if Carol and Bob received equal amounts of new collateral
        assertEq(carolFinalColl - carolInitialColl, bobFinalColl - bobInitialColl, "Carol and Bob should receive equal amounts of new collateral");

        // Verify that all of Alice's collateral was distributed
        assertEq((carolFinalColl - carolInitialColl) + (bobFinalColl - bobInitialColl), aliceInitialColl, "Sum of new collateral should equal Alice's liquidated collateral");
    }

    function test_LiquidateVault_PartialLiquidation() public {
        vm.startPrank(alice);
        vaultOperations.createVault(address(collToken), 100e18, 300e18, 110e18, address(0), address(0));
        vm.stopPrank();

        // Bob deposits to Stability Pool, but not enough to cover Alice's full debt
        vm.startPrank(bob);
        keiToken.approve(address(stabilityPool), 200e18);
        address[] memory assets = new address[](1);
        assets[0] = address(collToken);
        stabilityPool.deposit(200e18, assets);
        vm.stopPrank();

        // Reduce price to make Alice's vault undercollateralized
        vaultOperations.changePrice(3 * 1e18); // 3 KEI per COLL
        vaultManager.changePrice(3 * 1e18);

        // Liquidate Alice's vault (should be partial)
        vm.prank(address(this));
        vaultOperations.liquidateVault(address(collToken), alice, address(0), address(0));

        // Check Alice's vault after partial liquidation
        (uint256 remainingCollateral, uint256 remainingDebt,) = vaultManager.getVaultData(address(collToken), alice);
        assertGt(remainingCollateral, 0, "Alice should still have some collateral");
        assertGt(remainingDebt, 0, "Alice should still have some debt");
        assertEq(remainingDebt, 100e18, "Alice should have 100 KEI debt remaining");

        // Check Stability Pool
        uint256 spBalance = stabilityPool.getTotalDebtTokenDeposits();
        assertEq(spBalance, 0, "Stability Pool should be empty");

        // Check Bob's collateral gain
        vm.prank(bob);
        stabilityPool.withdraw(0, assets);
        uint256 bobCollateral = collToken.balanceOf(bob);
        assertGt(bobCollateral, INITIAL_BALANCE, "Bob should have gained some collateral");
    }

    function test_LiquidateVault_LiquidationRewards() public {
        vm.startPrank(alice);
        vaultOperations.createVault(address(collToken), 100e18, 300e18, 110e18, address(0), address(0));
        vm.stopPrank();

        // Setup: Carol and Bob deposit to StabilityPool
        vm.startPrank(carol);
        keiToken.approve(address(stabilityPool), 600e18);
        address[] memory assets = new address[](1);
        assets[0] = address(collToken);
        stabilityPool.deposit(600e18, assets);
        vm.stopPrank();

        vm.startPrank(bob);
        keiToken.approve(address(stabilityPool), 400e18);
        stabilityPool.deposit(400e18, assets);
        vm.stopPrank();

        // Record initial collateral balances
        uint256 carolInitialColl = collToken.balanceOf(carol);
        uint256 bobInitialColl = collToken.balanceOf(bob);

        // Get Alice's initial collateral amount
        (uint256 aliceInitialColl, ,) = vaultManager.getVaultData(address(collToken), alice);

        // Reduce price to make Alice's vault undercollateralized
        vaultOperations.changePrice(3 * 1e18); // 3 KEI per COLL
        vaultManager.changePrice(3 * 1e18);

        // Liquidate Alice's vault
        vm.prank(address(this));
        vaultOperations.liquidateVault(address(collToken), alice, address(0), address(0));

        // Carol and Bob claim their rewards
        vm.prank(carol);
        stabilityPool.withdraw(0, assets);
        vm.prank(bob);
        stabilityPool.withdraw(0, assets);

        // Check rewards
        uint256 carolFinalColl = collToken.balanceOf(carol);
        uint256 bobFinalColl = collToken.balanceOf(bob);

        // Calculate expected rewards
        uint256 totalDeposit = 600e18 + 400e18; // Carol's deposit + Bob's deposit
        uint256 carolExpectedReward = (aliceInitialColl * 600e18) / totalDeposit;
        uint256 bobExpectedReward = (aliceInitialColl * 400e18) / totalDeposit;

        // Assert that Carol and Bob received their initial balance plus their share of Alice's collateral
        assertEq(carolFinalColl, carolInitialColl + carolExpectedReward, "Carol should have received her share of liquidated collateral");
        assertEq(bobFinalColl, bobInitialColl + bobExpectedReward, "Bob should have received his share of liquidated collateral");

        // Check if rewards are proportional to deposits
        uint256 carolReward = carolFinalColl - carolInitialColl;
        uint256 bobReward = bobFinalColl - bobInitialColl;
        assertEq(carolReward * 2, bobReward * 3, "Carol's reward should be exactly 1.5 times Bob's reward");

        // Verify that all of Alice's collateral was distributed
        assertEq(carolReward + bobReward, aliceInitialColl, "Sum of rewards should equal Alice's liquidated collateral");
    }

    function test_LiquidateVault_NonExistentVault() public {
        // Setup: Ensure we have a valid collateral type
        address nonExistentOwner = address(0x1234);
        uint256 initialTotalCollateral = vaultOperations.totalCollateral(address(collToken));
        uint256 initialTotalDebt = vaultOperations.totalDebt(address(collToken));

        // Attempt to liquidate a non-existent vault
        vm.expectRevert("Vault doesnt exist");
        vaultOperations.liquidateVault(address(collToken), nonExistentOwner, address(0), address(0));

        // Double-check that the vault truly doesn't exist
        (uint256 collateralAmount, uint256 debtAmount, ) = vaultManager.getVaultData(address(collToken), nonExistentOwner);
        assertEq(collateralAmount, 0, "Collateral amount should be 0 for non-existent vault");
        assertEq(debtAmount, 0, "Debt amount should be 0 for non-existent vault");

        // Ensure no changes occurred in the system
        uint256 totalSystemCollateral = vaultOperations.totalCollateral(address(collToken));
        uint256 totalSystemDebt = vaultOperations.totalDebt(address(collToken));
        assertEq(totalSystemCollateral, initialTotalCollateral, "Total system collateral should remain unchanged");
        assertEq(totalSystemDebt, initialTotalDebt, "Total system debt should remain unchanged");

    }

    function test_LiquidateVault_MultipleLiquidations() public {
        uint256 initialTotalCollateral = vaultOperations.totalCollateral(address(collToken));
        uint256 initialTotalDebt = vaultOperations.totalDebt(address(collToken));
        uint256 initialActiveVaults = vaultOperations.activeVaults();

        // Setup: Create multiple vaults
        address[] memory vaultOwners = new address[](3);
        vaultOwners[0] = address(0x11);
        vaultOwners[1] = address(0x22);
        vaultOwners[2] = address(0x33);

        for (uint i = 0; i < vaultOwners.length; i++) {
            deal(address(collToken), vaultOwners[i], 1000e18);
            deal(address(keiToken), vaultOwners[i], 1000e18);
            
            vm.startPrank(vaultOwners[i]);
            collToken.approve(address(vaultOperations), type(uint256).max);
            vaultOperations.createVault(address(collToken), 100e18, 300e18, 110e18, address(0), address(0));
            vm.stopPrank();
        }

        // Setup: Deposit to Stability Pool
        vm.startPrank(alice);
        keiToken.approve(address(stabilityPool), 1000e18);
        address[] memory assets = new address[](1);
        assets[0] = address(collToken);
        stabilityPool.deposit(1000e18, assets);
        vm.stopPrank();

        // Record initial states
        uint256 initialStabilityPoolBalance = stabilityPool.getTotalDebtTokenDeposits();
        uint256 initialAliceCollateral = collToken.balanceOf(alice);

        // Reduce price to make vaults undercollateralized
        vaultOperations.changePrice(3 * 1e18); // 3 KEI per COLL
        vaultManager.changePrice(3 * 1e18);

        // Perform multiple liquidations
        for (uint i = 0; i < vaultOwners.length; i++) {
            vm.prank(address(this));
            vaultOperations.liquidateVault(address(collToken), vaultOwners[i], address(0), address(0));

            // Check vault state after liquidation
            (uint256 collateralAmount, uint256 debtAmount,) = vaultManager.getVaultData(address(collToken), vaultOwners[i]);
            assertEq(collateralAmount, 0, "Vault should have 0 collateral after liquidation");
            assertEq(debtAmount, 0, "Vault should have 0 debt after liquidation");
        }

        // Check final Stability Pool balance
        uint256 finalStabilityPoolBalance = stabilityPool.getTotalDebtTokenDeposits();
        assertEq(finalStabilityPoolBalance, initialStabilityPoolBalance - (300e18 * 3), "Stability Pool balance should be reduced by total liquidated debt");

        // Check Alice's collateral gain
        vm.prank(alice);
        stabilityPool.withdraw(0, assets);
        uint256 aliceCollateralGain = collToken.balanceOf(alice) - initialAliceCollateral;
        assertApproxEqAbs(aliceCollateralGain, 300e18, 1e15, "Alice should have gained all liquidated collateral");

        // Check system state
        uint256 totalSystemCollateral = vaultOperations.totalCollateral(address(collToken));
        uint256 totalSystemDebt = vaultOperations.totalDebt(address(collToken));
        assertEq(totalSystemCollateral / 1e18, initialTotalCollateral / 1e18, "Total system collateral should be 0 after all liquidations");
        assertEq(totalSystemDebt, initialTotalDebt, "Total system debt should be 0 after all liquidations");

        // Check active vaults
        uint256 activeVaults = vaultOperations.activeVaults();
        assertEq(activeVaults, initialActiveVaults, "There should be no active vaults after all liquidations");
    }

    function test_LiquidateVault_MultipleCollateralTypes() public {

        // Create vaults with different collateral types
        uint256 collAmount = 1000e18; // 200% collateralization for each
        uint256 debtAmount = 1000e18;  // Adjust this to ensure 200% collateralization

        vm.startPrank(alice);
        collToken.approve(address(vaultOperations), collAmount);
        coll2Token.approve(address(vaultOperations), collAmount);
        coll3Token.approve(address(vaultOperations), collAmount);
        vaultOperations.createVault(address(collToken), collAmount, debtAmount, 110e18, address(0), address(0));
        vaultOperations.createVault(address(coll2Token), collAmount, debtAmount, 110e18, address(0), address(0));
        vaultOperations.createVault(address(coll3Token), collAmount, debtAmount, 110e18, address(0), address(0));
        vm.stopPrank();


        // Ensure Stability Pool has enough balance
        vm.startPrank(bob);
        keiToken.approve(address(stabilityPool), debtAmount * 3);
        address[] memory assets = new address[](3);
        assets[0] = address(collToken);
        assets[1] = address(coll2Token);
        assets[2] = address(coll3Token);
        sortAddresses(assets);
        stabilityPool.deposit(debtAmount * 3, assets);
        vm.stopPrank();

        // Reduce prices to make vaults undercollateralized
        vaultOperations.changePrice(1 * 1e18); // 1 KEI per COLL for all collateral types
        vaultManager.changePrice(1 * 1e18);

        // Liquidate vaults
        vaultOperations.liquidateVault(address(collToken), alice, address(0), address(0));
        vaultOperations.liquidateVault(address(coll2Token), alice, address(0), address(0));
        vaultOperations.liquidateVault(address(coll3Token), alice, address(0), address(0));

        // Check that all vaults are liquidated
        (uint256 remainingColl1, uint256 remainingDebt1,) = vaultManager.getVaultData(address(collToken), alice);
        (uint256 remainingColl2, uint256 remainingDebt2,) = vaultManager.getVaultData(address(coll2Token), alice);
        (uint256 remainingColl3, uint256 remainingDebt3,) = vaultManager.getVaultData(address(coll3Token), alice);

        assertEq(remainingColl1, 0, "COLL vault should be fully liquidated");
        assertEq(remainingDebt1, 0, "COLL vault should be fully liquidated");
        assertEq(remainingColl2, 0, "COLL2 vault should be fully liquidated");
        assertEq(remainingDebt2, 0, "COLL2 vault should be fully liquidated");
        assertEq(remainingColl3, 0, "COLL3 vault should be fully liquidated");
        assertEq(remainingDebt3, 0, "COLL3 vault should be fully liquidated");

        // Bob withdraws from Stability Pool to claim liquidated collateral
        uint256 bobInitialColl1 = collToken.balanceOf(bob);
        uint256 bobInitialColl2 = coll2Token.balanceOf(bob);
        uint256 bobInitialColl3 = coll3Token.balanceOf(bob);

        vm.startPrank(bob);
        stabilityPool.withdraw(0, assets); // Withdraw all gains
        vm.stopPrank();

        // Check that bob received different types of collateral
        uint256 bobFinalColl1 = collToken.balanceOf(bob);
        uint256 bobFinalColl2 = coll2Token.balanceOf(bob);
        uint256 bobFinalColl3 = coll3Token.balanceOf(bob);

        assertGt(bobFinalColl1, bobInitialColl1, "Bob should have received COLL");
        assertGt(bobFinalColl2, bobInitialColl2, "Bob should have received COLL2");
        assertGt(bobFinalColl3, bobInitialColl3, "Bob should have received COLL3");

        // Check the amounts received, allowing for small discrepancies due to potential rounding or fees
        assertApproxEqAbs(bobFinalColl1 - bobInitialColl1, collAmount, 1e15, "Bob should have received most of the liquidated COLL");
        assertApproxEqAbs(bobFinalColl2 - bobInitialColl2, collAmount, 1e15, "Bob should have received most of the liquidated COLL2");
        assertApproxEqAbs(bobFinalColl3 - bobInitialColl3, collAmount, 1e15, "Bob should have received most of the liquidated COLL3");
    }

    function testStabilityPoolLiquidationAndWithdrawal() public {
        console.log("Starting Stability Pool Liquidation and Withdrawal Test");

        // Setup: Create a vault for Alice
        uint256 aliceCollateral = 1000e18;
        uint256 aliceDebt = 2800e18;
        uint256 mcr = 110e18; // 110% MCR

        vm.startPrank(alice);
        collToken.approve(address(vaultOperations), aliceCollateral);
        vaultOperations.createVault(address(collToken), aliceCollateral, aliceDebt, mcr, address(0), address(0));
        vm.stopPrank();

        // Bob deposits into Stability Pool
        uint256 bobDeposit = 5000e18; // More than Alice's debt to ensure full liquidation
        vm.startPrank(bob);
        keiToken.approve(address(stabilityPool), bobDeposit);
        address[] memory assets = new address[](1);
        assets[0] = address(collToken);
        stabilityPool.deposit(bobDeposit, assets);
        vm.stopPrank();

        console.log("Bob deposited into Stability Pool:", bobDeposit / 1e18, "KEI");

        // Record initial balances
        uint256 bobInitialKEIBalance = keiToken.balanceOf(bob);
        uint256 bobInitialCOLLBalance = collToken.balanceOf(bob);
        uint256 initialStabilityPoolBalance = stabilityPool.getTotalDebtTokenDeposits();

        console.log("Initial Stability Pool Balance:", initialStabilityPoolBalance / 1e18, "KEI");

        // Reduce price to make Alice's vault undercollateralized
        uint256 newPrice = 3e18; // This will make CR about 100%, below the MCR
        vaultOperations.changePrice(newPrice);
        vaultManager.changePrice(newPrice);

        console.log("COLL price reduced to:", newPrice / 1e18, "KEI");

        uint256 newCR = vaultManager.calculateCR(address(collToken), alice);
        console.log("Alice's new CR:", newCR / 1e16, "%");

        // Perform liquidation
        vaultOperations.liquidateVault(address(collToken), alice, address(0), address(0));

        console.log("Alice's vault liquidated");

        // Bob withdraws from Stability Pool
        vm.startPrank(bob);
        stabilityPool.withdraw(bobDeposit, assets);
        vm.stopPrank();

        console.log("Bob withdrew from Stability Pool");

        // Calculate expected values
        uint256 expectedKEIWithdrawn = bobDeposit - aliceDebt;
        uint256 liquidationPenalty = vaultManager.getLiquidationPenalty(address(collToken));
        uint256 totalLiquidationAmount = aliceDebt + (aliceDebt * liquidationPenalty / 1e18);
        uint256 expectedCOLLReceived = (totalLiquidationAmount * 1e18) / newPrice;

        console.log("Expected KEI withdrawn:", expectedKEIWithdrawn / 1e18);
        console.log("Expected COLL received:", expectedCOLLReceived / 1e18);

        // Check Bob's final balances
        uint256 bobFinalKEIBalance = keiToken.balanceOf(bob);
        uint256 bobFinalCOLLBalance = collToken.balanceOf(bob);

        console.log("Bob's KEI balance change:", (bobFinalKEIBalance - bobInitialKEIBalance) / 1e18);
        console.log("Bob's COLL balance change:", (bobFinalCOLLBalance - bobInitialCOLLBalance) / 1e18);

        // Verify KEI withdrawal
        assertEq(
            bobFinalKEIBalance - bobInitialKEIBalance, 
            expectedKEIWithdrawn, 
            "Incorrect KEI withdrawn from Stability Pool"
        );

        // Verify COLL received
        assertEq(
            bobFinalCOLLBalance - bobInitialCOLLBalance, 
            expectedCOLLReceived, 
            "Incorrect COLL received from liquidation"
        );

        // Verify Stability Pool balance
        uint256 finalStabilityPoolBalance = stabilityPool.getTotalDebtTokenDeposits();
        console.log("Final Stability Pool Balance:", finalStabilityPoolBalance / 1e18, "KEI");

        assertEq(
            finalStabilityPoolBalance, 
            initialStabilityPoolBalance - aliceDebt - 2000e18, 
            "Incorrect final Stability Pool balance"
        );

        // Verify Alice's vault is liquidated
        (uint256 aliceRemainingCollateral, uint256 aliceRemainingDebt,) = vaultManager.getVaultData(address(collToken), alice);
        console.log("Alice's remaining collateral:", aliceRemainingCollateral / 1e18, "COLL");
        console.log("Alice's remaining debt:", aliceRemainingDebt / 1e18, "KEI");

        assertEq(aliceRemainingCollateral, 0, "Alice's vault should have no remaining collateral");
        assertEq(aliceRemainingDebt, 0, "Alice's vault should have no remaining debt");

        console.log("Stability Pool Liquidation and Withdrawal Test completed successfully");
    }

    // Helper function to sort addresses
    function sortAddresses(address[] memory addrs) internal pure {
        for (uint i = 0; i < addrs.length - 1; i++) {
            for (uint j = 0; j < addrs.length - i - 1; j++) {
                if (addrs[j] > addrs[j + 1]) {
                    (addrs[j], addrs[j + 1]) = (addrs[j + 1], addrs[j]);
                }
            }
        }
    }
}