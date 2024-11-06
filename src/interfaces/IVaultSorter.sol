// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IVaultSorter {
	// --- Events ---

	event NodeAdded(address indexed _asset, address _id, uint256 _NICR);
	event NodeRemoved(address indexed _asset, address _id);

	// --- Functions ---

	function insertVault(
        address _asset,
        address _id,
        uint256 _NICR,
        address _prevId,
        address _nextId
    ) external;

    function removeVault(address _asset, address _id) external;

    function reInsertVault(
        address _asset,
        address _id,
        uint256 _newNICR,
        address _prevId,
        address _nextId
    ) external;

	function contains(address _asset, address _id) external view returns (bool);

	function isEmpty(address _asset) external view returns (bool);

	function getSize(address _asset) external view returns (uint256);

	function getFirst(address _asset) external view returns (address);

	function getLast(address _asset) external view returns (address);

	function getNext(address _asset, address _id) external view returns (address);

	function getPrev(address _asset, address _id) external view returns (address);

	function validInsertPosition(
		address _asset,
		uint256 _ICR,
		address _prevId,
		address _nextId
	) external returns (bool);

	function findInsertPosition(
		address _asset,
		uint256 _ICR,
		address _prevId,
		address _nextId
	) external returns (address, address);
}