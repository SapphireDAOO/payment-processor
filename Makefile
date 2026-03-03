include .env
export

.PHONY: help build test format clean deploy-local deploy-test deploy-mainnet

help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "Targets:"
	@echo "  build           Compile contracts"
	@echo "  test            Run tests"
	@echo "  format          Format Solidity source files"
	@echo "  clean           Remove build artifacts"
	@echo "  deploy-local    Deploy to local Anvil node"
	@echo "  deploy-test     Deploy to testnet sepolia and verify"
	@echo "  deploy-mainnet  Deploy to mainnet and verify"

build:
	@forge build

test:
	@forge test -vvv

format:
	@forge fmt

clean:
	@forge clean

deploy-local:
	@forge script script/Deployer.s.sol --rpc-url anvil \
	--private-key $(PRIVATE_KEY) --broadcast -vvv

deploy-test:
	@forge script script/Deployer.s.sol --rpc-url $(TEST_NET_RPC_URL) \
	--private-key $(PRIVATE_KEY) --etherscan-api-key $(ETHERSCAN_API_KEY) \
	--verify --broadcast -vvv

deploy-mainnet:
	@forge script script/Deployer.s.sol --rpc-url $(MAINNET_RPC_URL) \
	--private-key $(PRIVATE_KEY) --etherscan-api-key $(ETHERSCAN_API_KEY) \
	--verify --broadcast -vvv
