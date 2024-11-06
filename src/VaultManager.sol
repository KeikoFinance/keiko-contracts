// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./interfaces/IVaultManager.sol";
import "./interfaces/IPriceFeed.sol";
import "./AddressBook.sol";

contract VaultManager is IVaultManager, AddressBook {

    /*
            ------------------------ PARAMETER CONSTANTS ------------------------
    */

    uint256 public constant MIN_NET_DEBT_DEFAULT = 300 * 1e18;  // 300 KEI
    uint256 public constant MINT_CAP_DEFAULT = 50000 * 1e18;    // 50000 KEI
    uint256 public constant MIN_CR_RANGE = 110 * 1e18;          // 110%
    uint256 public constant MAX_CR_RANGE = 150 * 1e18;          // 150%
    uint256 public constant MCR_FACTOR = 20e16;                 // 0.2
    uint256 public constant MAX_FEE = 200 * 1e15;               // 20%
    uint256 public constant BASE_FEE = 25 * 1e15;               // 2.5%
    uint256 public constant LIQUIDATION_PENALTY = 100 * 1e15;   // 10%
    uint256 public REDEMPTION_FEE = 25 * 1e15;                  // 2.5%

    /*
            ------------------------      STATE      ------------------------
    */

    struct Vault {
        uint256 collateral;
        uint256 debt;
        uint256 mcr;
    }

    struct CollateralParams {
        uint256 decimals;
        uint256 index;  // Maps to token address in validCollateral[]
        bool active;
        uint256 minRange;
        uint256 maxRange;
        uint256 mcrFactor;
        uint256 baseFee;
        uint256 maxFee;
        uint256 minNetDebt;
        uint256 mintCap;
        uint256 liquidationPenalty;
    }

    mapping(address => mapping(address => Vault)) public userVaults;
    mapping(address => CollateralParams) internal collateralParams;
    address[] public validCollateral;

    /*
            ------------------------ EXTERNAL FUNCTIONS ------------------------
    */

    function addNewCollateral(address collateral, uint256 decimals) external onlyOwner {
        require(decimals == 18, "collaterals must have the default decimals");

        validCollateral.push(collateral);
        collateralParams[collateral] = CollateralParams({
            decimals: decimals,
            index: validCollateral.length - 1,
            active: false,
            minRange: MIN_CR_RANGE,
            maxRange: MAX_CR_RANGE,
            mcrFactor: MCR_FACTOR,
            baseFee: BASE_FEE,
            maxFee: MAX_FEE,
            minNetDebt: MIN_NET_DEBT_DEFAULT,
            mintCap: MINT_CAP_DEFAULT,
            liquidationPenalty: LIQUIDATION_PENALTY
        });

        emit CollateralAdded(collateral);
    }

    function adjustVaultData(
        address vaultCollateral, 
        address vaultOwner, 
        uint256 collateralAmount,
        uint256 debtAmount, 
        uint256 mcr
    ) external onlyVaultOperations {
        require(vaultOwner != address(0), "Invalid vault owner");

        Vault storage userVault = userVaults[vaultOwner][vaultCollateral];

        userVault.collateral = collateralAmount;
        userVault.debt = debtAmount;
        userVault.mcr = mcr;
    }

    function getVaultData(address vaultCollateral, address vaultOwner) external view returns(uint256, uint256, uint256) {
        Vault memory userVault = userVaults[vaultOwner][vaultCollateral];

        return (userVault.collateral, userVault.debt, userVault.mcr);
    }

    function isAddressValid(address _address) public view returns(bool) {
        for (uint i = 0; i < validCollateral.length; i++) {
            if (validCollateral[i] == _address) {
                return true;
            }
        }

        return false;
    }

    function checkVaultState(address vaultCollateral, address vaultOwner) external view returns(bool) {
        Vault memory userVault = userVaults[vaultOwner][vaultCollateral];

        require(calculateCR(vaultCollateral, vaultOwner) > userVault.mcr, "CR < MCR");
        require(isAddressValid(vaultCollateral), "Not whitelisted");
        require(userVault.mcr >= getMinRange(vaultCollateral), "Invalid MCR");
        require(getIsActive(vaultCollateral), "Not active");
        require(userVault.debt >= getMinNetDebt(vaultCollateral), "Invalid minNetDebt");

        return true;
    }

    function calculateARS(address vaultCollateral, address vaultOwner) external view returns (uint256) {
        Vault memory userVault = userVaults[vaultOwner][vaultCollateral];

        uint256 mcrFactor = getMCRFactor(vaultCollateral);
        uint256 vaultNCR = calculateNCR(vaultCollateral, vaultOwner);

        if (vaultNCR == type(uint256).max || mcrFactor == 0) {
            return vaultNCR;
        }

        uint256 mcrComponent = (mcrFactor * userVault.mcr) / 1e18;
        uint256 vaultARS = vaultNCR + mcrComponent;

        return vaultARS;
    }

    /*
            ------------------------ PUBLIC FUNCTIONS ------------------------
    */

    function getVaultInterestRate(address vaultCollateral, address vaultOwner) public view returns(uint256) {
        Vault memory userVault = userVaults[vaultOwner][vaultCollateral];

        uint256 baseFee = getBaseFee(vaultCollateral);
        uint256 maxFee = getMaxFee(vaultCollateral);
        uint256 maxRange = getMaxRange(vaultCollateral);
        uint256 collateralMCR = collateralParams[vaultCollateral].minRange;
        uint256 vaultMCR = userVault.mcr;

        if (userVault.mcr == 0) {
            return 0;
        }

        if (userVault.mcr >= getMaxRange(vaultCollateral)) {
            return baseFee;
        }

        if (userVault.mcr <= getMinRange(vaultCollateral)) {
            return maxFee;

        } else {
            uint256 slope = (maxFee - baseFee) * 1e18 / (maxRange - collateralMCR);
            uint256 rate = baseFee + slope * (maxRange - vaultMCR) / 1e18;

            return rate;
        }
    }

    function calculateCR(address vaultCollateral, address vaultOwner) public view returns (uint256) {
        Vault memory userVault = userVaults[vaultOwner][vaultCollateral];

        if (userVault.debt != 0) {
            uint256 price = IPriceFeed(priceFeed).fetchPrice(vaultCollateral);
            uint256 cr = (userVault.collateral * price * 100 / userVault.debt);
            return cr;

        } else {
            return type(uint256).max;
        }
    }

    function calculateNCR(address vaultCollateral, address vaultOwner) public view returns (uint256) {
        Vault memory userVault = userVaults[vaultOwner][vaultCollateral];

        if (userVault.debt != 0) {
            return (userVault.collateral * 1e20) / userVault.debt;
        } else {
            return type(uint256).max;
        }
    }

    /*
            ------------------------ PARAMETER SETTERS ------------------------
    */

    function setCollateralParameters(
        address _collateral, 
        uint256 mcrMinRange,
        uint256 mcrMaxRange, 
        uint256 mcrFactor, 
        uint256 baseFee, 
        uint256 maxFee, 
        uint256 minNetDebt, 
        uint256 mintCap, 
        uint256 liquidationPenalty 
    ) external onlyOwner {
        require(baseFee < maxFee, "Base fee must be smaller than max fee");

        collateralParams[_collateral].active = true;

        setMinRange(_collateral, mcrMinRange);
        setMaxRange(_collateral, mcrMaxRange);
        setMCRFactor(_collateral, mcrFactor);
        setBaseFee(_collateral, baseFee);
        setMaxFee(_collateral, maxFee);
        setMinNetDebt(_collateral, minNetDebt);
        setMintCap(_collateral, mintCap);
        setLiquidationPenalty(_collateral, liquidationPenalty);

        emit CollateralParamsSet(_collateral, mcrMinRange, mcrMaxRange, baseFee, minNetDebt, mintCap, liquidationPenalty);
    }

    function setMinRange(address collateral, uint256 minRange) public onlyOwner {
        require(isAddressValid(collateral), "Invalid collateral");
        require(minRange >= 100e16, "Min MCR 100%");

        CollateralParams storage collParams = collateralParams[collateral];
        collParams.minRange = minRange;
        emit MinRangeUpdated(collateral, minRange);
    }

    function setMaxRange(address collateral, uint256 maxRange) public onlyOwner {
        require(isAddressValid(collateral), "Invalid collateral");

        CollateralParams storage collParams = collateralParams[collateral];
        collParams.maxRange = maxRange;
        emit MaxRangeSet(collateral, maxRange);
    }

    function setMCRFactor(address collateral, uint256 mcrFactor) public onlyOwner {
        require(isAddressValid(collateral), "Invalid collateral");

        CollateralParams storage collParams = collateralParams[collateral];
        collParams.mcrFactor = mcrFactor;
        emit MCRFactorSet(collateral, mcrFactor);
    }

    function setBaseFee(address collateral, uint256 baseFee) public onlyOwner {
        require(isAddressValid(collateral),"Invalid collateral");

        CollateralParams storage collParams = collateralParams[collateral];
        collParams.baseFee = baseFee;
        emit BaseFeeSet(collateral, baseFee);
    }

    function setMaxFee(address collateral, uint256 maxFee) public onlyOwner {
        require(isAddressValid(collateral),"Invalid collateral");
        require(maxFee <= 100e16, "Max fee cannot exceed 100%");

        CollateralParams storage collParams = collateralParams[collateral];
        collParams.maxFee = maxFee;
        emit MaxFeeSet(collateral, maxFee);
    }

    function setMinNetDebt(address collateral, uint256 minNetDebt) public onlyOwner {
        require(isAddressValid(collateral), "Invalid collateral");

        CollateralParams storage collParams = collateralParams[collateral];
        uint256 oldMinNet = collParams.minNetDebt;
        collParams.minNetDebt = minNetDebt;
        emit MinNetDebtChanged(oldMinNet, minNetDebt);
    }

    function setMintCap(address collateral, uint256 mintCap) public onlyOwner {
        require(isAddressValid(collateral), "Invalid collateral");

        CollateralParams storage collParams = collateralParams[collateral];
        uint256 oldMintCap = collParams.mintCap;
        collParams.mintCap = mintCap;
        emit MintCapChanged(oldMintCap, mintCap);
    }

    function setLiquidationPenalty(address collateral, uint256 penalty) public onlyOwner {
        require(penalty <= 30e16, "Liquidation penalty cannot exceed 30%");

        CollateralParams storage collParams = collateralParams[collateral];
        uint256 oldPenalty = collParams.liquidationPenalty;
        collParams.liquidationPenalty = penalty;
        emit LiquidationPenaltyChanged(oldPenalty, penalty);
    }

    function setIsActive(address collateral, bool active) external onlyOwner {
        require(isAddressValid(collateral), "Invalid collateral");

        CollateralParams storage collParams = collateralParams[collateral];
        collParams.active = active;
        emit IsActiveSet(collateral, active);
    }

    function setRedemptionFee(uint256 fee) external onlyOwner {
        require(fee <= 10e16, "Redemption fee cannot exceed 10%");

        REDEMPTION_FEE = fee;
        emit RedemptionFeeSet(fee);
    }

    /*
            ------------------------ PARAMETER GETTERS ------------------------
    */

    function getMinNetDebt(address _collateral) public view returns(uint256) {
        return collateralParams[_collateral].minNetDebt;
    }

    function getIsActive(address _collateral) public view returns(bool) {
        return collateralParams[_collateral].active;
    }

    function getDecimals(address _collateral) external view returns(uint256) {
        return collateralParams[_collateral].decimals;
    }

    function getMinRange(address _collateral) public view returns(uint256) {
        return collateralParams[_collateral].minRange;
    }

    function getMCRFactor(address _collateral) public view returns(uint256) {
        return collateralParams[_collateral].mcrFactor;
    }

    function getBaseFee(address _collateral) public view returns(uint256) {
        return collateralParams[_collateral].baseFee;
    }

    function getMaxRange(address _collateral) public view returns(uint256) {
        return collateralParams[_collateral].maxRange;
    }

    function getMaxFee(address _collateral) public view returns(uint256) {
        return collateralParams[_collateral].maxFee;
    }

    function getMintCap(address _collateral) external view override returns(uint256) {
        return collateralParams[_collateral].mintCap;
    }

    function getLiquidationPenalty(address _collateral) external view override returns(uint256) {
        return collateralParams[_collateral].liquidationPenalty;
    }

    function getIndex(address _collateral) external view returns(uint256) {
        return (collateralParams[_collateral].index);
    }

    function getValidCollateral() external view returns(address[] memory) {
        return validCollateral;
    }

    function getRedemptionFee() external view returns(uint256) {
        return REDEMPTION_FEE;
    }
}