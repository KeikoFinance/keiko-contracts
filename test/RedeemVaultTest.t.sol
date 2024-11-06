// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../mocks/VaultOperations.sol";
import "../mocks/VaultManager.sol";
import "../mocks/VaultSorter.sol";
import "../mocks/StabilityPool.sol";
import "../mocks/KEI.sol";
import "../mocks/COLL.sol";

contract RedeemVaultTest is Test {
    VaultOperations public vaultOperations;
    VaultManager public vaultManager;
    VaultSorter public vaultSorter;
    StabilityPool public stabilityPool;
    KEI public keiToken;
    COLL public collToken;

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

    function test_RedeemVault_Basic() public {
        // Create a vault for Bob
        uint256 initialCollateral = 800e18;
        uint256 initialDebt = 1000e18;
        vm.startPrank(bob);
        vaultOperations.createVault(address(collToken), initialCollateral, initialDebt, 110e18, address(0), address(0));
        vm.stopPrank();

        // Carol redeems
        uint256 redemptionAmount = 1000e18;
        vm.startPrank(carol);
        uint256 carolInitialKEIBalance = keiToken.balanceOf(carol);
        uint256 carolInitialCOLLBalance = collToken.balanceOf(carol);
        vaultOperations.redeemVault(address(collToken), redemptionAmount, address(0), address(0));
        vm.stopPrank();

        // Check Carol's balances
        uint256 carolFinalKEIBalance = keiToken.balanceOf(carol);
        uint256 carolFinalCOLLBalance = collToken.balanceOf(carol);
        assertLt(carolFinalKEIBalance, carolInitialKEIBalance, "Carol's KEI balance should decrease");
        assertGt(carolFinalCOLLBalance, carolInitialCOLLBalance, "Carol's COLL balance should increase");

        // Check Bob's vault
        (uint256 bobCollateral, uint256 bobDebt,) = vaultManager.getVaultData(address(collToken), bob);
        
        // Calculate expected remaining collateral
        uint256 collateralPrice = 6e18; // As set in setUp()
        uint256 redemptionFee = vaultManager.getRedemptionFee();
        uint256 netRedemptionAmount = (redemptionAmount * (1e18 - redemptionFee)) / 1e18;
        uint256 collateralRedeemed = (netRedemptionAmount * 1e18) / collateralPrice;
        uint256 expectedRemainingCollateral = initialCollateral - collateralRedeemed;

        // Assert Bob's vault state
        assertEq(bobDebt, 0, "Bob's debt should be fully redeemed");
        assertApproxEqAbs(bobCollateral, expectedRemainingCollateral, 1e15, "Bob's remaining collateral should match the calculated amount");
        
        // Additional checks
        assertGt(bobCollateral, 0, "Bob should have some collateral left");
        uint256 collateralReduction = initialCollateral - bobCollateral;
        assertApproxEqAbs(collateralReduction, collateralRedeemed, 1e15, "Collateral reduction should match expected amount");

        // Check Carol's KEI and COLL balance changes
        uint256 carolKEIReduction = carolInitialKEIBalance - carolFinalKEIBalance;
        uint256 carolCOLLIncrease = carolFinalCOLLBalance - carolInitialCOLLBalance;
        assertApproxEqAbs(carolKEIReduction, redemptionAmount, 1e15, "Carol's KEI reduction should match redemption amount");
        assertApproxEqAbs(carolCOLLIncrease, collateralRedeemed, 1e15, "Carol's COLL increase should match redeemed collateral");
    }

    function test_RedeemVault_MultipleVaults() public {
        // Create vaults for Alice and Bob
        vm.startPrank(alice);
        vaultOperations.createVault(address(collToken), 1000e18, 3000e18, 120e18, address(0), address(0));
        vm.stopPrank();

        vm.startPrank(bob);
        vaultOperations.createVault(address(collToken), 800e18, 2400e18, 110e18, address(0), address(0));
        vm.stopPrank();

        // Carol redeems more than one vault's debt
        vm.startPrank(carol);
        uint256 carolInitialKEIBalance = keiToken.balanceOf(carol);
        uint256 carolInitialCOLLBalance = collToken.balanceOf(carol);
        vaultOperations.redeemVault(address(collToken), 4000e18, address(0), address(0));
        vm.stopPrank();

        // Check Carol's balances
        uint256 carolFinalKEIBalance = keiToken.balanceOf(carol);
        uint256 carolFinalCOLLBalance = collToken.balanceOf(carol);
        assertLt(carolFinalKEIBalance, carolInitialKEIBalance, "Carol's KEI balance should decrease");
        assertGt(carolFinalCOLLBalance, carolInitialCOLLBalance, "Carol's COLL balance should increase");

        // Check Bob's vault (should be fully redeemed in terms of debt)
        (uint256 bobCollateral, uint256 bobDebt,) = vaultManager.getVaultData(address(collToken), bob);
        assertEq(bobDebt, 0, "Bob's debt should be fully redeemed");
        assertLt(bobCollateral, 800e18, "Bob's collateral should decrease");
        
        // Calculate expected remaining collateral for Bob
        uint256 collateralPrice = 6e18; // As set in setUp()
        uint256 redemptionFee = vaultManager.getRedemptionFee();
        uint256 netRedemptionAmount = (2400e18 * (1e18 - redemptionFee)) / 1e18;
        uint256 expectedBobCollateralRedeemed = (netRedemptionAmount * 1e18) / collateralPrice;
        uint256 expectedBobRemainingCollateral = 800e18 - expectedBobCollateralRedeemed;
        assertApproxEqAbs(bobCollateral, expectedBobRemainingCollateral, 1e15, "Bob's remaining collateral should match the calculated amount");

        // Check Alice's vault (should be partially redeemed)
        (uint256 aliceCollateral, uint256 aliceDebt,) = vaultManager.getVaultData(address(collToken), alice);
        assertLt(aliceCollateral, 1000e18, "Alice's collateral should decrease");
        assertLt(aliceDebt, 3000e18, "Alice's debt should decrease");
        assertGt(aliceDebt, 0, "Alice's debt should not be fully redeemed");
        
        // Calculate expected remaining debt and collateral for Alice
        uint256 aliceRedemptionAmount = 4000e18 - 2400e18; // Total redemption minus Bob's debt
        uint256 netAliceRedemptionAmount = (aliceRedemptionAmount * (1e18 - redemptionFee)) / 1e18;
        uint256 expectedAliceCollateralRedeemed = (netAliceRedemptionAmount * 1e18) / collateralPrice;
        uint256 expectedAliceRemainingCollateral = 1000e18 - expectedAliceCollateralRedeemed;
        uint256 expectedAliceRemainingDebt = 3000e18 - aliceRedemptionAmount;
        assertApproxEqAbs(aliceCollateral, expectedAliceRemainingCollateral, 1e15, "Alice's remaining collateral should match the calculated amount");
        assertApproxEqAbs(aliceDebt, expectedAliceRemainingDebt, 1e15, "Alice's remaining debt should match the calculated amount");
    }

    function test_RedeemVault_SucceedsLimitedByDebt() public {
        // Create a vault for Alice
        vm.startPrank(alice);
        vaultOperations.createVault(address(collToken), 1000e18, 3000e18, 120e18, address(0), address(0));
        vm.stopPrank();

        // Carol tries to redeem more than her KEI balance and more than the vault's debt
        vm.startPrank(carol);
        uint256 carolInitialKEIBalance = keiToken.balanceOf(carol);
        uint256 carolInitialCOLLBalance = collToken.balanceOf(carol);
        
        // Attempt to redeem an amount larger than Carol's balance and the vault's debt
        uint256 largeRedemptionAmount = 20e28; // This is larger than Carol's balance and the vault's debt
        vaultOperations.redeemVault(address(collToken), largeRedemptionAmount, address(0), address(0));
        
        vm.stopPrank();

        // Verify the redemption was successful
        uint256 carolFinalKEIBalance = keiToken.balanceOf(carol);
        uint256 carolFinalCOLLBalance = collToken.balanceOf(carol);

        // Check that Carol's KEI balance decreased by the vault's debt amount
        assertEq(carolInitialKEIBalance - carolFinalKEIBalance, 3000e18, "Carol's KEI balance should decrease by the vault's debt");

        // Check that Carol received COLL tokens
        assertGt(carolFinalCOLLBalance, carolInitialCOLLBalance, "Carol should have received COLL tokens");

        // Check Alice's vault (should be fully redeemed)
        (uint256 aliceCollateral, uint256 aliceDebt,) = vaultManager.getVaultData(address(collToken), alice);
        assertEq(aliceDebt, 0, "Alice's vault debt should be fully redeemed");
        assertLt(aliceCollateral, 1000e18, "Alice's collateral should decrease");

        // Calculate expected remaining collateral for Alice
        uint256 collateralPrice = 6e18; // As set in setUp()
        uint256 redemptionFee = vaultManager.getRedemptionFee();
        uint256 netRedemptionAmount = (3000e18 * (1e18 - redemptionFee)) / 1e18;
        uint256 expectedAliceCollateralRedeemed = (netRedemptionAmount * 1e18) / collateralPrice;
        uint256 expectedAliceRemainingCollateral = 1000e18 - expectedAliceCollateralRedeemed;
        assertApproxEqAbs(aliceCollateral, expectedAliceRemainingCollateral, 1e15, "Alice's remaining collateral should match the calculated amount");
    }

    function test_RedeemVault_RevertsOnInsufficientBalance() public {
        // Create a large vault for Alice
        vm.startPrank(alice);
        vaultOperations.createVault(address(collToken), 2000e18, 6000e18, 120e18, address(0), address(0));
        vm.stopPrank();

        // Reduce Carol's KEI balance to a known amount
        uint256 carolInitialKEIBalance = 2000e18; // 2000 KEI
        vm.startPrank(carol);
        uint256 amountToBurn = keiToken.balanceOf(carol) - carolInitialKEIBalance;
        keiToken.burn(carol, amountToBurn);
        vm.stopPrank();

        // Verify Carol's initial balance
        assertEq(keiToken.balanceOf(carol), carolInitialKEIBalance, "Carol's initial KEI balance should be set correctly");

        // Carol tries to redeem more than her KEI balance
        vm.startPrank(carol);
        uint256 attemptedRedemptionAmount = 4000e18; // More than Carol's balance

        // Expect revert due to insufficient balance
        vm.expectRevert();
        vaultOperations.redeemVault(address(collToken), attemptedRedemptionAmount, address(0), address(0));
        vm.stopPrank();

        // Verify Carol's balance hasn't changed
        assertEq(keiToken.balanceOf(carol), carolInitialKEIBalance, "Carol's KEI balance should remain unchanged");

        // Verify Alice's vault hasn't changed
        (uint256 aliceCollateral, uint256 aliceDebt,) = vaultManager.getVaultData(address(collToken), alice);
        assertEq(aliceCollateral, 2000e18, "Alice's collateral should remain unchanged");
        assertEq(aliceDebt, 6000e18, "Alice's debt should remain unchanged");
    }

    function test_RedeemVault_GasUsage() public {
        vaultManager.setMintCap(address(collToken), 10e30);
        uint256 carolInitialKEIBalance = keiToken.balanceOf(carol);
        keiToken.burn(carol, carolInitialKEIBalance);

        // Create multiple vaults with different owners and varying debt amounts
        address[] memory vaultOwners = new address[](50);
        uint256[] memory debtAmounts = new uint256[](50);

        uint256 totalDebt;
        
        for (uint i = 0; i < 50; i++) {
            vaultOwners[i] = address(uint160(0x1000 + i));
            debtAmounts[i] = (i + 1) * 1000e18;
            
            vm.startPrank(vaultOwners[i]);
            deal(address(collToken), vaultOwners[i], debtAmounts[i] * 2);
            collToken.approve(address(vaultOperations), type(uint256).max);
            vaultOperations.createVault(address(collToken), debtAmounts[i] * 2, debtAmounts[i], 120e18, address(0), address(0));
            totalDebt += debtAmounts[i];
            vm.stopPrank();
        }

        // Ensure redeemer (carol) has enough KEI
        vm.startPrank(address(this));
        keiToken.mint(carol, totalDebt);
        vm.stopPrank();

        vm.startPrank(carol);
        keiToken.approve(address(vaultOperations), type(uint256).max);

        // Measure gas for a large redemption
        uint256 gasStart = gasleft();
        vaultOperations.redeemVault(address(collToken), totalDebt, address(0), address(0));
        uint256 gasUsed = gasStart - gasleft();

        vm.stopPrank();

        // Log gas used
        console.log("Gas used for large redemption:", gasUsed);

        uint256 gasLimit = 30000000;
        assertLt(gasUsed, gasLimit, "Gas usage exceeded limit");
        console.log(gasUsed);

        // Verify redemption was successful
        for (uint i = 0; i < 50; i++) {
            (,uint256 remainingDebt,) = vaultManager.getVaultData(address(collToken), vaultOwners[i]);
            assertEq(remainingDebt, 0, "Vault should be fully redeemed");
        }

        // Check carol's balances
        assertEq(keiToken.balanceOf(carol), 0, "Carol should have used all her KEI");
        assertGt(collToken.balanceOf(carol), 0, "Carol should have received COLL tokens");
    }

    function test_RedeemVault_NonExistentCollateral() public {
        uint256 carolInitialKEIBalance = keiToken.balanceOf(carol);
        keiToken.burn(carol, carolInitialKEIBalance);

        // Create a vault with the valid collateral first
        vm.startPrank(alice);
        vaultOperations.createVault(address(collToken), 1000e18, 3000e18, 120e18, address(0), address(0));
        vm.stopPrank();

        // Create a fake collateral address
        address fakeCollateral = address(0x1234567890123456789012345678901234567890);

        // Ensure Carol has some KEI to attempt the redemption
        vm.startPrank(address(this));
        keiToken.mint(carol, 1000e18);
        vm.stopPrank();

        // Carol attempts to redeem with the non-existent collateral
        vm.startPrank(carol);
        keiToken.approve(address(vaultOperations), 1000e18);
        
        // Expect the transaction to revert
        vm.expectRevert("No vaults available for redemption"); // Adjust this to match your actual error message
        vaultOperations.redeemVault(fakeCollateral, 1000e18, address(0), address(0));

        vm.stopPrank();

        // Verify that Carol's KEI balance hasn't changed
        assertEq(keiToken.balanceOf(carol), 1000e18, "Carol's KEI balance should remain unchanged");

        // Verify that the valid vault hasn't been affected
        (uint256 aliceCollateral, uint256 aliceDebt,) = vaultManager.getVaultData(address(collToken), alice);
        assertEq(aliceCollateral, 1000e18, "Alice's collateral should remain unchanged");
        assertEq(aliceDebt, 3000e18, "Alice's debt should remain unchanged");
    }

    function test_RedeemVault_WithRedemptionFee() public {
        uint256 carolInitialKEIBalance = keiToken.balanceOf(carol);
        keiToken.burn(carol, carolInitialKEIBalance);
        
        // Set up a redemption fee
        uint256 redemptionFee = 25e15; // 2.5% fee
        vaultManager.setRedemptionFee(redemptionFee);

        uint256 collPrice = 6;

        // Create a vault
        vm.startPrank(alice);
        vaultOperations.createVault(address(collToken), 1000e18, 3000e18, 120e18, address(0), address(0));
        vm.stopPrank();
        
        // Carol redeems
        vm.startPrank(carol);
        deal(address(keiToken), carol, 1000e18);
        carolInitialKEIBalance = keiToken.balanceOf(carol);
        keiToken.approve(address(vaultOperations), 1000e18);
        uint256 carolInitialCOLLBalance = collToken.balanceOf(carol);
        vaultOperations.redeemVault(address(collToken), 1000e18, address(0), address(0));
        vm.stopPrank();
        
        // Calculate expected amounts
        uint256 expectedKEIRedeemed = 1000e18;
        uint256 collateralToRedeem = expectedKEIRedeemed / collPrice; // 166.666... COLL
        uint256 feeInCOLL = (collateralToRedeem * redemptionFee) / 1e18;
        uint256 expectedCOLLReceived = collateralToRedeem - feeInCOLL;
        
        // Verify Carol's balances
        assertEq(keiToken.balanceOf(carol), carolInitialKEIBalance - expectedKEIRedeemed, "Carol's KEI balance should decrease by the redeemed amount");
        assertApproxEqAbs(collToken.balanceOf(carol), carolInitialCOLLBalance + expectedCOLLReceived, 1e15, "Carol should receive the correct amount of COLL tokens after fee");
        
        // Verify Alice's vault state
        (uint256 aliceCollateral, uint256 aliceDebt,) = vaultManager.getVaultData(address(collToken), alice);
        assertEq(aliceDebt, 3000e18 - expectedKEIRedeemed, "Alice's vault debt should decrease by the redeemed amount");
        assertEq(aliceCollateral, 1000e18 - expectedCOLLReceived, "Alice's vault collateral should decrease by the amount distribution to redeemer");
        
    }

    function test_RedeemVault_NoVaultsAvailable() public {
        // Carol tries to redeem when no vaults are available
        vm.startPrank(carol);
        vm.expectRevert(); // Expect the transaction to revert
        vaultOperations.redeemVault(address(collToken), 1000e18, address(0), address(0));
        vm.stopPrank();
    }
}