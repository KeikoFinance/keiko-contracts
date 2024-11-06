// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*
 * @dev from https://github.com/smartcontractkit/chainlink/blob/develop/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol
 */
interface ChainlinkAggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface ISystemOracle {
    function getMarkPxs() external view returns (uint[] memory);
    function getOraclePxs() external view returns (uint[] memory);
    function getSpotPxs() external view returns (uint[] memory);
}

interface IPriceFeed {
    // Enums ---------------------------------------------------------------------------------------------------------
    enum OracleType { CHAINLINK, SYSTEM }

    // Structs -------------------------------------------------------------------------------------------------------
    struct OracleRecordV2 {
        address oracleAddress;     // Both
        uint256 timeoutSeconds;    // Both
        uint8 decimals;            // Chainlink
        bool isEthIndexed;         // Both
        OracleType oracleType;     // Both
        uint8 szDecimals;          // SystemOracle
        uint256 priceIndex;        // SystemOracle
    }

    // Custom Errors ------------------------------------------------------------------------------------------------
    error PriceFeed__ExistingOracleRequired();
    error PriceFeed__InvalidDecimalsError();
    error PriceFeed__InvalidOracleResponseError(address token);
    error PriceFeed__TimelockOnlyError();
    error PriceFeed__UnknownAssetError();

    // Events ------------------------------------------------------------------------------------------------------
    event ChainlinkOracleSet(address indexed token, address indexed oracle, uint256 timeout, bool isEthIndexed);
    event SystemOracleSet(address indexed token, address indexed oracle, uint256 priceIndex, uint8 szDecimals);

    // Functions ---------------------------------------------------------------------------------------------------
    /// @notice Fetches price for any token regardless of oracle type
    /// @param _token Address of the token to fetch price for
    /// @return Price in 1e18 (WAD) format
    function fetchPrice(address _token) external view returns (uint256);

    /// @notice Sets a Chainlink oracle for a token
    /// @param _token Token address
    /// @param _chainlinkOracle Chainlink oracle address
    /// @param _timeoutSeconds Maximum age of the price feed
    /// @param _isEthIndexed Whether the price should be multiplied by ETH price
    function setChainlinkOracle(
        address _token,
        address _chainlinkOracle,
        uint256 _timeoutSeconds,
        bool _isEthIndexed
    ) external;

    /// @notice Sets a SystemOracle for a token
    /// @param _token Token address
    /// @param _systemOracle SystemOracle address
    /// @param _priceIndex Index in the price array for this token
    /// @param _szDecimals Token decimals for price scaling
    function setSystemOracle(
        address _token,
        address _systemOracle,
        uint256 _priceIndex,
        uint8 _szDecimals
    ) external;
}