// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./AddressBook.sol";
import "./interfaces/IStabilityPool.sol";
import "./interfaces/IVaultSorter.sol";
import "./interfaces/IPriceFeed.sol";
import "./interfaces/IVaultManager.sol";
import "./dependencies/IERC20.sol";

contract VaultOperations is AddressBook {

    /* ----------   PROTOCOL STATE   ------------ */
    uint256 public activeVaults;
    uint256 public totalProtocolDebt;
    uint256 public totalAccruedDebt;
    uint256 private lastRecordedAccruedDebt;

    uint256 constant DECIMAL_PRECISION = 1e18;
    uint256 constant SECONDS_IN_YEAR = 31536000; // 365 * 24 * 60 * 60

    mapping(address => uint256) public totalDebt; // Total debt of a specific asset vaults 
    mapping(address => uint256) public totalCollateral; // Total collateral of a specific asset vaults
    mapping(address => mapping(address => uint256)) public lastDebtUpdateTime;

    struct MintRecipient {
        address recipient;
        uint256 percentage; // Percentage in basis points (e.g., 5000 for 50%)
    }
    
    // Allows the protocol to stream accrued interest to multiple addresses.
    MintRecipient[] public mintRecipients;
    address public defaultInterestRecipient;

    /*
        ------------------- PROTOCOL EVENTS -------------------
    */

    event VaultCreated(address indexed vaultOwner, address indexed vaultCollateral, uint256 collatAmount, uint256 debtAmount);
    event VaultClosed(address indexed vaultOwner, address indexed vaultCollateral, uint256 collatAmount, uint256 debtAmount);
    event VaultAdjusted(address indexed vaultOwner, address indexed vaultCollateral, uint256 addCollateral, uint256 withdrawCollateral, uint256 addDebt, uint256 repaidDebt);
    event VaultLiquidated(address indexed vaultOwner, address indexed vaultCollateral, address indexed liquidator);
    event VaultTransfered(address indexed oldOwner, address indexed vaultCollateral, address indexed newOwner);
    event VaultRedeemed(address indexed vaultOwner, address vaultCollateral, address redeemer, uint256 amount, uint256 vaultARS);
    event VaultInterestMinted(uint256 amount);

    /*
        ------------------- EXTERNAL FUNCTIONS -------------------
    */

    /*
    * @notice Creates a new vault
    * @param vaultCollateral ERC20 token used as collateral.
    * @param collatAmount Amount of collateral to be deposited in the new vault.
    * @param debtAmount Amount of debt to be issued against the collateral.
    * @param vaultMCR Minimum Collateral Ratio choosen by the user.
    */
    function createVault(address vaultCollateral, uint256 collatAmount, uint256 debtAmount, uint256 vaultMCR, address prevId, address nextId) external {
        (uint256 currentCollateralAmount,,) = manageDebtInterest(vaultCollateral, msg.sender);

        require(currentCollateralAmount == 0, "Vault already exists for this asset");

        totalCollateral[vaultCollateral] += collatAmount;
        totalDebt[vaultCollateral] += debtAmount;
        totalProtocolDebt += debtAmount;
        activeVaults += 1;

        IVaultManager(vaultManager).adjustVaultData(vaultCollateral, msg.sender, collatAmount, debtAmount, vaultMCR); 
        require(IVaultManager(vaultManager).checkVaultState(vaultCollateral, msg.sender), "Invariant check failed");
        require(totalDebt[vaultCollateral] <= IVaultManager(vaultManager).getMintCap(vaultCollateral), "Maximum debt for this asset exceeded");

        uint256 vaultARS = IVaultManager(vaultManager).calculateARS(vaultCollateral, msg.sender);
        IVaultSorter(vaultSorter).insertVault(vaultCollateral, msg.sender, vaultARS, prevId, nextId);
        
        IERC20(vaultCollateral).transferFrom(msg.sender, address(this), collatAmount);
        IERC20(debtToken).mint(msg.sender, debtAmount);

        emit VaultCreated(msg.sender, vaultCollateral, collatAmount, debtAmount);
    }

    /*
    * @notice Closes an existing vault and returns the collateral to the user.
    * @param vaultCollateral ERC20 token used as collateral in the vault.
    */
    function closeVault(address vaultCollateral) external {
        (uint256 collateralAmount, uint256 debtAmount,) = manageDebtInterest(vaultCollateral, msg.sender);
        require(collateralAmount != 0, "Vault doesnt exists");

        totalCollateral[vaultCollateral] -= collateralAmount;
        totalDebt[vaultCollateral] -= debtAmount;
        totalProtocolDebt -= debtAmount;
        activeVaults -= 1;
        lastDebtUpdateTime[msg.sender][vaultCollateral] = 0;

        IVaultManager(vaultManager).adjustVaultData(vaultCollateral, msg.sender, 0, 0, 0);
        IVaultSorter(vaultSorter).removeVault(vaultCollateral, msg.sender);

        IERC20(debtToken).burn(msg.sender, debtAmount);
        IERC20(vaultCollateral).transfer(msg.sender, collateralAmount);
        
        emit VaultClosed(msg.sender, vaultCollateral, collateralAmount, debtAmount);
    }

    /*
    * @notice Adjusts an existing vault's collateral and debt balances.
    * @param vaultCollateral ERC20 token used as collateral.
    * @param addCollateral Amount of collateral to be added to the vault.
    * @param withdrawCollateral Amount of collateral to be withdrawn from the vault.
    * @param addDebt Amount of new debt to be added to the vault.
    * @param repaidDebt Amount of existing debt to be repaid.
    */
    function adjustVault(
        address vaultCollateral,
        uint256 addCollateral,
        uint256 withdrawCollateral,
        uint256 addDebt,
        uint256 repaidDebt,
        address prevId, 
        address nextId
    ) external {
        (uint256 collateralAmount, uint256 debtAmount, uint256 vaultMCR) = manageDebtInterest(vaultCollateral, msg.sender);

        require(collateralAmount != 0, "Vault doesnt exists");
        require(collateralAmount >= withdrawCollateral, "CollateralManager: Insufficient collateral");
        require(addCollateral == 0 || withdrawCollateral == 0, "Cant add and withdraw collateral");
        require(repaidDebt == 0 || addDebt == 0, "Cant repay and take debt");
        require(debtAmount >= repaidDebt, "CollateralManager: Insufficient debt");

        if (addCollateral > 0) {
            totalCollateral[vaultCollateral] += addCollateral;
        }

        if (withdrawCollateral > 0) {
            totalCollateral[vaultCollateral] -= withdrawCollateral;
        }

        if (repaidDebt > 0) {
            totalDebt[vaultCollateral] -= repaidDebt;
            totalProtocolDebt -= repaidDebt;
        }

        if (addDebt > 0) {
            totalDebt[vaultCollateral] += addDebt;
            totalProtocolDebt += addDebt;
            require(totalDebt[vaultCollateral] <= IVaultManager(vaultManager).getMintCap(vaultCollateral), "Maximum debt for this asset exceeded");
        }

        IVaultManager(vaultManager).adjustVaultData(vaultCollateral, msg.sender, 
            collateralAmount + addCollateral - withdrawCollateral, 
            debtAmount + addDebt - repaidDebt, 
            vaultMCR);

        if (addCollateral > 0) IERC20(vaultCollateral).transferFrom(msg.sender, address(this), addCollateral);
        if (withdrawCollateral > 0) IERC20(vaultCollateral).transfer(msg.sender, withdrawCollateral);
        if (repaidDebt > 0) IERC20(debtToken).burn(msg.sender, repaidDebt);
        if (addDebt > 0) IERC20(debtToken).mint(msg.sender, addDebt);

        uint256 vaultARS = IVaultManager(vaultManager).calculateARS(vaultCollateral, msg.sender);
        IVaultSorter(vaultSorter).reInsertVault(vaultCollateral, msg.sender, vaultARS, prevId, nextId);
        require(IVaultManager(vaultManager).checkVaultState(vaultCollateral, msg.sender), "Invariant check failed");

        emit VaultAdjusted(msg.sender, vaultCollateral, addCollateral, withdrawCollateral, addDebt, repaidDebt);
    }
    
    /*
    * @notice Adjusts the minimum collateral ratio of a specific vault
    * @param vaultCollateral ERC20 token used as collateral in the vault.
    * @param mcr New minimum collateral ratio
    */
    function adjustVaultMCR(address vaultCollateral, uint256 mcr, address prevId, address nextId) external {
        (uint256 collateralAmount, uint256 debtAmount, uint256 vaultMCR) = manageDebtInterest(vaultCollateral, msg.sender);

        require(vaultMCR != mcr, "New MCR is the same as the current one");

        IVaultManager(vaultManager).adjustVaultData(vaultCollateral, msg.sender, collateralAmount, debtAmount, mcr);
        uint256 vaultARS = IVaultManager(vaultManager).calculateARS(vaultCollateral, msg.sender);
        IVaultSorter(vaultSorter).reInsertVault(vaultCollateral, msg.sender, vaultARS, prevId, nextId);

        require(IVaultManager(vaultManager).checkVaultState(vaultCollateral, msg.sender), "Invariant check failed");   
    }

    /*
    * @notice Liquidates a vault whose collateralization ratio has fallen below the minimum threshold.
    * @param vaultOwner Address of the owner of the vault to be liquidated.
    * @param vaultCollateral ERC20 token used as collateral in the vault.
    */
    function liquidateVault(address vaultCollateral, address vaultOwner, address prevId, address nextId) external {
        (uint256 collateralAmount, uint256 debtAmount, uint256 vaultMCR) = manageDebtInterest(vaultCollateral, vaultOwner);
        uint256 currentCR = IVaultManager(vaultManager).calculateCR(vaultCollateral, vaultOwner);
        uint256 stabilityPoolBalance = IStabilityPool(stabilityPool).getTotalDebtTokenDeposits();
        
        require(collateralAmount != 0, "Vault doesnt exist");
        require(currentCR < vaultMCR, "Collateralization ratio above minimum");
        require(stabilityPoolBalance > 0, "Stability pool is empty");

        uint256 debtToOffset = debtAmount;
        
        if (stabilityPoolBalance < debtAmount) {
            debtToOffset = stabilityPoolBalance;
        }

        (uint256 spDistribution, uint256 remainingCollateral) = calculateLiquidationDistribution(vaultCollateral, collateralAmount, debtToOffset);
        
        // Full liquidation (Enough KEI in SP to cover the entire vault debt)
        if (debtToOffset == debtAmount) {
            activeVaults -= 1;
            lastDebtUpdateTime[vaultOwner][vaultCollateral] = 0;

            IVaultSorter(vaultSorter).removeVault(vaultCollateral, vaultOwner);
            IVaultManager(vaultManager).adjustVaultData(vaultCollateral, vaultOwner, 0, 0, 0);
            
            // Update total debt and collateral
            totalDebt[vaultCollateral] -= debtAmount;
            totalCollateral[vaultCollateral] -= collateralAmount;

            if (remainingCollateral > 0) {
                IERC20(vaultCollateral).transfer(vaultOwner, remainingCollateral);
            }
        
        // Partial liquidation (Not enough KEI in SP)
        } else {
            uint256 remainingDebt = debtAmount - debtToOffset;
            
            IVaultManager(vaultManager).adjustVaultData(vaultCollateral, vaultOwner, remainingCollateral, remainingDebt, vaultMCR);
            uint256 vaultARS = IVaultManager(vaultManager).calculateARS(vaultCollateral, vaultOwner);
            IVaultSorter(vaultSorter).reInsertVault(vaultCollateral, vaultOwner, vaultARS, prevId, nextId);
            
            // Update total debt and collateral
            totalDebt[vaultCollateral] -= debtToOffset;
            totalCollateral[vaultCollateral] -= spDistribution;
        }

        totalProtocolDebt -= debtToOffset;

        IERC20(vaultCollateral).approve(stabilityPool, spDistribution);
        IStabilityPool(stabilityPool).offsetDebt(debtToOffset, vaultCollateral, spDistribution);
        emit VaultLiquidated(vaultOwner, vaultCollateral, msg.sender);
    }

    /*
    * @notice Redeems collateral from vaults in exchange for paying off the corresponding debt amount until the requested redemption amount is met.
    * @param vaultCollateral ERC20 token used as collateral.
    * @param redemptionAmount Total debt amount the caller wants to redeem in exchange for collateral.
    */
    function redeemVault(address vaultCollateral, uint256 redemptionAmount, address prevId, address nextId) external {
        require(redemptionAmount > 0, "Amount must be positive");
        
        address currentVault = IVaultSorter(vaultSorter).getLast(vaultCollateral);
        require(currentVault != address(0), "No vaults available for redemption");
        
        uint256 redemptionFee = IVaultManager(vaultManager).getRedemptionFee();
        uint256 collateralPrice = IPriceFeed(priceFeed).fetchPrice(vaultCollateral);
        uint256 totalCollateralRedeemed;
        uint256 totalDebtRedeemed;
        
        while (redemptionAmount > 0 && currentVault != address(0)) {
            (uint256 collateralAmount, uint256 debtAmount, uint256 vaultMCR) = manageDebtInterest(vaultCollateral, currentVault);
            
            uint256 redeemableAmount = debtAmount < redemptionAmount ? debtAmount : redemptionAmount;
            uint256 feeAmount = (redeemableAmount * redemptionFee) / 1e18;
            uint256 netRedeemableAmount = redeemableAmount - feeAmount;
            uint256 collateralForRedeemer = (netRedeemableAmount * 1e18) / collateralPrice;
                
            require(collateralForRedeemer <= collateralAmount, "Insufficient collateral in the vault");
                
            totalCollateralRedeemed += collateralForRedeemer;
            totalDebtRedeemed += redeemableAmount;
            redemptionAmount -= redeemableAmount;


            // Calculate VaultARS at which the vault was redeemed for analytic purposes.
            uint256 vaultARS = IVaultManager(vaultManager).calculateARS(vaultCollateral, currentVault);
            emit VaultRedeemed(currentVault, vaultCollateral, msg.sender, redeemableAmount, vaultARS);
            
            if (redemptionAmount > 0) {
                uint256 collForUser = collateralAmount - collateralForRedeemer;

                IVaultManager(vaultManager).adjustVaultData(
                    vaultCollateral,
                    currentVault,
                    0,
                    0,
                    0
                );

                IVaultSorter(vaultSorter).removeVault(vaultCollateral, currentVault);
                IERC20(vaultCollateral).transfer(currentVault, collForUser);

                currentVault = IVaultSorter(vaultSorter).getLast(vaultCollateral);
            } else {
                IVaultManager(vaultManager).adjustVaultData(
                    vaultCollateral,
                    currentVault,
                    collateralAmount - collateralForRedeemer,
                    debtAmount > redeemableAmount ? debtAmount - redeemableAmount : 0,
                    vaultMCR
                );

                vaultARS = IVaultManager(vaultManager).calculateARS(vaultCollateral, currentVault);
                IVaultSorter(vaultSorter).reInsertVault(vaultCollateral, currentVault, vaultARS, prevId, nextId);
            }
        }

        if (totalDebtRedeemed > 0) {
            IERC20(debtToken).burn(msg.sender, totalDebtRedeemed);
        }

        if (totalCollateralRedeemed > 0) {
            IERC20(vaultCollateral).transfer(msg.sender, totalCollateralRedeemed);
        }
    }

    /*
    * @notice Transfers ownership of a vault from the caller to another address, ensuring both collateral and debt are transferred and the recipient does not already own a vault with the same collateral.
    * @param vaultCollateral ERC20 token used as collateral in the vault.
    * @param recipient Address of the new owner to whom the vault will be transferred.
    */
    function transferVaultOwnership(address vaultCollateral, address recipient, address prevId, address nextId) external {
        (uint256 donorCollateralAmount, uint256 donorDebtAmount, uint256 vaultMCR) = manageDebtInterest(vaultCollateral, msg.sender);
        (uint256 recipientCollateralAmount, ,) = IVaultManager(vaultManager).getVaultData(vaultCollateral, recipient);
        uint256 vaultARS = IVaultManager(vaultManager).calculateARS(vaultCollateral, msg.sender);

        require(recipientCollateralAmount == 0, "This address already has a vault");
        require(recipient != msg.sender, "Cant transfer vault to yourself");
        require(IVaultManager(vaultManager).calculateCR(vaultCollateral, msg.sender) > vaultMCR, "Vault below MCR");

        IVaultManager(vaultManager).adjustVaultData(vaultCollateral, msg.sender, 0, 0, 0);
        IVaultManager(vaultManager).adjustVaultData(vaultCollateral, recipient, donorCollateralAmount, donorDebtAmount, vaultMCR);
        lastDebtUpdateTime[recipient][vaultCollateral] = lastDebtUpdateTime[msg.sender][vaultCollateral];
        lastDebtUpdateTime[msg.sender][vaultCollateral] = 0;

        require(IVaultManager(vaultManager).checkVaultState(vaultCollateral, recipient), "Invariant check failed");

        IVaultSorter(vaultSorter).removeVault(vaultCollateral, msg.sender);
        IVaultSorter(vaultSorter).insertVault(vaultCollateral, recipient, vaultARS, prevId, nextId);

        emit VaultTransfered(msg.sender, vaultCollateral, recipient);

    }
    
    /*
    * @notice Mints protocol accrued interest from all active vaults
    * @dev No undercollateralized KEI is minted. All of the minted tokens come strictly from already generated protocol revenue.
    */
    function mintVaultsInterest() external {
        uint256 interestSinceLastMint = totalAccruedDebt - lastRecordedAccruedDebt;

        require(interestSinceLastMint > 0, "No interest to mint");
        lastRecordedAccruedDebt = totalAccruedDebt;  // Update the last recorded debt to the current

        uint256 remainingInterest = interestSinceLastMint;

        // Mint to configured recipients
        for (uint i = 0; i < mintRecipients.length; i++) {
            uint256 amountToMint = (interestSinceLastMint * mintRecipients[i].percentage) / 10000;
            if (amountToMint > 0) {
                IERC20(debtToken).mint(mintRecipients[i].recipient, amountToMint);
                remainingInterest -= amountToMint;
            }
        }

        // Mint any remaining amount to the default recipient
        if (remainingInterest > 0 && defaultInterestRecipient != address(0)) {
            IERC20(debtToken).mint(defaultInterestRecipient, remainingInterest);
        }
        
        emit VaultInterestMinted(interestSinceLastMint);
    }

    function setMintRecipients(MintRecipient[] memory _recipients) external onlyOwner {
        delete mintRecipients; // Clear existing recipients
        uint256 totalPercentage = 0;

        for (uint i = 0; i < _recipients.length; i++) {
            require(_recipients[i].recipient != address(0), "Invalid recipient address");
            require(_recipients[i].percentage > 0, "Percentage must be greater than 0");
            totalPercentage += _recipients[i].percentage;
            mintRecipients.push(_recipients[i]);
        }

        require(totalPercentage <= 10000, "Total percentage cannot exceed 100%");
    }

    function updateVaultInterest(address vaultCollateral, address vaultOwner) external returns (uint256, uint256, uint256) {
        (uint256 collateralAmount, uint256 debtAmount, uint256 vaultMCR) = manageDebtInterest(vaultCollateral, vaultOwner);

        return (collateralAmount, debtAmount, vaultMCR);
    }

    function getLastUpdatedDebtTime(address vaultCollateral, address vaultOwner) external view returns (uint256) {
        uint256 lastUpdated = lastDebtUpdateTime[vaultOwner][vaultCollateral];

        return lastUpdated;
    }

    function setDefaultInterestRecipient(address _recipient) external onlyOwner {
        defaultInterestRecipient = _recipient;
    }

    /*
        ------------------- INTERNAL FUNCTIONS -------------------
    */

    /*
    * @notice Updates and manages the accrued interest on the debt of a vault based on its last update time.
    * @param _vaultCollateral Address of the ERC20 token used as collateral.
    * @param _vaultOwner Address of the vault owner.
    * @return The updated collateral amount, debt amount, and minimum collateral ratio of the vault.
    */
    function manageDebtInterest(address _vaultCollateral, address _vaultOwner) internal returns (uint256, uint256, uint256) {
        (uint256 collateralAmount, uint256 debtAmount, uint256 vaultMCR) = IVaultManager(vaultManager).getVaultData(_vaultCollateral, _vaultOwner);
        uint256 lastUpdated = lastDebtUpdateTime[_vaultOwner][_vaultCollateral];
        uint256 currentTimestamp = block.timestamp;
        uint256 timeElapsed = currentTimestamp - lastUpdated;

        if (timeElapsed > 0) {
            uint256 vaultInterestRate = IVaultManager(vaultManager).getVaultInterestRate(_vaultCollateral, _vaultOwner);
            uint256 accruedInterest = calculateAccruedInterest(debtAmount, vaultInterestRate, timeElapsed);
            
            debtAmount += accruedInterest;
            totalAccruedDebt += accruedInterest;
            totalDebt[_vaultCollateral] += accruedInterest;
            totalProtocolDebt += accruedInterest;
            
            // Update the vault data with the new debt amount including accrued interest
            IVaultManager(vaultManager).adjustVaultData(_vaultCollateral, _vaultOwner, collateralAmount, debtAmount, vaultMCR);
        }

        // Reset the last update time to the current timestamp
        lastDebtUpdateTime[_vaultOwner][_vaultCollateral] = currentTimestamp;
        
        return (collateralAmount, debtAmount, vaultMCR);
    }

    /*
    * @notice Calculates the accrued interest on a given debt over a specified period of time using compound interest.
    * @param _currentDebt The principal amount of debt to calculate interest on.
    * @param _interestRate The annual interest rate applied, scaled by 1e18.
    * @param _timeElapsed The time elapsed since the last interest calculation, in seconds.
    * @return The amount of interest accrued over the time period, calculated with compound interest.
    */
    function calculateAccruedInterest(uint256 _currentDebt, uint256 _interestRate, uint256 _timeElapsed) internal pure returns (uint256) {
        if (_currentDebt == 0 || _interestRate == 0 || _timeElapsed == 0) {
            return 0;
        }

        // Convert annual interest rate to per-second rate
        uint256 baseRate = DECIMAL_PRECISION + (_interestRate / SECONDS_IN_YEAR);
        uint256 compoundFactor = VaultMath.decPow(baseRate, _timeElapsed);
        uint256 newDebt = (_currentDebt * compoundFactor) / DECIMAL_PRECISION;
        
        return newDebt - _currentDebt;
    }


    /*
    * @notice Calculates the amount of collateral that should be distributed to the stability pool based on the debt and penalties.
    * @param token The address of the ERC20 token used as collateral.
    * @param collateral The total amount of collateral held in the vault.
    * @param debt The total debt amount that triggered the liquidation.
    * @return The amount of collateral to distribute to the liquidator.
    */
    function calculateLiquidationDistribution(address _collateral, uint256 _collateralAmount, uint256 _debt) internal view returns (uint256, uint256) {
        uint256 collateralPrice = IPriceFeed(priceFeed).fetchPrice(_collateral);
        uint256 liqPenalty = IVaultManager(vaultManager).getLiquidationPenalty(_collateral);

        // Adjust the liquidation amount considering the penalty
        uint256 liquidationAmount = _debt + (_debt * liqPenalty) / 1e18;

        // Calculate the total collateral value in 1e18 format
        uint256 collateralValue = _collateralAmount * collateralPrice / 1e18;

        if (liquidationAmount > collateralValue) {
            return (_collateralAmount, 0); // Return full collateral amount if liquidationAmount exceeds collateral value
        }

        // Calculate the amount of collateral to be distributed to the Stability Pool
        uint256 spCollateral = liquidationAmount * 1e18 / collateralPrice;
        uint256 surplusCollateral = _collateralAmount - spCollateral;
        return (spCollateral, surplusCollateral);
    }
}