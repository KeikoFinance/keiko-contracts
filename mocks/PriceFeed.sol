// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./interfaces/IPriceFeed.sol";
import "./AddressBook.sol";

/**
 * @title The PriceFeed contract contains a directory of oracles for fetching prices for assets based on their
 *     addresses; optionally fallback oracles can also be registered in case the primary source fails or is stale.
 */
contract PriceFeed is IPriceFeed {

	/// @dev Used to convert an oracle price answer to an 18-digit precision uint
	uint256 public constant TARGET_DIGITS = 18;

	// State ------------------------------------------------------------------------------------------------------------

	mapping(address => OracleRecordV2) public oracles;
    mapping(address => uint256) public lastCorrectPrice;

	// Admin routines ---------------------------------------------------------------------------------------------------

	function setOracle(address _token, address _oracle, uint256 _timeoutSeconds, bool _isEthIndexed) external override {
		uint256 decimals = _fetchDecimals(_oracle);
		if (decimals == 0) {
			revert PriceFeed__InvalidDecimalsError();
		}

		OracleRecordV2 memory newOracle = OracleRecordV2({
			oracleAddress: _oracle,
			timeoutSeconds: _timeoutSeconds,
			decimals: decimals,
			isEthIndexed: _isEthIndexed
		});

		uint256 price = _fetchOracleScaledPrice(newOracle);
		if (price == 0) {
			revert PriceFeed__InvalidOracleResponseError(_token);
		}

		oracles[_token] = newOracle;

		//emit NewOracleRegistered(_token, _oracle, _isEthIndexed);
	}

	// Public functions -------------------------------------------------------------------------------------------------

	function fetchPrice(address _token) public view virtual returns (uint256) {
		// Tries fetching the price from the oracle
		OracleRecordV2 memory oracle = oracles[_token];
		uint256 price = _fetchOracleScaledPrice(oracle);

		if (price != 0) {
			return oracle.isEthIndexed ? _calcEthIndexedPrice(price) : price;
		}

		// If the oracle fails (and returns 0), try again with the fallback
		//oracle = fallbacks[_token];
		//price = _fetchOracleScaledPrice(oracle);

		//if (price != 0) {
		//	return oracle.isEthIndexed ? _calcEthIndexedPrice(price) : price;
		//}

		revert PriceFeed__InvalidOracleResponseError(_token);
	}

	// Internal functions -----------------------------------------------------------------------------------------------

	function _fetchDecimals(address _oracle) internal view returns (uint8) {
		return ChainlinkAggregatorV3Interface(_oracle).decimals();
	}

	function _fetchOracleScaledPrice(OracleRecordV2 memory oracle) internal view returns (uint256) {
		uint256 oraclePrice;
		uint256 priceTimestamp;

		if (oracle.oracleAddress == address(0)) {
			revert PriceFeed__UnknownAssetError();
		}
			
        (oraclePrice, priceTimestamp) = _fetchChainlinkOracleResponse(oracle.oracleAddress);

		if (oraclePrice != 0 && !_isStalePrice(priceTimestamp, oracle.timeoutSeconds)) {
			return _scalePriceByDigits(oraclePrice, oracle.decimals);
		}

		return 0;
	}

    // CHECK HOW LONG TIL LIQUITY ASSUMES STALE PRICE
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

	/**
	 * @dev Fetches the ETH:USD price (using the zero address as being the ETH asset), then multiplies it by the
	 *     indexed price. Assumes an oracle has been set for that purpose.
	 */
	function _calcEthIndexedPrice(uint256 _ethAmount) internal view returns (uint256) {
		uint256 ethPrice = fetchPrice(address(0));
		return (ethPrice * _ethAmount) / 1 ether;
	}

	/**
	 * @dev Scales oracle's response up/down to Gravita's target precision; returns unaltered price if already on
	 *     target digits.
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
}