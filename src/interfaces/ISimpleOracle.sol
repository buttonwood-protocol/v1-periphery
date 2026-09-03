// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/**
 * @title ISimpleOracle
 * @author @SocksNFlops
 * @notice Interface for the SimpleOracle contract, which stores signer-attested prices pushed by callers.
 * @dev Local mirror of the core repo's `interfaces/ISimpleOracle.sol`; remove once `lib/cash` ships it.
 */
interface ISimpleOracle {
  /**
   * @notice A single signed price update
   * @param id The feed identifier
   * @param price The price, scaled to `decimals()`
   * @param timestamp The time the price was observed
   */
  struct PriceUpdate {
    bytes32 id;
    int256 price;
    uint256 timestamp;
  }

  /**
   * @notice The number of decimals every stored price is scaled to
   * @return The number of decimals
   */
  function decimals() external view returns (uint8);

  /**
   * @notice The address whose signatures are accepted for price updates
   * @return The signer address
   */
  function signer() external view returns (address);

  /**
   * @notice Returns the latest stored price for a feed
   * @param id The feed identifier
   * @return answer The latest price
   * @return updatedAt The timestamp of the latest price
   */
  function latestRoundData(bytes32 id) external view returns (int256 answer, uint256 updatedAt);

  /**
   * @notice Stores a single signed price update
   * @param id The feed identifier
   * @param price The price, scaled to `decimals()`
   * @param timestamp The time the price was observed
   * @param signature The signer's signature over the update
   */
  function updatePrice(bytes32 id, int256 price, uint256 timestamp, bytes calldata signature) external;

  /**
   * @notice Stores a batch of signed price updates
   * @param updates Each entry is `abi.encode(bytes32 id, int256 price, uint256 timestamp, bytes signature)`
   */
  function updatePrices(bytes[] calldata updates) external;
}
