// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./interfaces/IPriceFeed.sol";
import "./dependencies/Ownable.sol";
import "./AddressBook.sol";


/**
 * @title Modified Liquity's PriceFeed contract to support Chainlink or Hyperliquid L1 Oracle for a given asset
 */
contract PriceFeed is IPriceFeed {
    uint256 public constant TARGET_DIGITS = 18;
    uint256 public constant SPOT_CONVERSION_BASE = 8; // For spot prices: 10^(8-szDecimals)
    uint256 public constant PERP_CONVERSION_BASE = 6; // For spot prices: 10^(6-szDecimals)
    uint256 public constant SYSTEM_TO_WAD = 1e18;    // To convert to 1e18 notation

    mapping(address => OracleRecordV2) public oracles;
    mapping(address => uint256) public lastCorrectPrice;

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
            szDecimals: 0,         // Not used for Chainlink
            priceIndex: 0          // Not used for Chainlink
        });

        uint256 price = _fetchOracleScaledPrice(newOracle);
        if (price == 0) {
            revert PriceFeed__InvalidOracleResponseError(_token);
        }

        oracles[_token] = newOracle;
    }

    function setSystemOracle(
        address _token,
        address _systemOracle,
        uint256 _priceIndex,
        uint8 _szDecimals
    ) external onlyOwner {
        OracleRecordV2 memory newOracle = OracleRecordV2({
            oracleAddress: _systemOracle,
            timeoutSeconds: 3600,   // Fixed timeout for SystemOracle
            decimals: 0,  // Not used for SystemOracle
            isEthIndexed: false,
            oracleType: OracleType.SYSTEM,
            szDecimals: _szDecimals,
            priceIndex: _priceIndex
        });

        uint256 price = _fetchOracleScaledPrice(newOracle);
        if (price == 0) {
            revert PriceFeed__InvalidOracleResponseError(_token);
        }

        oracles[_token] = newOracle;
    }

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
        } else {
            (oraclePrice, priceTimestamp) = _fetchSystemOracleResponse(
                oracle.oracleAddress,
                oracle.priceIndex,
                oracle.szDecimals
            );
            if (oraclePrice != 0 && !_isStalePrice(priceTimestamp, oracle.timeoutSeconds)) {
                return oraclePrice;
            }
        }

        return 0;
    }

    function fetchPrice(address _token) public view virtual override returns (uint256) {
        OracleRecordV2 memory oracle = oracles[_token];
        uint256 price = _fetchOracleScaledPrice(oracle);

        if (price != 0) {
            // If the price is ETH indexed, multiply by ETH price
            return oracle.isEthIndexed ? _calcEthIndexedPrice(price) : price;
        }

        revert PriceFeed__InvalidOracleResponseError(_token);
    }

    function _fetchSystemOracleResponse(
        address _oracleAddress,
        uint256 _priceIndex,
        uint8 _szDecimals
    ) internal view returns (uint256 price, uint256 timestamp) {
        uint[] memory prices = ISystemOracle(_oracleAddress).getSpotPxs();
        
        if (_priceIndex < prices.length && prices[_priceIndex] != 0) {
            // Convert the raw price to actual price
            // For spot prices: price / 10^(8-szDecimals)
            uint256 divisor = 10 ** (SPOT_CONVERSION_BASE - _szDecimals);
            price = (prices[_priceIndex] * SYSTEM_TO_WAD) / divisor;
            timestamp = block.timestamp;
        }
    }

    function _isStalePrice(uint256 _priceTimestamp, uint256 _oracleTimeoutSeconds) internal view returns (bool) {
        return block.timestamp - _priceTimestamp > _oracleTimeoutSeconds;
    }

    function _fetchChainlinkOracleResponse(
        address _oracleAddress
    ) internal view returns (uint256 price, uint256 timestamp) {
        try ChainlinkAggregatorV3Interface(_oracleAddress).latestRoundData() returns (
            uint80 roundId,
            int256 answer,
            uint256 /* startedAt */,
            uint256 updatedAt,
            uint80 /* answeredInRound */
        ) {
            if (roundId != 0 && updatedAt != 0 && answer != 0) {
                price = uint256(answer);
                timestamp = updatedAt;
            }
        } catch {
            // If call to Chainlink aggregator reverts, return a zero response
        }
    }

    function _calcEthIndexedPrice(uint256 _ethAmount) internal view returns (uint256) {
        uint256 ethPrice = fetchPrice(address(0));
        return (ethPrice * _ethAmount) / 1 ether;
    }

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

    function _fetchDecimals(address _oracle) internal view returns (uint8) {
        return ChainlinkAggregatorV3Interface(_oracle).decimals();
    }
}