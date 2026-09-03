// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ICopyOracle} from "../../src/interfaces/ICopyOracle.sol";

contract MockCopyOracle is ICopyOracle {
  /// @dev Thrown by every update call while `shouldRevert` is set
  error MockCopyOracleRejected();

  /// @inheritdoc ICopyOracle
  address public immutable signer;
  /// @dev When set, every update call reverts
  bool public shouldRevert;
  /// @dev Every update received, in call order
  PriceUpdate[] public updates;
  /// @dev Latest price per feed
  mapping(bytes32 => PriceUpdate) internal latest;

  constructor(address _signer) {
    signer = _signer;
  }

  /// @dev Toggle whether update calls revert
  function setShouldRevert(bool _shouldRevert) external {
    shouldRevert = _shouldRevert;
  }

  /// @dev The number of updates received so far
  function updateCount() external view returns (uint256) {
    return updates.length;
  }

  /// @inheritdoc ICopyOracle
  function decimals() external pure returns (uint8) {
    return 8;
  }

  /// @inheritdoc ICopyOracle
  function latestRoundData(bytes32 id) external view returns (int256 answer, uint256 updatedAt) {
    PriceUpdate storage update = latest[id];
    return (update.price, update.timestamp);
  }

  /// @inheritdoc ICopyOracle
  function updatePrice(bytes32 id, int256 price, uint256 timestamp, bytes calldata) external {
    _record(id, price, timestamp);
  }

  /// @inheritdoc ICopyOracle
  function updatePrices(bytes[] calldata _updates) external {
    for (uint256 i = 0; i < _updates.length; i++) {
      (bytes32 id, int256 price, uint256 timestamp,) = abi.decode(_updates[i], (bytes32, int256, uint256, bytes));
      _record(id, price, timestamp);
    }
  }

  function _record(bytes32 id, int256 price, uint256 timestamp) internal {
    if (shouldRevert) {
      revert MockCopyOracleRejected();
    }
    PriceUpdate memory update = PriceUpdate({id: id, price: price, timestamp: timestamp});
    updates.push(update);
    latest[id] = update;
  }
}
