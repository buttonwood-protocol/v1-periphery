#!/bin/bash

# Load environment variables
set -a
source .env
set +a

# Wait 10 seconds before running
sleep 10

# packages/contracts/utils/local-deploy.sh should already be running an anvil instance

# Find the address of the general manager contract
GENERAL_MANAGER_ADDRESS=$(jq -r '.generalManagerAddress' ../contracts/addresses/addresses-31337.json)
export GENERAL_MANAGER_ADDRESS
echo "General manager address: $GENERAL_MANAGER_ADDRESS"

# Find the address of the Pyth contract
PYTH_ADDRESS=$(jq -r '.pythAddress' ../contracts/addresses/addresses-31337.json)
export PYTH_ADDRESS
echo "Pyth address: $PYTH_ADDRESS"

# Fetch the address of the wrapped native token contract from environment variable
echo "Wrapped native token address: $WRAPPED_NATIVE_TOKEN_ADDRESS"


# Deploy the contracts using forge
echo "Deploying contracts"
forge script script/DeployRouter.s.sol --rpc-url http://localhost:8545 --broadcast --slow
