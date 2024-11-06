// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../mocks/VaultOperations.sol";
import "../mocks/VaultManager.sol";
import "../mocks/VaultSorter.sol";
import "../mocks/StabilityPool.sol";
import "../mocks/KEI.sol";
import "../mocks/COLL.sol";

contract InterestDistributionTest is Test {
    VaultOperations public vaultOperations;
    VaultManager public vaultManager;
    VaultSorter public vaultSorter;
    StabilityPool public stabilityPool;
    KEI public keiToken;
    COLL public collToken;

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public carol = address(0x3);
    address public dave = address(0x4);
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
        addresses[1] = address(0);
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
        collToken.transfer(dave, INITIAL_BALANCE);
        keiToken.mint(alice, INITIAL_BALANCE);
        keiToken.mint(bob, INITIAL_BALANCE);
        keiToken.mint(carol, INITIAL_BALANCE);
        keiToken.mint(dave, INITIAL_BALANCE);

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

        vm.startPrank(dave);
        collToken.approve(address(vaultOperations), type(uint256).max);
        keiToken.approve(address(vaultOperations), type(uint256).max);
        vm.stopPrank();

        stabilityPool.addCollateralType(address(collToken));
    }

    function test_InterestDistribution_SetMintRecipients() public {
        VaultOperations.MintRecipient[] memory recipients = new VaultOperations.MintRecipient[](3);
        recipients[0] = VaultOperations.MintRecipient(alice, 3000); // 30%
        recipients[1] = VaultOperations.MintRecipient(bob, 5000);   // 50%
        recipients[2] = VaultOperations.MintRecipient(carol, 2000); // 20%

        vaultOperations.setMintRecipients(recipients);

        // Check if recipients are set correctly
        (address recipient1, uint256 percentage1) = vaultOperations.mintRecipients(0);
        (address recipient2, uint256 percentage2) = vaultOperations.mintRecipients(1);
        (address recipient3, uint256 percentage3) = vaultOperations.mintRecipients(2);

        assertEq(recipient1, alice);
        assertEq(percentage1, 3000);
        assertEq(recipient2, bob);
        assertEq(percentage2, 5000);
        assertEq(recipient3, carol);
        assertEq(percentage3, 2000);
    }

    function test_InterestDistribution_SetMintRecipientsInvalidPercentage() public {
        VaultOperations.MintRecipient[] memory recipients = new VaultOperations.MintRecipient[](2);
        recipients[0] = VaultOperations.MintRecipient(alice, 5000); // 50%
        recipients[1] = VaultOperations.MintRecipient(bob, 6000);   // 60%

        vm.expectRevert("Total percentage cannot exceed 100%");
        vaultOperations.setMintRecipients(recipients);
    }

    function test_InterestDistribution_SetMintRecipientsInvalidAddress() public {
        VaultOperations.MintRecipient[] memory recipients = new VaultOperations.MintRecipient[](1);
        recipients[0] = VaultOperations.MintRecipient(address(0), 5000);

        vm.expectRevert("Invalid recipient address");
        vaultOperations.setMintRecipients(recipients);
    }

    function test_InterestDistribution_MintVaultsInterest() public {
        // Set up mint recipients
        VaultOperations.MintRecipient[] memory recipients = new VaultOperations.MintRecipient[](3);
        recipients[0] = VaultOperations.MintRecipient(alice, 3000); // 30%
        recipients[1] = VaultOperations.MintRecipient(bob, 5000);   // 50%
        recipients[2] = VaultOperations.MintRecipient(carol, 2000); // 20%
        vaultOperations.setMintRecipients(recipients);

        // Create a vault and accrue some interest
        vm.startPrank(dave);
        vaultOperations.createVault(address(collToken), 1000e18, 3000e18, 110e18, address(0), address(0));
        vm.stopPrank();

        // Fast forward time to accrue interest
        vm.warp(block.timestamp + 365 days);

        // Update vault interest
        vaultOperations.updateVaultInterest(address(collToken), dave);

        // Mint accrued interest
        vaultOperations.mintVaultsInterest();

        // Check if interest was distributed correctly
        uint256 totalInterest = keiToken.balanceOf(alice) + keiToken.balanceOf(bob) + keiToken.balanceOf(carol) - 3 * INITIAL_BALANCE;
        assertGt(totalInterest, 0, "No interest was minted");

        uint256 aliceInterest = keiToken.balanceOf(alice) - INITIAL_BALANCE;
        uint256 bobInterest = keiToken.balanceOf(bob) - INITIAL_BALANCE;
        uint256 carolInterest = keiToken.balanceOf(carol) - INITIAL_BALANCE;

        assertApproxEqRel(aliceInterest, totalInterest * 30 / 100, 1e16, "Alice's interest share is incorrect");
        assertApproxEqRel(bobInterest, totalInterest * 50 / 100, 1e16, "Bob's interest share is incorrect");
        assertApproxEqRel(carolInterest, totalInterest * 20 / 100, 1e16, "Carol's interest share is incorrect");
    }

    function test_InterestDistribution_MintVaultsInterestWithDefaultRecipient() public {
        // Set up mint recipients with total percentage less than 100%
        VaultOperations.MintRecipient[] memory recipients = new VaultOperations.MintRecipient[](2);
        recipients[0] = VaultOperations.MintRecipient(alice, 3000); // 30%
        recipients[1] = VaultOperations.MintRecipient(bob, 5000);   // 50%
        vaultOperations.setMintRecipients(recipients);

        // Set default recipient
        vaultOperations.setDefaultInterestRecipient(dave);

        // Create a vault and accrue some interest
        vm.startPrank(carol);
        vaultOperations.createVault(address(collToken), 1000e18, 3000e18, 110e18, address(0), address(0));
        vm.stopPrank();

        // Fast forward time to accrue interest
        vm.warp(block.timestamp + 365 days);

        // Update vault interest
        vaultOperations.updateVaultInterest(address(collToken), carol);

        // Mint accrued interest
        vaultOperations.mintVaultsInterest();

        // Check if interest was distributed correctly
        uint256 totalInterest = keiToken.balanceOf(alice) + keiToken.balanceOf(bob) + keiToken.balanceOf(dave) - 3 * INITIAL_BALANCE;
        assertGt(totalInterest, 0, "No interest was minted");

        uint256 aliceInterest = keiToken.balanceOf(alice) - INITIAL_BALANCE;
        uint256 bobInterest = keiToken.balanceOf(bob) - INITIAL_BALANCE;
        uint256 daveInterest = keiToken.balanceOf(dave) - INITIAL_BALANCE;

        assertApproxEqRel(aliceInterest, totalInterest * 30 / 100, 1e16, "Alice's interest share is incorrect");
        assertApproxEqRel(bobInterest, totalInterest * 50 / 100, 1e16, "Bob's interest share is incorrect");
        assertApproxEqRel(daveInterest, totalInterest * 20 / 100, 1e16, "Dave's (default recipient) interest share is incorrect");
    }

    function test_InterestDistribution_MintVaultsInterestMultipleTimes() public {
        // Set up mint recipients
        VaultOperations.MintRecipient[] memory recipients = new VaultOperations.MintRecipient[](2);
        recipients[0] = VaultOperations.MintRecipient(alice, 4000); // 40%
        recipients[1] = VaultOperations.MintRecipient(bob, 6000);   // 60%
        vaultOperations.setMintRecipients(recipients);

        // Create a vault and accrue some interest
        vm.startPrank(carol);
        vaultOperations.createVault(address(collToken), 1000e18, 3000e18, 110e18, address(0), address(0));
        vm.stopPrank();

        // First interest accrual and minting
        vm.warp(block.timestamp + 182 days);
        vaultOperations.updateVaultInterest(address(collToken), carol);
        vaultOperations.mintVaultsInterest();

        uint256 aliceInterest1 = keiToken.balanceOf(alice) - INITIAL_BALANCE;
        uint256 bobInterest1 = keiToken.balanceOf(bob) - INITIAL_BALANCE;

        // Second interest accrual and minting
        vm.warp(block.timestamp + 183 days);
        vaultOperations.updateVaultInterest(address(collToken), carol);
        vaultOperations.mintVaultsInterest();

        uint256 aliceInterest2 = keiToken.balanceOf(alice) - INITIAL_BALANCE - aliceInterest1;
        uint256 bobInterest2 = keiToken.balanceOf(bob) - INITIAL_BALANCE - bobInterest1;

        // Check if interest was distributed correctly in both rounds
        assertGt(aliceInterest1, 0, "No interest was minted for Alice in the first round");
        assertGt(bobInterest1, 0, "No interest was minted for Bob in the first round");
        assertGt(aliceInterest2, 0, "No interest was minted for Alice in the second round");
        assertGt(bobInterest2, 0, "No interest was minted for Bob in the second round");

        assertApproxEqRel(aliceInterest1, bobInterest1 * 2 / 3, 1e16, "Incorrect interest distribution in the first round");
        assertApproxEqRel(aliceInterest2, bobInterest2 * 2 / 3, 1e16, "Incorrect interest distribution in the second round");
    }

    function test_InterestDistribution_MintVaultsInterestNoAccruedInterest() public {
        // Set up mint recipients
        VaultOperations.MintRecipient[] memory recipients = new VaultOperations.MintRecipient[](2);
        recipients[0] = VaultOperations.MintRecipient(alice, 5000); // 50%
        recipients[1] = VaultOperations.MintRecipient(bob, 5000);   // 50%
        vaultOperations.setMintRecipients(recipients);

        // Try to mint interest without any accrued interest
        vm.expectRevert("No interest to mint");
        vaultOperations.mintVaultsInterest();
    }

    function testChangeMintRecipientsAfterInterestAccrual() public {
        // Set initial recipients
        VaultOperations.MintRecipient[] memory initialRecipients = new VaultOperations.MintRecipient[](2);
        initialRecipients[0] = VaultOperations.MintRecipient(alice, 5000); // 50%
        initialRecipients[1] = VaultOperations.MintRecipient(bob, 5000);   // 50%
        vaultOperations.setMintRecipients(initialRecipients);

        // Create a vault and accrue interest
        vm.startPrank(carol);
        vaultOperations.createVault(address(collToken), 1000e18, 3000e18, 110e18, address(0), address(0));
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);
        vaultOperations.updateVaultInterest(address(collToken), carol);

        // Change recipients
        VaultOperations.MintRecipient[] memory newRecipients = new VaultOperations.MintRecipient[](2);
        newRecipients[0] = VaultOperations.MintRecipient(dave, 7000); // 70%
        newRecipients[1] = VaultOperations.MintRecipient(carol, 3000); // 30%
        vaultOperations.setMintRecipients(newRecipients);

        // Mint accrued interest
        vaultOperations.mintVaultsInterest();

        // Check if interest was distributed to new recipients
        uint256 daveInterest = keiToken.balanceOf(dave) - INITIAL_BALANCE;
        uint256 carolInterest = keiToken.balanceOf(carol) - INITIAL_BALANCE;

        assertGt(daveInterest, 0, "Dave should have received interest");
        assertGt(carolInterest, 0, "Carol should have received interest");
        assertEq(keiToken.balanceOf(alice), INITIAL_BALANCE, "Alice should not have received any interest");
        assertEq(keiToken.balanceOf(bob), INITIAL_BALANCE, "Bob should not have received any interest");
    }

    function testSingleRecipient() public {
        VaultOperations.MintRecipient[] memory recipients = new VaultOperations.MintRecipient[](1);
        recipients[0] = VaultOperations.MintRecipient(alice, 10000); // 100%
        vaultOperations.setMintRecipients(recipients);

        // Create a vault and accrue interest
        vm.startPrank(bob);
        vaultOperations.createVault(address(collToken), 1000e18, 3000e18, 110e18, address(0), address(0));
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);
        vaultOperations.updateVaultInterest(address(collToken), bob);

        uint256 aliceBalanceBefore = keiToken.balanceOf(alice);
        vaultOperations.mintVaultsInterest();
        uint256 aliceBalanceAfter = keiToken.balanceOf(alice);

        assertGt(aliceBalanceAfter, aliceBalanceBefore, "Alice should have received all the interest");
        assertEq(keiToken.balanceOf(bob), INITIAL_BALANCE + 3000e18, "Bob should not have received any interest");
    }

    function testManyRecipients() public {
        VaultOperations.MintRecipient[] memory recipients = new VaultOperations.MintRecipient[](10);
        for (uint i = 0; i < 10; i++) {
            recipients[i] = VaultOperations.MintRecipient(address(uint160(i + 1)), 1000); // 10% each
        }
        vaultOperations.setMintRecipients(recipients);

        // Create a vault and accrue interest
        vm.startPrank(alice);
        vaultOperations.createVault(address(collToken), 1000e18, 3000e18, 110e18, address(0), address(0));
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);
        vaultOperations.updateVaultInterest(address(collToken), alice);

        vaultOperations.mintVaultsInterest();

        for (uint i = 0; i < 10; i++) {
            uint256 recipientBalance = keiToken.balanceOf(address(uint160(i + 1)));
            assertGt(recipientBalance, 0, "Recipient should have received interest");
        }
    }

    function testSmallPercentageRecipient() public {
        VaultOperations.MintRecipient[] memory recipients = new VaultOperations.MintRecipient[](2);
        recipients[0] = VaultOperations.MintRecipient(alice, 9999); // 99.99%
        recipients[1] = VaultOperations.MintRecipient(bob, 1);     // 0.01%
        vaultOperations.setMintRecipients(recipients);

        // Increase the mint cap
        vaultManager.setMintCap(address(collToken), 10e24); // 10 million tokens

        uint256 collateralAmount = 1e22; // 10,000 tokens
        uint256 debtAmount = 3e22; // 30,000 tokens

        deal(address(collToken), carol, collateralAmount);

        // Create a vault and accrue substantial interest
        vm.startPrank(carol);
        collToken.approve(address(vaultOperations), collateralAmount);
        vaultOperations.createVault(address(collToken), collateralAmount, debtAmount, 110e18, address(0), address(0));
        vm.stopPrank();

        // Set a high interest rate to accrue significant interest
        vaultManager.setBaseFee(address(collToken), 1e17); // 10% base fee

        // Advance time by 1 year
        vm.warp(block.timestamp + 365 days);

        vaultOperations.updateVaultInterest(address(collToken), carol);

        uint256 aliceBalanceBefore = keiToken.balanceOf(alice);
        uint256 bobBalanceBefore = keiToken.balanceOf(bob);

        vaultOperations.mintVaultsInterest();

        uint256 aliceBalanceAfter = keiToken.balanceOf(alice);
        uint256 bobBalanceAfter = keiToken.balanceOf(bob);

        assertGt(aliceBalanceAfter, aliceBalanceBefore, "Alice should have received most of the interest");
        assertGt(bobBalanceAfter, bobBalanceBefore, "Bob should have received a small amount of interest");

        // Check that Alice received significantly more interest than Bob
        uint256 aliceInterest = aliceBalanceAfter - aliceBalanceBefore;
        uint256 bobInterest = bobBalanceAfter - bobBalanceBefore;
        assertGt(aliceInterest, bobInterest * 100, "Alice should have received at least 100 times more interest than Bob");

        // Verify that Bob received a very small amount (0.01% of total interest)
        uint256 totalInterest = aliceInterest + bobInterest;
        assertApproxEqRel(bobInterest, totalInterest / 10000, 1e14, "Bob should have received approximately 0.01% of total interest");
    }

    function testLargeAccruedInterestAmount() public {
        VaultOperations.MintRecipient[] memory recipients = new VaultOperations.MintRecipient[](2);
        recipients[0] = VaultOperations.MintRecipient(alice, 5000); // 50%
        recipients[1] = VaultOperations.MintRecipient(bob, 5000);   // 50%
        vaultOperations.setMintRecipients(recipients);

        // Increase the mint cap to allow for larger debt
        vaultManager.setMintCap(address(collToken), 1e27);

        uint256 largeCollateral = 1e25; // 10 million tokens
        uint256 largeDebt = 3e25; // 30 million tokens
        
        // Mint enough tokens to carol for the vault creation
        deal(address(collToken), carol, largeCollateral);

        vm.startPrank(carol);
        collToken.approve(address(vaultOperations), largeCollateral);
        vaultOperations.createVault(address(collToken), largeCollateral, largeDebt, 110e18, address(0), address(0));
        vm.stopPrank();

        // Set a high interest rate to accrue significant interest
        vaultManager.setBaseFee(address(collToken), 1e17); // 10% base fee

        // Advance time by 1 year
        vm.warp(block.timestamp + 365 days);

        vaultOperations.updateVaultInterest(address(collToken), carol);

        uint256 aliceBalanceBefore = keiToken.balanceOf(alice);
        uint256 bobBalanceBefore = keiToken.balanceOf(bob);

        vaultOperations.mintVaultsInterest();

        uint256 aliceBalanceAfter = keiToken.balanceOf(alice);
        uint256 bobBalanceAfter = keiToken.balanceOf(bob);

        assertGt(aliceBalanceAfter, aliceBalanceBefore, "Alice should have received interest");
        assertGt(bobBalanceAfter, bobBalanceBefore, "Bob should have received interest");
        assertEq(aliceBalanceAfter - aliceBalanceBefore, bobBalanceAfter - bobBalanceBefore, "Alice and Bob should have received equal amounts of interest");

        // Check that a significant amount of interest was accrued
        uint256 totalInterestAccrued = (aliceBalanceAfter - aliceBalanceBefore) + (bobBalanceAfter - bobBalanceBefore);
        assertGt(totalInterestAccrued, largeDebt / 10, "Total accrued interest should be significant");
    }

    function testUpdateMintRecipients() public {
        // Set initial recipients
        VaultOperations.MintRecipient[] memory initialRecipients = new VaultOperations.MintRecipient[](2);
        initialRecipients[0] = VaultOperations.MintRecipient(alice, 5000); // 50%
        initialRecipients[1] = VaultOperations.MintRecipient(bob, 5000);   // 50%
        vaultOperations.setMintRecipients(initialRecipients);

        // Create a vault and accrue some interest
        vm.startPrank(alice);
        vaultOperations.createVault(address(collToken), 1000e18, 3000e18, 110e18, address(0), address(0));
        vm.stopPrank();

        vm.warp(block.timestamp + 182 days);
        vaultOperations.updateVaultInterest(address(collToken), alice);

        // Set new recipients (this will automatically clear the old ones)
        VaultOperations.MintRecipient[] memory newRecipients = new VaultOperations.MintRecipient[](2);
        newRecipients[0] = VaultOperations.MintRecipient(carol, 5000); // 50%
        newRecipients[1] = VaultOperations.MintRecipient(dave, 5000);  // 50%
        vaultOperations.setMintRecipients(newRecipients);

        // Accrue more interest and mint
        vm.warp(block.timestamp + 183 days);
        vaultOperations.updateVaultInterest(address(collToken), alice);
        vaultOperations.mintVaultsInterest();

        uint256 carolInterest = keiToken.balanceOf(carol) - INITIAL_BALANCE;
        uint256 daveInterest = keiToken.balanceOf(dave) - INITIAL_BALANCE;
        uint256 aliceInterest = keiToken.balanceOf(alice) - INITIAL_BALANCE - 3000e18;
        uint256 bobInterest = keiToken.balanceOf(bob) - INITIAL_BALANCE;

        assertGt(carolInterest, 0, "Carol should have received interest");
        assertGt(daveInterest, 0, "Dave should have received interest");
        assertEq(aliceInterest, 0, "Alice should not have received any interest");
        assertEq(bobInterest, 0, "Bob should not have received any interest");

        // Check if Carol and Dave received the same amount of interest
        assertEq(carolInterest, daveInterest, "Carol and Dave should have received the same amount of interest");

        // Additional check to ensure the total minted interest is correct
        uint256 totalMintedInterest = carolInterest + daveInterest;
        assertGt(totalMintedInterest, 0, "Total minted interest should be greater than 0");
    }

    function testRemoveRecipient() public {
        // Set initial recipients
        VaultOperations.MintRecipient[] memory initialRecipients = new VaultOperations.MintRecipient[](3);
        initialRecipients[0] = VaultOperations.MintRecipient(alice, 3000); // 30%
        initialRecipients[1] = VaultOperations.MintRecipient(bob, 4000);   // 40%
        initialRecipients[2] = VaultOperations.MintRecipient(carol, 3000); // 30%
        vaultOperations.setMintRecipients(initialRecipients);

        // Create a vault and accrue interest
        vm.startPrank(dave);
        vaultOperations.createVault(address(collToken), 1000e18, 3000e18, 110e18, address(0), address(0));
        vm.stopPrank();

        vm.warp(block.timestamp + 182 days);
        vaultOperations.updateVaultInterest(address(collToken), dave);

        // Remove Bob and redistribute percentages
        VaultOperations.MintRecipient[] memory newRecipients = new VaultOperations.MintRecipient[](2);
        newRecipients[0] = VaultOperations.MintRecipient(alice, 5000); // 50%
        newRecipients[1] = VaultOperations.MintRecipient(carol, 5000); // 50%
        vaultOperations.setMintRecipients(newRecipients);

        vm.warp(block.timestamp + 183 days);
        vaultOperations.updateVaultInterest(address(collToken), dave);

        vaultOperations.mintVaultsInterest();

        uint256 aliceInterest = keiToken.balanceOf(alice) - INITIAL_BALANCE;
        uint256 carolInterest = keiToken.balanceOf(carol) - INITIAL_BALANCE;
        uint256 bobInterest = keiToken.balanceOf(bob) - INITIAL_BALANCE;

        assertGt(aliceInterest, 0, "Alice should have received interest");
        assertGt(carolInterest, 0, "Carol should have received interest");
        assertEq(bobInterest, 0, "Bob should not have received any interest after removal");
        assertApproxEqRel(aliceInterest, carolInterest, 1e16, "Alice and Carol should have received approximately equal interest after redistribution");
    }
}