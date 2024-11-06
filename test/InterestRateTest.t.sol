// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../mocks/VaultOperations.sol";
import "../mocks/VaultManager.sol";
import "../mocks/VaultSorter.sol";
import "../mocks/StabilityPool.sol";
import "../mocks/KEI.sol";
import "../mocks/COLL.sol";

contract InterestRateTest is Test {
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

    function test_InterestRate_SimpleInterestAccrual() public {
        // Setup initial vault
        uint256 initialCollateral = 1000e18;
        uint256 initialDebt = 3000e18;
        uint256 mcr = 120e18; // 120% MCR

        vm.startPrank(alice);
        vaultOperations.createVault(address(collToken), initialCollateral, initialDebt, mcr, address(0), address(0));

        // Get initial vault data
        (, uint256 initialDebtAmount, ) = vaultManager.getVaultData(address(collToken), alice);
        
        // Advance time by 1 year (365 days)
        vm.warp(block.timestamp + 365 days);

        // Update vault interest
        (,uint256 currentDebtAmount,) = vaultOperations.updateVaultInterest(address(collToken), alice);

        // Calculate expected interest using compound interest formula
        uint256 interestRate = vaultManager.getVaultInterestRate(address(collToken), alice);
        uint256 baseRate = 1e18 + (interestRate / (365 * 24 * 60)); // per minute rate
        uint256 compoundFactor = VaultMath.decPow(baseRate, 365 * 24 * 60); // compound for a year
        uint256 expectedDebt = (initialDebtAmount * compoundFactor) / 1e18;

        // Assert that the current debt matches the expected debt
        assertApproxEqAbs(currentDebtAmount, expectedDebt, 1e17, "Debt after interest accrual doesn't match expected amount");

        vm.stopPrank();
    }

    function test_InterestRate_VariableInterestRates() public {
        // Setup initial vault
        uint256 initialCollateral = 1000e18;
        uint256 initialDebt = 3000e18;
        uint256 initialMCR = 120e18; // 120% MCR

        vm.startPrank(alice);
        vaultOperations.createVault(address(collToken), initialCollateral, initialDebt, initialMCR, address(0), address(0));

        // Record initial interest rate
        uint256 initialRate = vaultManager.getVaultInterestRate(address(collToken), alice);

        // Calculate expected interest for first 6 months
        uint256 baseRateFirstHalf = 1e18 + (initialRate / (365 * 24 * 60));
        uint256 compoundFactorFirstHalf = VaultMath.decPow(baseRateFirstHalf, 182 * 24 * 60);
        uint256 expectedDebtAfterSixMonths = (initialDebt * compoundFactorFirstHalf) / 1e18;

        // Advance time by 6 months and update interest
        vm.warp(block.timestamp + 182 days);
        (,uint256 debtAfterSixMonths,) = vaultOperations.updateVaultInterest(address(collToken), alice);

        // Check if the accrued debt matches the expected debt
        assertApproxEqAbs(debtAfterSixMonths, expectedDebtAfterSixMonths, 1e17, "Debt after first half-year should match expected");

        // Increase MCR to decrease interest rate
        uint256 newMCR = 150e18; // 150% MCR
        vaultOperations.adjustVaultMCR(address(collToken), newMCR, address(0), address(0));

        // Record new interest rate
        uint256 newRate = vaultManager.getVaultInterestRate(address(collToken), alice);

        // Verify that the new rate is lower
        assertTrue(newRate < initialRate, "Interest rate should decrease after increasing MCR");

        // Calculate expected interest for second 6 months
        uint256 baseRateSecondHalf = 1e18 + (newRate / (365 * 24 * 60));
        uint256 compoundFactorSecondHalf = VaultMath.decPow(baseRateSecondHalf, 183 * 24 * 60);
        uint256 expectedDebtAfterOneYear = (debtAfterSixMonths * compoundFactorSecondHalf) / 1e18;

        // Advance time by another 6 months and update interest
        vm.warp(block.timestamp + 183 days);
        (,uint256 debtAfterOneYear,) = vaultOperations.updateVaultInterest(address(collToken), alice);

        // Check if the accrued debt matches the expected debt for the full year
        assertApproxEqAbs(debtAfterOneYear, expectedDebtAfterOneYear, 1e17, "Debt after one year should match expected");

        // Calculate actual interest for each half
        uint256 actualInterestFirstHalf = debtAfterSixMonths - initialDebt;
        uint256 actualInterestSecondHalf = debtAfterOneYear - debtAfterSixMonths;

        // Log the interest amounts for manual verification
        console.log("First half interest:", actualInterestFirstHalf);
        console.log("Second half interest:", actualInterestSecondHalf);

        // Note: We're not asserting that less interest accrued in the second half-year,
        // as this might not always be true with compound interest and a growing debt balance

        vm.stopPrank();
    }

    function test_InterestRate_MultipleVaults() public {
        // Setup vaults for Alice and Bob
        vm.startPrank(alice);
        vaultOperations.createVault(address(collToken), 1000e18, 3000e18, 120e18, address(0), address(0)); // Lower MCR
        vm.stopPrank();

        vm.startPrank(bob);
        vaultOperations.createVault(address(collToken), 2000e18, 4000e18, 150e18, address(0), address(0)); // Higher MCR
        vm.stopPrank();

        // Advance time by 1 year
        vm.warp(block.timestamp + 365 days);

        // Update interest for both vaults
        (,uint256 aliceDebt,) = vaultOperations.updateVaultInterest(address(collToken), alice);
        (,uint256 bobDebt,) = vaultOperations.updateVaultInterest(address(collToken), bob);

        // Verify that Bob's debt has accrued less interest due to higher MCR (lower interest rate)
        uint256 aliceInterest = aliceDebt - 3000e18;
        uint256 bobInterest = bobDebt - 4000e18;
        
        assertTrue(bobInterest < aliceInterest * 4000e18 / 3000e18, "Bob's interest should be proportionally less than Alice's due to higher MCR");
    }

    function test_InterestRate_MCRChangesInterestRate() public {
        // Setup initial vault for Alice with lower MCR
        vm.startPrank(alice);
        vaultOperations.createVault(address(collToken), 1000e18, 3000e18, 120e18, address(0), address(0)); // 120% MCR
        
        uint256 lowerMCRRate = vaultManager.getVaultInterestRate(address(collToken), alice);

        // Adjust Alice's vault to a higher MCR
        vaultOperations.adjustVaultMCR(address(collToken), 150e18, address(0), address(0)); // 150% MCR
        
        uint256 higherMCRRate = vaultManager.getVaultInterestRate(address(collToken), alice);

        // Verify that the interest rate decreased when MCR increased
        assertTrue(higherMCRRate < lowerMCRRate, "Interest rate should decrease with higher MCR");

        vm.stopPrank();
    }

    function test_InterestRate_MintCapExceededByInterest() public {
        // Setup
        uint256 initialCollateral = 2000e18;
        uint256 initialDebt = 4000e18;
        uint256 mcr = 120e18; // 120% MCR

        // Get the current MintCap
        uint256 mintCap = vaultManager.getMintCap(address(collToken));

        // Create vaults to get close to the MintCap
        uint256 numVaults = mintCap / initialDebt;
        for (uint256 i = 0; i < numVaults; i++) {
            vm.startPrank(address(uint160(i + 1000))); // Use different addresses
            deal(address(collToken), address(uint160(i + 1000)), initialCollateral);
            collToken.approve(address(vaultOperations), initialCollateral);
            vaultOperations.createVault(address(collToken), initialCollateral, initialDebt, mcr, address(0), address(0));
            vm.stopPrank();
        }

        // Check total debt is close to but below MintCap
        uint256 totalDebtBefore = vaultOperations.totalDebt(address(collToken));
        assertTrue(totalDebtBefore < mintCap && totalDebtBefore > mintCap - initialDebt, "Total debt should be just below MintCap");

        // Advance time to accrue interest
        vm.warp(block.timestamp + 365 days);

        // Update interest for all vaults
        for (uint256 i = 0; i < numVaults; i++) {
            vaultOperations.updateVaultInterest(address(collToken), address(uint160(i + 1000)));
        }

        // Check total debt has exceeded MintCap
        uint256 totalDebtAfter = vaultOperations.totalDebt(address(collToken));
        assertTrue(totalDebtAfter > mintCap, "Total debt should exceed MintCap due to interest");

        // Try to create a new vault (should fail)
        vm.startPrank(alice);
        deal(address(collToken), alice, initialCollateral);
        collToken.approve(address(vaultOperations), initialCollateral);
        vm.expectRevert("Maximum debt for this asset exceeded");
        vaultOperations.createVault(address(collToken), initialCollateral, initialDebt, mcr, address(0), address(0));
        vm.stopPrank();

        // Test adjusting existing vault (should succeed)
        vm.startPrank(address(1000));
        vaultOperations.adjustVaultMCR(address(collToken), 130e18, address(0), address(0));
        (,, uint256 newMCR) = vaultManager.getVaultData(address(collToken), address(1000));
        assertEq(newMCR, 130e18, "MCR should be adjustable even when MintCap is exceeded");

        // Try to add more debt (should fail)
        vm.expectRevert("Maximum debt for this asset exceeded");
        vaultOperations.adjustVault(address(collToken), 0, 0, 100e18, 0, address(0), address(0));

        // Add more collateral (should succeed)
        uint256 additionalCollateral = 100e18;
        deal(address(collToken), address(1000), additionalCollateral);
        collToken.approve(address(vaultOperations), additionalCollateral);
        vaultOperations.adjustVault(address(collToken), additionalCollateral, 0, 0, 0, address(0), address(0));
        (uint256 collateralAfter,,) = vaultManager.getVaultData(address(collToken), address(1000));
        assertEq(collateralAfter, initialCollateral + additionalCollateral, "Should be able to add collateral even when MintCap is exceeded");

        // Repay some debt (should succeed)
        uint256 repayAmount = 100e18;
        deal(address(keiToken), address(1000), repayAmount);
        keiToken.approve(address(vaultOperations), repayAmount);
        (,uint256 debtBeforeAdjusting,) = vaultManager.getVaultData(address(collToken), address(1000));
        vaultOperations.adjustVault(address(collToken), 0, 0, 0, repayAmount, address(0), address(0));
        (,uint256 debtAfter,) = vaultManager.getVaultData(address(collToken), address(1000));

        assertTrue(debtBeforeAdjusting > debtAfter, "Should be able to repay debt even when MintCap is exceeded");

        vm.stopPrank();
    }

    function test_InterestRate_EqualVaultsWithDifferentAdjustments() public {
        // Setup initial parameters
        uint256 initialCollateral = 1000e18;
        uint256 initialDebt = 500e18;
        uint256 mcr = 120e18; // 120% MCR

        // Create two identical vaults
        address alice = address(0x1);
        address bob = address(0x2);

        // Setup vaults for Alice and Bob
        vm.startPrank(alice);
        deal(address(collToken), alice, initialCollateral * 2); // Extra for adjustments
        collToken.approve(address(vaultOperations), type(uint256).max);
        vaultOperations.createVault(address(collToken), initialCollateral, initialDebt, mcr, address(0), address(0));
        vm.stopPrank();

        vm.startPrank(bob);
        deal(address(collToken), bob, initialCollateral * 2);
        collToken.approve(address(vaultOperations), type(uint256).max);
        vaultOperations.createVault(address(collToken), initialCollateral, initialDebt, mcr, address(0), address(0));
        vm.stopPrank();

        // Log initial state
        console.log("Initial State:");
        logVaultState("Alice", alice);
        logVaultState("Bob", bob);

        // Define time periods and collateral adjustments
        uint256[] memory timePeriods = new uint256[](4);
        timePeriods[0] = 30 days;  // 1 month
        timePeriods[1] = 60 days;  // 2 months
        timePeriods[2] = 90 days;  // 3 months
        timePeriods[3] = 185 days; // 6 months

        uint256[] memory collateralAdjustments = new uint256[](4);
        collateralAdjustments[0] = 100e18;
        collateralAdjustments[1] = 150e18;
        collateralAdjustments[2] = 200e18;
        collateralAdjustments[3] = 50e18;

        // Simulate time passing and adjust Alice's vault
        for (uint i = 0; i < timePeriods.length; i++) {
            vm.warp(block.timestamp + timePeriods[i]);
            
            // Adjust Alice's vault
            vm.startPrank(alice);
            vaultOperations.adjustVault(address(collToken), collateralAdjustments[i], 0, 0, 0, address(0), address(0));
            vm.stopPrank();

            // Update interest for both vaults
            vaultOperations.updateVaultInterest(address(collToken), alice);
            vaultOperations.updateVaultInterest(address(collToken), bob);

            // Log state after each period
            console.log("\nAfter period", i + 1, ":");
            logVaultState("Alice", alice);
            logVaultState("Bob", bob);
        }

        // Final adjustment for Bob's vault to match Alice's total collateral
        uint256 totalAdditionalCollateral = collateralAdjustments[0] + collateralAdjustments[1] + 
                                            collateralAdjustments[2] + collateralAdjustments[3];
        
        vm.startPrank(bob);
        vaultOperations.adjustVault(address(collToken), totalAdditionalCollateral, 0, 0, 0, address(0), address(0));
        vm.stopPrank();

        // Final interest update
        vaultOperations.updateVaultInterest(address(collToken), alice);
        vaultOperations.updateVaultInterest(address(collToken), bob);

        // Log final state
        console.log("\nFinal State:");
        logVaultState("Alice", alice);
        logVaultState("Bob", bob);

        // Compare final debt
        (,uint256 aliceDebt,) = vaultManager.getVaultData(address(collToken), alice);
        (,uint256 bobDebt,) = vaultManager.getVaultData(address(collToken), bob);

        assertEq(aliceDebt, bobDebt, "Final debt should be equal for both vaults");
    }

    function logVaultState(string memory name, address user) internal view {
        (uint256 collateral, uint256 debt, uint256 mcr) = vaultManager.getVaultData(address(collToken), user);
        uint256 interestRate = vaultManager.getVaultInterestRate(address(collToken), user);

        console.log(name, ":");
        console.log("  Collateral:", collateral / 1e18);
        console.log("  Debt:", debt / 1e18);
        console.log("  MCR:", mcr / 1e18, "%");
        console.log("  Interest Rate:", interestRate / 1e15, "%");
    }
}