// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./interfaces/IPriceFeed.sol";
import "./dependencies/Ownable.sol";
import "./AddressBook.sol";

/**
 * @title PriceFeed contract supporting Chainlink, System and Pyth oracles
 */
contract PriceFeed is IPriceFeed, Ownable {
    uint256 public constant TARGET_DIGITS = 18;
    uint256 public constant SPOT_CONVERSION_BASE = 8; // For spot prices: 10^(8-szDecimals)
    uint256 public constant PERP_CONVERSION_BASE = 6; // For spot prices: 10^(6-szDecimals)
    uint256 public constant SYSTEM_TO_WAD = 1e18;    // To convert to 1e18 notation

    mapping(address => OracleRecordV2) public oracles;
    mapping(address => uint256) public lastCorrectPrice;

    /*
        ------------------- EXTERNAL FUNCTIONS -------------------
    */
    
    /**
     * @notice Fetches price for any token regardless of oracle type
     * @param _token Address of the token to fetch price for
     * @return Price in 1e18 (WAD) format
     * @dev Handles ETH-indexed prices by multiplying with ETH price if needed
     */
    function fetchPrice(address _token) public view virtual override returns (uint256) {
        OracleRecordV2 memory oracle = oracles[_token];
        uint256 price = _fetchOracleScaledPrice(oracle);

        if (price != 0) {
            // If the price is ETH indexed, multiply by ETH price
            return oracle.isEthIndexed ? _calcEthIndexedPrice(price) : price;
        }

        revert PriceFeed__InvalidOracleResponseError(_token);
    }

    /**
     * @notice Sets a Chainlink oracle for a token
     * @param _token Token address to set oracle for
     * @param _chainlinkOracle Address of the Chainlink price feed contract
     * @param _timeoutSeconds Maximum age allowed for price data
     * @param _isEthIndexed Whether price should be multiplied by ETH price
     * @dev Verifies decimals and initial price fetch
     */
    function setChainlinkOracle(
        address _token,
        address _chainlinkOracle,
        uint256 _timeoutSeconds,
        bool _isEthIndexed
    ) external onlyOwner {
        uint8 decimals = _fetchDecimals(_chainlinkOracle);
        if (decimals == 0) {
            revert PriceFeed__InvalidDecimalsError();
        }

        OracleRecordV2 memory newOracle = OracleRecordV2({
            oracleAddress: _chainlinkOracle,
            timeoutSeconds: _timeoutSeconds,
            decimals: decimals,
            isEthIndexed: _isEthIndexed,
            oracleType: OracleType.CHAINLINK,
            szDecimals: 0,
            priceIndex: 0,
            pythPriceId: bytes32(0)
        });

        uint256 price = _fetchOracleScaledPrice(newOracle);
        if (price == 0) {
            revert PriceFeed__InvalidOracleResponseError(_token);
        }

        oracles[_token] = newOracle;
        emit ChainlinkOracleSet(_token, _chainlinkOracle, _timeoutSeconds, _isEthIndexed);
    }

    /**
     * @notice Sets a SystemOracle for a token
     * @param _token Token address to set oracle for
     * @param _systemOracle Address of the SystemOracle contract
     * @param _priceIndex Index in the price array for this token
     * @param _szDecimals Decimals for price scaling
     * @dev Uses fixed 3600 second timeout
     */
    function setSystemOracle(
        address _token,
        address _systemOracle,
        uint256 _priceIndex,
        uint8 _szDecimals
    ) external onlyOwner {
        OracleRecordV2 memory newOracle = OracleRecordV2({
            oracleAddress: _systemOracle,
            timeoutSeconds: 3600,
            decimals: 0,
            isEthIndexed: false,
            oracleType: OracleType.SYSTEM,
            szDecimals: _szDecimals,
            priceIndex: _priceIndex,
            pythPriceId: bytes32(0)
        });

        uint256 price = _fetchOracleScaledPrice(newOracle);
        if (price == 0) {
            revert PriceFeed__InvalidOracleResponseError(_token);
        }

        oracles[_token] = newOracle;
        emit SystemOracleSet(_token, _systemOracle, _priceIndex, _szDecimals);
    }

    /**
     * @notice Sets a Pyth Network oracle for a token
     * @param _token Token address to set oracle for
     * @param _pythOracle Address of the Pyth oracle contract
     * @param _priceId Unique identifier for the price feed
     * @param _timeoutSeconds Maximum age allowed for price data
     * @param _isEthIndexed Whether price should be multiplied by ETH price
     * @dev Validates addresses and parameters before setting
     */
    function setPythOracle(
        address _token,
        address _pythOracle,
        bytes32 _priceId,
        uint256 _timeoutSeconds,
        bool _isEthIndexed
    ) external onlyOwner {
        require(_pythOracle != address(0), "Invalid Pyth oracle address");
        require(_priceId != bytes32(0), "Invalid price ID");
        require(_timeoutSeconds > 0, "Invalid timeout");

        OracleRecordV2 memory newOracle = OracleRecordV2({
            oracleAddress: _pythOracle,
            timeoutSeconds: _timeoutSeconds,
            decimals: 0,
            isEthIndexed: _isEthIndexed,
            oracleType: OracleType.PYTH,
            szDecimals: 0,
            priceIndex: 0,
            pythPriceId: _priceId
        });

        uint256 price = _fetchOracleScaledPrice(newOracle);
        if (price == 0) {
            revert PriceFeed__InvalidOracleResponseError(_token);
        }

        oracles[_token] = newOracle;
        emit PythOracleSet(_token, _pythOracle, _priceId, _timeoutSeconds, _isEthIndexed);
    }

    /*
        ------------------- INTERNAL FUNCTIONS -------------------
    */

    /**
     * @notice Routes price fetching to appropriate oracle type
     * @param oracle OracleRecordV2 struct containing oracle configuration
     * @return Normalized price in 18 decimal format
     * @dev Handles Chainlink, System, and Pyth oracle types
     */
    function _fetchOracleScaledPrice(OracleRecordV2 memory oracle) internal view returns (uint256) {
        if (oracle.oracleAddress == address(0)) {
            revert PriceFeed__UnknownAssetError();
        }

        uint256 oraclePrice;
        uint256 priceTimestamp;

        if (oracle.oracleType == OracleType.CHAINLINK) {
            (oraclePrice, priceTimestamp) = _fetchChainlinkOracleResponse(oracle.oracleAddress);
            if (oraclePrice != 0 && !_isStalePrice(priceTimestamp, oracle.timeoutSeconds)) {
                return _scalePriceByDigits(oraclePrice, oracle.decimals);
            }
        } else if (oracle.oracleType == OracleType.SYSTEM) {
            (oraclePrice, priceTimestamp) = _fetchSystemOracleResponse(
                oracle.oracleAddress,
                oracle.priceIndex,
                oracle.szDecimals
            );
            if (oraclePrice != 0 && !_isStalePrice(priceTimestamp, oracle.timeoutSeconds)) {
                return oraclePrice;
            }
        } else if (oracle.oracleType == OracleType.PYTH) {
            (oraclePrice, priceTimestamp) = _fetchPythOracleResponse(
                oracle.oracleAddress,
                oracle.pythPriceId,
                oracle.timeoutSeconds
            );
            if (oraclePrice != 0) {
                return oraclePrice;
            }
        }

        return 0;
    }

    /**
     * @notice Fetches and normalizes price data from Pyth Network oracle
     * @param _oracleAddress Pyth oracle contract address
     * @param _priceId Price feed identifier
     * @param _timeoutSeconds Maximum age of price data
     * @return price Normalized price in 18 decimals
     * @return timestamp Time of price update
     * @dev Handles Pyth's exponent-based price format
     */
    function _fetchPythOracleResponse(
        address _oracleAddress,
        bytes32 _priceId,
        uint256 _timeoutSeconds
    ) internal view returns (uint256 price, uint256 timestamp) {
        try IPyth(_oracleAddress).getPriceNoOlderThan(_priceId, _timeoutSeconds) returns (PythStructs.Price memory pythPrice) {
            // Ensure the price data is valid
            if (pythPrice.publishTime == 0 || pythPrice.price <= 0) {
                revert PriceFeed__InvalidPythPrice();
            }

            // Convert price from int64 to uint256
            int256 priceInt = pythPrice.price;
            if (priceInt < 0) {
                revert PriceFeed__InvalidPythPrice();
            }
            uint256 rawPrice = uint256(priceInt);

            // Adjust for Pyth's exponent to normalize to 1e18
            int32 expo = pythPrice.expo;
            if (expo < 0) {
                // For negative exponents, scale up
                uint32 absoluteExpo = uint32(-expo); // Convert negative exponent to positive
                if (absoluteExpo > 18) {
                    revert PriceFeed__InvalidExponent(); // Prevent overflow
                }
                price = rawPrice * (10 ** (uint256(18) - uint256(absoluteExpo)));
            } else {
                // For positive exponents, scale down
                uint32 positiveExpo = uint32(expo);
                if (positiveExpo > 18) {
                    revert PriceFeed__InvalidExponent(); // Prevent underflow
                }
                price = rawPrice / (10 ** (uint256(positiveExpo + 18)));
            }

            // Set the price publish timestamp
            timestamp = pythPrice.publishTime;
        } catch {
            revert PriceFeed__InvalidPythPrice();
        }
    }

    /**
     * @notice Retrieves price data from Chainlink price feed
     * @param _oracleAddress Chainlink aggregator address
     * @return price Current price
     * @return timestamp Time of price update
     * @dev Validates round ID and ensures positive price
     */
    function _fetchChainlinkOracleResponse(
        address _oracleAddress
    ) internal view returns (uint256 price, uint256 timestamp) {
        try ChainlinkAggregatorV3Interface(_oracleAddress).latestRoundData() returns (
            uint80 roundId,
            int256 answer,
            uint256,
            uint256 updatedAt,
            uint80
        ) {
            if (roundId != 0 && updatedAt != 0 && answer > 0) {
                price = uint256(answer);
                timestamp = updatedAt;
            }
        } catch {
            revert PriceFeed__ChainlinkCallFailed();
        }
    }

    /**
     * @notice Fetches price data from SystemOracle
     * @param _oracleAddress SystemOracle contract address
     * @param _priceIndex Index in price array
     * @param _szDecimals Decimals for scaling
     * @return price Current price
     * @return timestamp Current block timestamp
     */
    function _fetchSystemOracleResponse(
        address _oracleAddress,
        uint256 _priceIndex,
        uint8 _szDecimals
    ) internal view returns (uint256 price, uint256 timestamp) {
        uint[] memory prices = ISystemOracle(_oracleAddress).getSpotPxs();
        
        if (_priceIndex < prices.length && prices[_priceIndex] != 0) {
            uint256 divisor = 10 ** (SPOT_CONVERSION_BASE - _szDecimals);
            price = (prices[_priceIndex] * SYSTEM_TO_WAD) / divisor;
            timestamp = block.timestamp;
        }
    }

    /**
     * @notice Checks if a price update is too old
     * @param _priceTimestamp Timestamp of price update
     * @param _oracleTimeoutSeconds Maximum allowed age
     * @return bool True if price is stale
     */
    function _isStalePrice(uint256 _priceTimestamp, uint256 _oracleTimeoutSeconds) internal view returns (bool) {
        return block.timestamp - _priceTimestamp > _oracleTimeoutSeconds;
    }

    /**
     * @notice Calculates ETH-indexed price
     * @param _ethAmount Amount to multiply by ETH price
     * @return Calculated price in 18 decimals
     */
    function _calcEthIndexedPrice(uint256 _ethAmount) internal view returns (uint256) {
        uint256 ethPrice = fetchPrice(address(0));
        return (ethPrice * _ethAmount) / 1e18;
    }

    /**
     * @notice Normalizes prices to 18 decimal format
     * @param _price Original price
     * @param _priceDigits Original decimal places
     * @return Price normalized to 18 decimals
     * @dev Handles both scaling up and down
     */
    function _scalePriceByDigits(uint256 _price, uint256 _priceDigits) internal pure returns (uint256) {
        unchecked {
            if (_priceDigits > TARGET_DIGITS) {
                return _price / (10 ** (_priceDigits - TARGET_DIGITS));
            } else if (_priceDigits < TARGET_DIGITS) {
                return _price * (10 ** (TARGET_DIGITS - _priceDigits));
            }
        }
        return _price;
    }

    /**
     * @notice Gets decimal places from Chainlink price feed
     * @param _oracle Chainlink aggregator address
     * @return Number of decimal places
     */
    function _fetchDecimals(address _oracle) internal view returns (uint8) {
        return ChainlinkAggregatorV3Interface(_oracle).decimals();
    }
}