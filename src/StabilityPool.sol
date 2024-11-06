// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "./dependencies/IERC20.sol";
import "./interfaces/IStabilityPool.sol";
import "./dependencies/VaultMath.sol";
import "./interfaces/IVaultManager.sol";
import "./AddressBook.sol";

import "forge-std/console.sol";

contract StabilityPool is AddressBook, IStabilityPool {

    // Tracker for debtToken held in the pool. Changes when users deposit/withdraw, and when Vessel debt is offset.
    uint256 public totalDebtTokenDeposits;
    address[] public validCollaterals;
    mapping(address => uint256) public deposits; // depositor address -> deposit amount

    /*
     * depositSnapshots maintains an entry for each depositor
     * that tracks P, S, G, scale, and epoch.
     * depositor's snapshot is updated only when they
     * deposit or withdraw from stability pool
     * depositSnapshots are used to allocate GRVT rewards, calculate compoundedDepositAmount
     * and to calculate how much Collateral amount the depositor is entitled to
     */
    mapping(address => Snapshots) public depositSnapshots; // depositor address -> snapshots struct

    /*  Product 'P': Running product by which to multiply an initial deposit, in order to find the current compounded deposit,
     * after a series of liquidations have occurred, each of which cancel some debt tokens debt with the deposit.
     *
     * During its lifetime, a deposit's value evolves from d_t to d_t * P / P_t , where P_t
     * is the snapshot of P taken at the instant the deposit was made. 18-digit decimal.
     */
    uint256 public P = 1e18;
    uint256 public constant SCALE_FACTOR = 1e9;

    // Each time the scale of P shifts by SCALE_FACTOR, the scale is incremented by 1
    uint128 public currentScale;

    // With each offset that fully empties the Pool, the epoch is incremented by 1
    uint128 public currentEpoch;

    /* Collateral amount Gain sum 'S': During its lifetime, each deposit d_t earns an Collateral amount gain of ( d_t * [S - S_t] )/P_t,
     * where S_t is the depositor's snapshot of S taken at the time t when the deposit was made.
     *
     * The 'S' sums are stored in a nested mapping (epoch => scale => sum):
     *
     * - The inner mapping records the (scale => sum)
     * - The middle mapping records (epoch => (scale => sum))
     * - The outer mapping records (collateralType => (epoch => (scale => sum)))
     */
    mapping(address => mapping(uint128 => mapping(uint128 => uint256))) public epochToScaleToSum;

    /*
     * Similarly, the sum 'G' is used to calculate GRVT gains. During it's lifetime, each deposit d_t earns a GRVT gain of
     *  ( d_t * [G - G_t] )/P_t, where G_t is the depositor's snapshot of G taken at time t when  the deposit was made.
     *
     *  GRVT reward events occur are triggered by depositor operations (new deposit, topup, withdrawal), and liquidations.
     *  In each case, the GRVT reward is issued (i.e. G is updated), before other state changes are made.
     */
    mapping(uint128 => mapping(uint128 => uint256)) public epochToScaleToG;

    // Error trackers for the error correction in the offset calculation
    uint256[] public lastAssetError_Offset;
    uint256 public lastDebtTokenLossError_Offset;

    /**
     * @notice add a collateral
     * @dev should be called anytime a collateral is added to controller
     * keeps all arrays the correct length
     * @param _collateral address of collateral to add
     */
    function addCollateralType(address _collateral) external onlyOwner {
        lastAssetError_Offset.push(0);
        validCollaterals.push(_collateral);
    }

    /**
     * @notice getter function
     * @dev gets total debtToken from deposits
     * @return totalDebtTokenDeposits
     */
    function getTotalDebtTokenDeposits() external view override returns (uint256) {
        return totalDebtTokenDeposits;
    }

    // --- External Depositor Functions ---

    /**
     * @notice Used to provide debt tokens to the stability Pool
     * @param _amount amount of debtToken provided
     * @param _assets an array of collaterals to be claimed. 
     * Skipping a collateral forfeits the available rewards (can be useful for gas optimizations)
     */
    function deposit(uint256 _amount, address[] calldata _assets) external {
        require(_amount != 0, "StabilityPool: Amount must be non-zero");

        uint256 initialDeposit = deposits[msg.sender];
        (address[] memory gainAssets, uint256[] memory gainAmounts) = getDepositorGains(msg.sender, _assets);
        uint256 compoundedDeposit = getCompoundedDebtTokenDeposits(msg.sender);
        uint256 loss = initialDeposit - compoundedDeposit; // Needed only for event log
        uint256 newTotalDeposits = totalDebtTokenDeposits + _amount;
        uint256 newDeposit = compoundedDeposit + _amount;
        totalDebtTokenDeposits = newTotalDeposits;

        _updateDepositAndSnapshots(msg.sender, newDeposit);
        _sendGainsToDepositor(msg.sender, gainAssets, gainAmounts); // send any collateral gains accrued to the depositor

        IERC20(debtToken).transferFrom(msg.sender, address(this), _amount);

        emit StabilityPoolDebtTokenBalanceUpdated(newTotalDeposits);
        emit UserDepositChanged(msg.sender, newDeposit);
        emit GainsWithdrawn(msg.sender, gainAssets, gainAmounts, loss); // loss required for event log
    }
    /** 
    * @param _amount amount of debtToken to withdraw
    * @param _assets an array of collaterals to be claimed.
    */

    function withdraw(uint256 _amount, address[] calldata _assets) external {
        (address[] memory assets, uint256[] memory amounts) = _withdrawFromSP(_amount, _assets);
        _sendGainsToDepositor(msg.sender, assets, amounts);

        emit UserWithdrawal(msg.sender, _amount);
    }

    /**
     * @notice withdraw from the stability pool
     * @param _amount debtToken amount to withdraw
     * @param _assets an array of collaterals to be claimed. 
     * @return assets address of assets withdrawn, amount of asset withdrawn
     */
    function _withdrawFromSP(
        uint256 _amount,
        address[] calldata _assets
    ) internal returns (address[] memory assets, uint256[] memory amounts) {
        uint256 initialDeposit = deposits[msg.sender];
        require(initialDeposit != 0, "StabilityPool: User must have a non-zero deposit");

        (assets, amounts) = getDepositorGains(msg.sender, _assets);

        uint256 compoundedDeposit = getCompoundedDebtTokenDeposits(msg.sender);
        uint256 debtTokensToWithdraw = VaultMath._min(_amount, compoundedDeposit);
        uint256 loss = initialDeposit - compoundedDeposit; // Needed only for event log

        _sendToDepositor(msg.sender, debtTokensToWithdraw);

        // Update deposit
        uint256 newDeposit = compoundedDeposit - debtTokensToWithdraw;
        _updateDepositAndSnapshots(msg.sender, newDeposit);

        emit UserDepositChanged(msg.sender, newDeposit);
        emit GainsWithdrawn(msg.sender, assets, amounts, loss); // loss required for event log
    }

    // --- Liquidation functions ---

    /**
     * @notice sets the offset for liquidation
     * @dev Cancels out the specified debt against the debtTokens contained in the Stability Pool (as far as possible)
     * and transfers the Vessel's collateral from ActivePool to StabilityPool.
     * Only called by liquidation functions in the VesselManager.
     * @param _debtToOffset how much debt to offset
     * @param _asset token address
     * @param _amountAdded token amount as uint256
     */
    function offsetDebt(uint256 _debtToOffset, address _asset, uint256 _amountAdded) external onlyVaultOperations {
        uint256 cachedTotalDebtTokenDeposits = totalDebtTokenDeposits; // cached to save an SLOAD

        if (cachedTotalDebtTokenDeposits == 0 || _debtToOffset == 0) {
            return;
        }
        
        (uint256 collGainPerUnitStaked, uint256 debtLossPerUnitStaked) = _computeRewardsPerUnitStaked(
            _asset,
            _amountAdded,
            _debtToOffset,
            cachedTotalDebtTokenDeposits
        );

        _updateRewardSumAndProduct(_asset, collGainPerUnitStaked, debtLossPerUnitStaked); // updates S and P
        _decreaseDebtTokens(_debtToOffset);

        IERC20(debtToken).burn(address(this), _debtToOffset);
        IERC20(_asset).transferFrom(msg.sender, address(this), _amountAdded);
    }

    // --- Offset helper functions ---

    /**
     * @notice Compute the debtToken and Collateral amount rewards. Uses a "feedback" error correction, to keep
     * the cumulative error in the P and S state variables low:
     *
     * @dev 1) Form numerators which compensate for the floor division errors that occurred the last time this
     * function was called.
     * 2) Calculate "per-unit-staked" ratios.
     * 3) Multiply each ratio back by its denominator, to reveal the current floor division error.
     * 4) Store these errors for use in the next correction when this function is called.
     * 5) Note: static analysis tools complain about this "division before multiplication", however, it is intended.
     * @param _asset Address of token
     * @param _amountAdded amount as uint256
     * @param _debtToOffset amount of debt to offset
     * @param _totalDeposits How much user has deposited
     */
    function _computeRewardsPerUnitStaked(
        address _asset,
        uint256 _amountAdded,
        uint256 _debtToOffset,
        uint256 _totalDeposits
    ) internal returns (uint256 collGainPerUnitStaked, uint256 debtLossPerUnitStaked) {
        uint256 assetIndex = IVaultManager(vaultManager).getIndex(_asset);
        uint256 collateralNumerator = (_amountAdded * VaultMath.DECIMAL_PRECISION) + lastAssetError_Offset[assetIndex];
        require(_debtToOffset <= _totalDeposits, "StabilityPool: Debt is larger than totalDeposits");
        if (_debtToOffset == _totalDeposits) {
            debtLossPerUnitStaked = VaultMath.DECIMAL_PRECISION; // When the Pool depletes to 0, so does each deposit
            lastDebtTokenLossError_Offset = 0;
        } else {
            uint256 lossNumerator = (_debtToOffset * VaultMath.DECIMAL_PRECISION) - lastDebtTokenLossError_Offset;
            /*
             * Add 1 to make error in quotient positive. We want "slightly too much" loss,
             * which ensures the error in any given compoundedDeposit favors the Stability Pool.
             */
            debtLossPerUnitStaked = (lossNumerator / _totalDeposits) + 1;
            lastDebtTokenLossError_Offset = (debtLossPerUnitStaked * _totalDeposits) - lossNumerator;
        }
        collGainPerUnitStaked = collateralNumerator / _totalDeposits;
        lastAssetError_Offset[assetIndex] = collateralNumerator - (collGainPerUnitStaked * _totalDeposits);
    }

    function _updateRewardSumAndProduct(
        address _asset,
        uint256 _collGainPerUnitStaked,
        uint256 _debtLossPerUnitStaked
    ) internal {
        require(_debtLossPerUnitStaked <= VaultMath.DECIMAL_PRECISION, "StabilityPool: Loss < 1");
        uint256 currentP = P;
        uint256 newP;

        /*
         * The newProductFactor is the factor by which to change all deposits, due to the depletion of Stability Pool debt tokens in the liquidation.
         * We make the product factor 0 if there was a pool-emptying. Otherwise, it is (1 - _debtLossPerUnitStaked)
         */
        uint256 newProductFactor = VaultMath.DECIMAL_PRECISION - _debtLossPerUnitStaked;
        uint128 currentScaleCached = currentScale;
        uint128 currentEpochCached = currentEpoch;
        uint256 currentS = epochToScaleToSum[_asset][currentEpochCached][currentScaleCached];

        /*
         * Calculate the new S first, before we update P.
         * The asset gain for any given depositor from a liquidation depends on the value of their deposit
         * (and the value of totalDeposits) prior to the Stability being depleted by the debt in the liquidation.
         *
         * Since S corresponds to asset gain, and P to deposit loss, we update S first.
         */
        uint256 marginalAssetGain = _collGainPerUnitStaked * currentP;
        uint256 newS = currentS + marginalAssetGain;
        epochToScaleToSum[_asset][currentEpochCached][currentScaleCached] = newS;
        emit S_Updated(_asset, newS, currentEpochCached, currentScaleCached);

        // If the Stability Pool was emptied, increment the epoch, and reset the scale and product P
        if (newProductFactor == 0) {
            currentEpochCached += 1;
            currentEpoch = currentEpochCached;
            emit EpochUpdated(currentEpochCached);
            currentScale = 0;
            emit ScaleUpdated(0);
            newP = VaultMath.DECIMAL_PRECISION;

            // If multiplying P by a non-zero product factor would reduce P below the scale boundary, increment the scale
        } else {
            uint256 mulCached = currentP * newProductFactor;
            uint256 mulDivCached = mulCached / VaultMath.DECIMAL_PRECISION;

            if (mulDivCached < SCALE_FACTOR) {
                newP = (mulCached * SCALE_FACTOR) / VaultMath.DECIMAL_PRECISION;
                currentScaleCached += 1;
                currentScale = currentScaleCached;
                emit ScaleUpdated(currentScaleCached);
            } else {
                newP = mulDivCached;
            }
        }

        require(newP != 0, "StabilityPool: P = 0");
        P = newP;
        emit P_Updated(newP);
    }

    function _decreaseDebtTokens(uint256 _amount) internal {
        uint256 newTotalDeposits = totalDebtTokenDeposits - _amount;
        totalDebtTokenDeposits = newTotalDeposits;
        emit StabilityPoolDebtTokenBalanceUpdated(newTotalDeposits);
    }

    // --- Reward calculator functions for depositor ---

    /**
     * @notice Calculates the gains earned by the deposit since its last snapshots were taken for selected assets.
     * @dev Given by the formula:  E = d0 * (S - S(0))/P(0)
     * where S(0) and P(0) are the depositor's snapshots of the sum S and product P, respectively.
     * d0 is the last recorded deposit value.
     * @param _depositor address of depositor in question
     * @param _assets array of assets to check gains for
     * @return assets, amounts
     */
    function getDepositorGains(
        address _depositor,
        address[] memory _assets
    ) public view returns (address[] memory, uint256[] memory) {
        uint256 initialDeposit = deposits[_depositor];

        if (initialDeposit == 0) {
            address[] memory emptyAddress = new address[](0);
            uint256[] memory emptyUint = new uint256[](0);
            return (emptyAddress, emptyUint);
        }

        Snapshots storage snapshots = depositSnapshots[_depositor];

        uint256[] memory amountsFromNewGains = _calculateNewGains(initialDeposit, snapshots, _assets);
        return (_assets, amountsFromNewGains);
    }

    /**
     * @notice get gains on each possible asset by looping through
     * @dev assets with _getGainFromSnapshots function
     * @param initialDeposit Amount of initial deposit
     * @param snapshots struct snapshots
     * @param _assets ascending ordered array of assets to calculate and claim gains
     */
    function _calculateNewGains(
        uint256 initialDeposit,
        Snapshots storage snapshots,
        address[] memory _assets
    ) internal view returns (uint256[] memory amounts) {
        uint256 assetsLen = _assets.length;
        // asset list must be on ascending order - used to avoid any repeated elements
        unchecked {
            for (uint256 i = 1; i < assetsLen; i++) {
                if (_assets[i] <= _assets[i-1]) {
                    revert StabilityPool__ArrayNotInAscendingOrder();
                }
            }
        }
        amounts = new uint256[](assetsLen);
        for (uint256 i = 0; i < assetsLen; ) {
            amounts[i] = _getGainFromSnapshots(initialDeposit, snapshots, _assets[i]);
            unchecked {
                i++;
            }
        }
    }

    /**
     * @notice gets the gain in S for a given asset
     * @dev for a user who deposited initialDeposit
     * @param initialDeposit Amount of initialDeposit
     * @param snapshots struct snapshots
     * @param asset asset to gain snapshot
     * @return uint256 the gain
     */
    function _getGainFromSnapshots(
        uint256 initialDeposit,
        Snapshots storage snapshots,
        address asset
    ) internal view returns (uint256) {
        /*
         * Grab the sum 'S' from the epoch at which the stake was made. The Collateral amount gain may span up to one scale change.
         * If it does, the second portion of the Collateral amount gain is scaled by 1e9.
         * If the gain spans no scale change, the second portion will be 0.
         */
        uint256 S_Snapshot = snapshots.S[asset];
        uint256 P_Snapshot = snapshots.P;

        mapping(uint128 => uint256) storage scaleToSum = epochToScaleToSum[asset][snapshots.epoch];
        uint256 firstPortion = scaleToSum[snapshots.scale] - S_Snapshot;
        uint256 secondPortion = scaleToSum[snapshots.scale + 1] / SCALE_FACTOR;

        uint256 assetGain = (initialDeposit * (firstPortion + secondPortion)) / P_Snapshot / VaultMath.DECIMAL_PRECISION;

        return assetGain;
    }

    // --- Compounded deposit and compounded System stake ---

    /*
     * Return the user's compounded deposit. Given by the formula:  d = d0 * P/P(0)
     * where P(0) is the depositor's snapshot of the product P, taken when they last updated their deposit.
     */
    function getCompoundedDebtTokenDeposits(address _depositor) public view override returns (uint256) {
        uint256 initialDeposit = deposits[_depositor];
        if (initialDeposit == 0) {
            return 0;
        }

        return _getCompoundedStakeFromSnapshots(initialDeposit, depositSnapshots[_depositor]);
    }

    // Internal function, used to calculate compounded deposits and compounded stakes.
    function _getCompoundedStakeFromSnapshots(
        uint256 initialStake,
        Snapshots storage snapshots
    ) internal view returns (uint256) {
        uint256 snapshot_P = snapshots.P;
        uint128 scaleSnapshot = snapshots.scale;
        uint128 epochSnapshot = snapshots.epoch;

        // If stake was made before a pool-emptying event, then it has been fully cancelled with debt -- so, return 0
        if (epochSnapshot < currentEpoch) {
            return 0;
        }

        uint256 compoundedStake;
        uint128 scaleDiff = currentScale - scaleSnapshot;

        /* Compute the compounded stake. If a scale change in P was made during the stake's lifetime,
         * account for it. If more than one scale change was made, then the stake has decreased by a factor of
         * at least 1e-9 -- so return 0.
         */
        if (scaleDiff == 0) {
            compoundedStake = (initialStake * P) / snapshot_P;
        } else if (scaleDiff == 1) {
            compoundedStake = (initialStake * P) / snapshot_P / SCALE_FACTOR;
        } else {
            compoundedStake = 0;
        }

        /*
         * If compounded deposit is less than a billionth of the initial deposit, return 0.
         *
         * NOTE: originally, this line was in place to stop rounding errors making the deposit too large. However, the error
         * corrections should ensure the error in P "favors the Pool", i.e. any given compounded deposit should slightly less
         * than it's theoretical value.
         *
         * Thus it's unclear whether this line is still really needed.
         */
        if (compoundedStake < initialStake / 1e9) {
            return 0;
        }

        return compoundedStake;
    }

    /**
     * @notice transfer collateral gains to the depositor
     * @dev this function also unwraps wrapped assets
     * before sending to depositor
     * @param _to address
     * @param assets array of address
     * @param amounts array of uint256. Includes pending collaterals since that was added in previous steps
     */
    function _sendGainsToDepositor(address _to, address[] memory assets, uint256[] memory amounts) internal {
        uint256 assetsLen = assets.length;
        require(assetsLen == amounts.length, "StabilityPool: Length mismatch");
        for (uint256 i = 0; i < assetsLen; ) {
            uint256 amount = amounts[i];
            if (amount == 0) {
                unchecked {
                    i++;
                }
                continue;
            }
            address asset = assets[i];
            // Assumes we're internally working only with the wrapped version of ERC20 tokens
            IERC20(asset).transfer(_to, amount);
            unchecked {
                i++;
            }
        }
    }

    // Send debt tokens to user and decrease deposits in Pool
    function _sendToDepositor(address _depositor, uint256 debtTokenWithdrawal) internal {
        if (debtTokenWithdrawal == 0) {
            return;
        }

        IERC20(debtToken).transfer(_depositor, debtTokenWithdrawal);
        _decreaseDebtTokens(debtTokenWithdrawal);
    }

    // --- Stability Pool Deposit Functionality ---

    /**
     * @notice updates deposit and snapshots internally
     * @dev if _newValue is zero, delete snapshot for given _depositor and emit event
     * otherwise, add an entry or update existing entry for _depositor in the depositSnapshots
     * with current values for P, S, G, scale and epoch and then emit event.
     * @param _depositor address
     * @param _newValue uint256
     */
    function _updateDepositAndSnapshots(address _depositor, uint256 _newValue) internal {
        deposits[_depositor] = _newValue;
        address[] memory colls = getValidCollateral();
        uint256 collsLen = colls.length;

        Snapshots storage depositorSnapshots = depositSnapshots[_depositor];
        if (_newValue == 0) {
            for (uint256 i = 0; i < collsLen; ) {
                depositSnapshots[_depositor].S[colls[i]] = 0;
                unchecked {
                    i++;
                }
            }
            depositorSnapshots.P = 0;
            depositorSnapshots.G = 0;
            depositorSnapshots.epoch = 0;
            depositorSnapshots.scale = 0;
            emit DepositSnapshotUpdated(_depositor, 0, 0);
            return;
        }
        uint128 currentScaleCached = currentScale;
        uint128 currentEpochCached = currentEpoch;
        uint256 currentP = P;

        for (uint256 i = 0; i < collsLen; ) {
            address asset = colls[i];
            uint256 currentS = epochToScaleToSum[asset][currentEpochCached][currentScaleCached];
            depositSnapshots[_depositor].S[asset] = currentS;
            unchecked {
                i++;
            }
        }

        uint256 currentG = epochToScaleToG[currentEpochCached][currentScaleCached];
        depositorSnapshots.P = currentP;
        depositorSnapshots.G = currentG;
        depositorSnapshots.scale = currentScaleCached;
        depositorSnapshots.epoch = currentEpochCached;

        emit DepositSnapshotUpdated(_depositor, currentP, currentG);
    }

    function getValidCollateral() public view returns(address[] memory) {
        return validCollaterals;
    }

    function S(address _depositor, address _asset) external view returns (uint256) {
        return depositSnapshots[_depositor].S[_asset];
    }
}