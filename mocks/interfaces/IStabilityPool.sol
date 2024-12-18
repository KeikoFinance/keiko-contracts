// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IStabilityPool {
    // --- Structs ---

    struct Snapshots {
        mapping(address => uint256) S;
        uint256 P;
        uint256 G;
        uint128 scale;
        uint128 epoch;
    }

    // --- Events ---

    event DepositSnapshotUpdated(address indexed _depositor, uint256 _P, uint256 _G);
    event SystemSnapshotUpdated(uint256 _P, uint256 _G);

    event AssetSent(address _asset, address _to, uint256 _amount);
    event GainsWithdrawn(address indexed _depositor, address[] _collaterals, uint256[] _amounts, uint256 _debtTokenLoss);
    event StabilityPoolAssetBalanceUpdated(address _asset, uint256 _newBalance);
    event StabilityPoolDebtTokenBalanceUpdated(uint256 _newBalance);
    event StakeChanged(uint256 _newSystemStake, address _depositor);
    event UserDepositChanged(address indexed _depositor, uint256 _newDeposit);
    event UserWithdrawal(address indexed _user, uint256 _amount);

    event P_Updated(uint256 _P);
    event S_Updated(address _asset, uint256 _S, uint128 _epoch, uint128 _scale);
    event G_Updated(uint256 _G, uint128 _epoch, uint128 _scale);
    event EpochUpdated(uint128 _currentEpoch);
    event ScaleUpdated(uint128 _currentScale);

    // --- Errors ---

    error StabilityPool__ActivePoolOnly(address sender, address expected);
    error StabilityPool__AdminContractOnly(address sender, address expected);
    error StabilityPool__VesselManagerOnly(address sender, address expected);
    error StabilityPool__ArrayNotInAscendingOrder();

    // --- Functions ---

    function addCollateralType(address _collateral) external;

    /*
     * Initial checks:
     * - _amount is not zero
     * - Sends depositor's accumulated gains (GRVT, assets) to depositor
     */
    function deposit(uint256 _amount, address[] calldata _assets) external;

    /*
     * Initial checks:
     * - _amount is zero or there are no under collateralized vessels left in the system
     * - User has a non zero deposit
     * ---
     * - Decreases deposit's stake, and takes new snapshots.
     *
     * If _amount > userDeposit, the user withdraws all of their compounded deposit.
     */
    function withdraw(uint256 _amount, address[] calldata _assets) external;

    /*
    Initial checks:
     * - Caller is VesselManager
     * ---
     * Cancels out the specified debt against the debt token contained in the Stability Pool (as far as possible)
     * and transfers the Vessel's collateral from ActivePool to StabilityPool.
     * Only called by liquidation functions in the VesselManager.
     */
    function offsetDebt(uint256 _debt, address _asset, uint256 _coll) external;

    /*
     * Returns debt tokens held in the pool. Changes when users deposit/withdraw, and when Vessel debt is offset.
     */
    function getTotalDebtTokenDeposits() external view returns (uint256);

    /*
     * Calculates the asset gains earned by the deposit since its last snapshots were taken.
     */
    function getDepositorGains(
        address _depositor,
        address[] calldata _assets
    ) external view returns (address[] memory, uint256[] memory);

    /*
     * Return the user's compounded deposits.
     */
    function getCompoundedDebtTokenDeposits(address _depositor) external view returns (uint256);
}