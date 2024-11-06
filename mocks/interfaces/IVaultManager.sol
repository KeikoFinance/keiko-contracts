// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IVaultManager {
    // Events
    event CollateralAdded(address indexed collateral);
    event MCRUpdated(address _collateral, uint256 _mcr);
    event MCRFactorSet(address _collateral, uint256 _mcrFactor);
    event BaseFeeSet(address _collateral, uint256 _baseFee);
    event MaxFeeSet(address _collateral, uint256 _maxFee);
    event MaxRangeSet(address _collateral, uint256 _maxRange);
    event RedemptionFeeSet(uint256 _fee);
    event IsActiveSet(address indexed _collateral, bool _active);
    event MinNetDebtChanged(uint256 oldMinNetDebt, uint256 newMinNetDebt);
    event MintCapChanged(uint256 oldMintCap, uint256 newMintCap);
    event LiquidationPenaltyChanged(uint256 oldPenalty, uint256 newPenalty);
    event CollateralParamsSet(address indexed _collateral, uint256 mcr, uint256 maxRange, uint256 baseFee, uint256 minNetDebt, uint256 mintCap, uint256 liquidationPenalty);

    // Default Paramaters
    function MIN_NET_DEBT_DEFAULT() external view returns (uint256);
    function MINT_CAP_DEFAULT() external view returns (uint256);
    function MIN_CR_RANGE() external view returns (uint256);
    function MAX_CR_RANGE() external view returns (uint256);
    function MCR_FACTOR() external view returns (uint256);
    function LIQUIDATION_PENALTY() external view returns (uint256);
    function MAX_FEE() external view returns (uint256);
    function BASE_FEE() external view returns (uint256);
    function REDEMPTION_FEE() external view returns (uint256);
    function collPrice() external view returns (uint256);

    // Functions
    function validCollateral(uint256) external view returns (address);
    function checkVault(address coll, address owner) external view returns (uint256, uint256, uint256); // TEST FUNCTION REMOVE IN PROD
    function changePrice(uint256 newPrice) external; // TEST FUNCTION REMOVE IN PROD
    function adjustVaultData(address vaultCollateral, address vaultOwner, uint256 collateralAmount, uint256 debtAmount, uint256 mcr) external;
    function getVaultData(address vaultCollateral, address vaultOwner) external view returns (uint256, uint256, uint256);
    function getVaultInterestRate(address vaultCollateral, address vaultOwner) external view returns (uint256);
    function isAddressValid(address _address) external view returns (bool);
    function checkVaultState(address vaultCollateral, address vaultOwner) external view returns (bool);

    function calculateCR(address vaultCollateral, address vaultOwner) external view returns (uint256);
    function calculateNCR(address vaultCollateral, address vaultOwner) external view returns (uint256);
    function calculateARS(address vaultCollateral, address vaultOwner) external returns (uint256);

    function getMinNetDebt(address _collateral) external view returns (uint256);
    function getIsActive(address _collateral) external view returns (bool);
    function getDecimals(address _collateral) external view returns (uint256);
    function getMinRange(address _collateral) external view returns (uint256);
    function getMCRFactor(address _collateral) external view returns (uint256);
    function getBaseFee(address _collateral) external view returns (uint256);
    function getMaxRange(address _collateral) external view returns (uint256);
    function getMaxFee(address _collateral) external view returns (uint256);
    function getMintCap(address _collateral) external view returns (uint256);
    function getLiquidationPenalty(address _collateral) external view returns (uint256);
    function getIndex(address _collateral) external view returns (uint256);
    function getValidCollateral() external view returns (address[] memory);
    function getRedemptionFee() external view returns (uint256);
}