// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {INFTMetadataGenerator} from "@core/interfaces/INFTMetadataGenerator.sol";
import {MortgagePosition} from "@core/types/MortgagePosition.sol";

/**
 * @title MockNFTMetadataGenerator
 * @author SocksNFlops
 * @notice A mock implementation of the NFT Metadata Generator contract for simple testing
 */
contract MockNFTMetadataGenerator is INFTMetadataGenerator {
  string public metadata;

  function setMetadata(string memory metadata_) external {
    metadata = metadata_;
  }

  /**
   * @inheritdoc INFTMetadataGenerator
   */
  function generateMetadata(MortgagePosition memory) external view override returns (string memory) {
    return metadata;
  }
}
