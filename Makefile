include .env
export

clean:
	@forge clean

deploy-test:
	@forge script script/Deployer.s.sol --rpc-url $(TEST_NET_RPC_URL) \
	--private-key $(PRIVATE_KEY) \
	--broadcast -vvv

deploy-spp-test:
	@forge script script/SimplePaymentProcessorDeployer.s.sol --rpc-url $(TEST_NET_RPC_URL) \
	--private-key $(PRIVATE_KEY) --etherscan-api-key $(ETHERSCAN_API_KEY) \
	--verify --broadcast -vvv