// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./AddressBook.sol";
import "./interfaces/IVaultSorter.sol";
import "./interfaces/IVaultManager.sol";

import "forge-std/console.sol";

contract VaultSorter is IVaultSorter, AddressBook {
	
	// Information for a node in the list
	struct Node {
		bool exists;
		address nextId; // Id of next node (smaller ARS) in the list
		address prevId; // Id of previous node (larger ARS) in the list
	}

	// Information for the list
	struct Data {
		address head; // Head of the list. Also the node in the list with the largest ARS
		address tail; // Tail of the list. Also the node in the list with the smallest ARS
		uint256 size; // Current size of the list
		// Depositor address => node
		mapping(address => Node) nodes; // Track the corresponding ids for each node in the list
	}

	// Collateral type address => ordered list
	mapping(address => Data) public data;

	/*
	 * @dev Add a node to the list
	 * @param _id Node's id
	 * @param _ARS Node's ARS
	 * @param _prevId Id of previous node for the insert position
	 * @param _nextId Id of next node for the insert position
	 */

	function insertVault(
        address _asset,
        address _id,
        uint256 _ARS,
        address _prevId,
        address _nextId
    ) external override {
        _insert(_asset, _id, _ARS, _prevId, _nextId);
    }

	function _insert(address _asset, address _id, uint256 _ARS, address _prevId, address _nextId) internal {
		Data storage assetData = data[_asset];

		// List must not already contain node
		require(!_contains(assetData, _id), "SortedVessels: List already contains the node");
		// Node id must not be null
		require(_id != address(0), "SortedVessels: Id cannot be zero");
		// ARS must be non-zero
		require(_ARS != 0, "SortedVessels: ARS must be positive");

		address prevId = _prevId;
		address nextId = _nextId;

		if (!_validInsertPosition(_asset, _ARS, prevId, nextId)) {
			// Sender's hint was not a valid insert position
			// Use sender's hint to find a valid insert position
			(prevId, nextId) = _findInsertPosition(_asset, _ARS, prevId, nextId);
		}

		Node storage node = assetData.nodes[_id];
		node.exists = true;

		if (prevId == address(0) && nextId == address(0)) {
			// Insert as head and tail
			assetData.head = _id;
			assetData.tail = _id;
		} else if (prevId == address(0)) {
			// Insert before `prevId` as the head
			node.nextId = assetData.head;
			assetData.nodes[assetData.head].prevId = _id;
			assetData.head = _id;
		} else if (nextId == address(0)) {
			// Insert after `nextId` as the tail
			node.prevId = assetData.tail;
			assetData.nodes[assetData.tail].nextId = _id;
			assetData.tail = _id;
		} else {
			// Insert at insert position between `prevId` and `nextId`
			node.nextId = nextId;
			node.prevId = prevId;
			assetData.nodes[prevId].nextId = _id;
			assetData.nodes[nextId].prevId = _id;
		}

		assetData.size = assetData.size + 1;
		emit NodeAdded(_asset, _id, _ARS);
	}

	function removeVault(address _asset, address _id) external override {
        _remove(_asset, _id);
    }

	/*
	 * @dev Remove a node from the list
	 * @param _id Node's id
	 */
	function _remove(address _asset, address _id) internal {
		Data storage assetData = data[_asset];

		// List must contain the node
		require(_contains(assetData, _id), "SortedVessels: List does not contain the id");

		Node storage node = assetData.nodes[_id];
		if (assetData.size > 1) {
			// List contains more than a single node
			if (_id == assetData.head) {
				// The removed node is the head
				// Set head to next node
				assetData.head = node.nextId;
				// Set prev pointer of new head to null
				assetData.nodes[assetData.head].prevId = address(0);
			} else if (_id == assetData.tail) {
				// The removed node is the tail
				// Set tail to previous node
				assetData.tail = node.prevId;
				// Set next pointer of new tail to null
				assetData.nodes[assetData.tail].nextId = address(0);
			} else {
				// The removed node is neither the head nor the tail
				// Set next pointer of previous node to the next node
				assetData.nodes[node.prevId].nextId = node.nextId;
				// Set prev pointer of next node to the previous node
				assetData.nodes[node.nextId].prevId = node.prevId;
			}
		} else {
			// List contains a single node
			// Set the head and tail to null
			assetData.head = address(0);
			assetData.tail = address(0);
		}

		delete assetData.nodes[_id];
		assetData.size = assetData.size - 1;
		emit NodeRemoved(_asset, _id);
	}

	/*
	 * @dev Re-insert the node at a new position, based on its new ARS
	 * @param _id Node's id
	 * @param _newARS Node's new ARS
	 * @param _prevId Id of previous node for the new insert position
	 * @param _nextId Id of next node for the new insert position
	 */
	function reInsertVault(
        address _asset,
        address _id,
        uint256 _newARS,
        address _prevId,
        address _nextId
    ) external override {
		// List must contain the node
		require(contains(_asset, _id), "SortedVessels: List does not contain the id");
		// ARS must be non-zero
		require(_newARS != 0, "SortedVessels: ARS must be positive");

		// Remove node from the list
		_remove(_asset, _id);
		_insert(_asset, _id, _newARS, _prevId, _nextId);
	}

	/*
	 * @dev Check if a pair of nodes is a valid insertion point for a new node with the given ARS
	 * @param _ARS Node's ARS
	 * @param _prevId Id of previous node for the insert position
	 * @param _nextId Id of next node for the insert position
	 */
	function validInsertPosition(
		address _asset,
		uint256 _ARS,
		address _prevId,
		address _nextId
	) external returns (bool) {
		return _validInsertPosition(_asset, _ARS, _prevId, _nextId);
	}

	function _validInsertPosition(
		address _asset,
		uint256 _ARS,
		address _prevId,
		address _nextId
	) internal returns (bool) {

		if (_prevId == address(0) && _nextId == address(0)) {
			// `(null, null)` is a valid insert position if the list is empty
			return isEmpty(_asset);
		} else if (_prevId == address(0)) {
			// `(null, _nextId)` is a valid insert position if `_nextId` is the head of the list
			return data[_asset].head == _nextId && _ARS >= IVaultManager(vaultManager).calculateARS(_asset, _nextId);
		} else if (_nextId == address(0)) {
			// `(_prevId, null)` is a valid insert position if `_prevId` is the tail of the list
			return data[_asset].tail == _prevId && _ARS <= IVaultManager(vaultManager).calculateARS(_asset, _prevId);
		} else {
			// `(_prevId, _nextId)` is a valid insert position if they are adjacent nodes and `_ARS` falls between the two nodes' ARS
			return
				data[_asset].nodes[_prevId].nextId == _nextId &&
				IVaultManager(vaultManager).calculateARS(_asset, _prevId) >= _ARS &&
				_ARS >= IVaultManager(vaultManager).calculateARS(_asset, _nextId);
		}
	}

	/*
	 * @dev Descend the list (larger ARS to smaller ARS) to find a valid insert position
	 * @param _vesselManager VesselManager contract, passed in as param to save SLOAD’s
	 * @param _ARS Node's ARS
	 * @param _startId Id of node to start descending the list from
	 */
	function _descendList(address _asset, uint256 _ARS, address _startId) internal returns (address, address) {
		Data storage assetData = data[_asset];

		// If `_startId` is the head, check if the insert position is before the head
		if (assetData.head == _startId && _ARS >= IVaultManager(vaultManager).calculateARS(_asset, _startId)) {
			return (address(0), _startId);
		}

		address prevId = _startId;
		address nextId = assetData.nodes[prevId].nextId;

		// Descend the list until we reach the end or until we find a valid insert position
		while (prevId != address(0) && !_validInsertPosition(_asset, _ARS, prevId, nextId)) {
			prevId = assetData.nodes[prevId].nextId;
			nextId = assetData.nodes[prevId].nextId;
		}

		return (prevId, nextId);
	}

	/*
	 * @dev Ascend the list (smaller ARS to larger ARS) to find a valid insert position
	 * @param _vesselManager VesselManager contract, passed in as param to save SLOAD’s
	 * @param _ARS Node's ARS
	 * @param _startId Id of node to start ascending the list from
	 */
	function _ascendList(address _asset, uint256 _ARS, address _startId) internal returns (address, address) {
		Data storage assetData = data[_asset];

		// If `_startId` is the tail, check if the insert position is after the tail
		if (assetData.tail == _startId && _ARS <= IVaultManager(vaultManager).calculateARS(_asset, _startId)) {
			return (_startId, address(0));
		}

		address nextId = _startId;
		address prevId = assetData.nodes[nextId].prevId;

		// Ascend the list until we reach the end or until we find a valid insertion point
		while (nextId != address(0) && !_validInsertPosition(_asset, _ARS, prevId, nextId)) {
			nextId = assetData.nodes[nextId].prevId;
			prevId = assetData.nodes[nextId].prevId;
		}

		return (prevId, nextId);
	}

	/*
	 * @dev Find the insert position for a new node with the given ARS
	 * @param _ARS Node's ARS
	 * @param _prevId Id of previous node for the insert position
	 * @param _nextId Id of next node for the insert position
	 */
	function findInsertPosition(
		address _asset,
		uint256 _ARS,
		address _prevId,
		address _nextId
	) external returns (address, address) {
		return _findInsertPosition(_asset, _ARS, _prevId, _nextId);
	}

	function _findInsertPosition(
		address _asset,
		uint256 _ARS,
		address _prevId,
		address _nextId
	) internal returns (address, address) {
		address prevId = _prevId;
		address nextId = _nextId;

		if (prevId != address(0)) {
			if (!contains(_asset, prevId) || _ARS > IVaultManager(vaultManager).calculateARS(_asset, prevId)) {
				// `prevId` does not exist anymore or now has a smaller ARS than the given ARS
				prevId = address(0);
			}

		}

		if (nextId != address(0)) {
			if (!contains(_asset, nextId) || _ARS < IVaultManager(vaultManager).calculateARS(_asset, _nextId)) {
				// `nextId` does not exist anymore or now has a larger ARS than the given ARS
				nextId = address(0);
			}

		}

		if (prevId == address(0) && nextId == address(0)) {
			// No hint - descend list starting from head
			return _descendList(_asset, _ARS, data[_asset].head);
		} else if (prevId == address(0)) {
			// No `prevId` for hint - ascend list starting from `nextId`
			return _ascendList(_asset, _ARS, nextId);
		} else if (nextId == address(0)) {
			// No `nextId` for hint - descend list starting from `prevId`
			return _descendList(_asset, _ARS, prevId);
		} else {
			// Descend list starting from `prevId`
			return _descendList(_asset, _ARS, prevId);
		}
	}

	/*
	 * @dev Checks if the list contains a node
	 */
	function contains(address _asset, address _id) public view returns (bool) {
		return data[_asset].nodes[_id].exists;
	}

	function _contains(Data storage _dataAsset, address _id) internal view returns (bool) {
		return _dataAsset.nodes[_id].exists;
	}

	/*
	 * @dev Checks if the list is empty
	 */
	function isEmpty(address _asset) public view returns (bool) {
		return data[_asset].size == 0;
	}

	/*
	 * @dev Returns the current size of the list
	 */
	function getSize(address _asset) external view returns (uint256) {
		return data[_asset].size;
	}

	/*
	 * @dev Returns the first node in the list (node with the largest ARS)
	 */
	function getFirst(address _asset) external view returns (address) {
		return data[_asset].head;
	}

	/*
	 * @dev Returns the last node in the list (node with the smallest ARS)
	 */
	function getLast(address _asset) external view returns (address) {
		return data[_asset].tail;
	}

	/*
	 * @dev Returns the next node (with a smaller ARS) in the list for a given node
	 * @param _id Node's id
	 */
	function getNext(address _asset, address _id) external view returns (address) {
		return data[_asset].nodes[_id].nextId;
	}

	/*
	 * @dev Returns the previous node (with a larger ARS) in the list for a given node
	 * @param _id Node's id
	 */
	function getPrev(address _asset, address _id) external view returns (address) {
		return data[_asset].nodes[_id].prevId;
	}
}