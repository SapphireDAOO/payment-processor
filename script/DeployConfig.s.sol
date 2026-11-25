// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { IPaymentProcessorStorage } from "../src/interface/IPaymentProcessorStorage.sol";
import { PaymentProcessorStorage } from "../src/PaymentProcessorStorage.sol";
import { MultiSig } from "../src/MultiSig.sol";
import { Sweeper } from "../src/Sweeper.sol";
import { MockUsdc, MockWbtc } from "../test/mock/mERC20.sol";
import { MockV3Aggregator } from "../test/mock/MockV3Aggregator.sol";
import { MockWeth } from "../test/mock/MockWeth.sol";

/// @notice Tokens and Chainlink feeds for the current network.
struct Addr {
    address usdcPriceFeed;
    address wbtcPriceFeed;
    address nativeTokenPriceFeed;
    address sequencerUptimeFeed;
    address usdc;
    address wbtc;
    address weth;
}

/// @notice The contracts both processors share.
struct Core {
    MultiSig multiSig;
    PaymentProcessorStorage ppStorage;
    Sweeper sweeper;
}

/**
 * @title DeployConfig
 * @notice Constants, network setup, the shared core deployment and CREATE2 helpers used by both deploy scripts.
 * @dev Every contract goes through the deterministic CREATE2 factory and is reused when already deployed, so a
 *      run that failed partway resumes on the same addresses.
 */
abstract contract DeployConfig is Script {
    uint96 constant FEE_RATE = 500;
    uint32 constant TESTNET_ESCROW_HOLD_PERIOD = 5 minutes;
    uint32 constant MAINNET_ESCROW_HOLD_PERIOD = 30 days;

    // Base mainnet tokens
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WBTC = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;

    /// @dev Canonical wrapped-native predeploy on Base mainnet and Base Sepolia.
    address constant WETH = 0x4200000000000000000000000000000000000006;

    /// @dev Mock tokens already live on Base Sepolia, reused so the testnet never accumulates another pair.
    address constant TESTNET_MOCK_USDC = 0x9652aF270a39E8F63Fa801F6293DEb944FdEB5B9;
    address constant TESTNET_MOCK_WBTC = 0xc3a9d881A859EC02433eb0b6FaDC79F5678627b9;

    // Base mainnet Chainlink price feeds
    address constant USDC_USD_PRICE_FEED = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
    address constant WBTC_USD_PRICE_FEED = 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F;
    address constant NATIVE_TOKEN_USD_PRICE_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant MAINNET_SEQUENCER_UPTIME_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

    // Base Sepolia Chainlink price feeds
    address constant TESTNET_USDC_PRICE_FEED = 0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165;
    address constant TESTNET_WBTC_PRICE_FEED = 0x0FB99723Aee6f420beAD13e6bBB79b7E6F034298;
    address constant TESTNET_NATIVE_TOKEN_PRICE_FEED = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;

    // Mock feed answers (8 decimals) for local Anvil.
    uint8 constant MOCK_FEED_DECIMALS = 8;
    int256 constant MOCK_USDC_PRICE = 1e8;
    int256 constant MOCK_WBTC_PRICE = 90_000e8;
    int256 constant MOCK_NATIVE_TOKEN_PRICE = 1960e8;

    uint96 constant FEED_HEARTBEAT = 24 hours;

    uint256 constant TESTNET_CHAIN_ID = 84532;
    uint256 constant MAINNET_CHAIN_ID = 8453;
    uint256 constant LOCAL_CHAIN_ID = 31337;

    uint256 constant INITIAL_THRESHOLD = 2;

    /// @dev Key whose signature authorizes the per-invoice fee receiver. Override with FEE_SIGNER.
    address constant DEFAULT_FEE_SIGNER = 0x06124927895eF15c6f436988E47C73a80c220c3b;

    /// @dev address(0) leaves PaymentAutomation's `onReport` unreachable; set CRE_FORWARDER and CRE_WORKFLOW_OWNER.
    address constant DEFAULT_CRE_FORWARDER = address(0);
    address constant DEFAULT_CRE_WORKFLOW_OWNER = address(0);

    address constant SIGNER_ONE = 0x60D7dD3b4248D53Abba8DA999B22023656A2E4B3;
    address constant SIGNER_TWO = 0x0f447989b14A3f0bbf08808020Ec1a6DE0b8cbC4;
    address[] signers = [SIGNER_ONE, SIGNER_TWO];

    /// @dev Bump the version (or set CREATE2_SALT) to redeploy at fresh addresses.
    bytes32 constant DEFAULT_SALT = keccak256("sapphiredao.payment-processor.deploy.testnet");

    function _deploySalt() internal view returns (bytes32 salt) {
        salt = vm.envOr("CREATE2_SALT", DEFAULT_SALT);
    }

    function _logHeader(string memory _title, bytes32 _salt) internal view {
        console.log(string.concat("=== SapphireDAO ", _title, " ==="));
        console.log("Network:  ", _networkName());
        console.log("Chain ID: ", block.chainid);
        console.log("Deployer: ", msg.sender);
        console.log("CREATE2 salt:");
        console.logBytes32(_salt);
        console.log("");
    }

    /**
     * @notice Deploys `_initCode` through the CREATE2 factory, or returns the contract already there.
     * @param _name Label for the log line.
     * @return deployed The contract's address.
     */
    function _create2(string memory _name, bytes32 _salt, bytes memory _initCode) internal returns (address deployed) {
        deployed = vm.computeCreate2Address(_salt, keccak256(_initCode));
        if (deployed.code.length != 0) {
            console.log(string.concat(_name, " (existing):"), deployed);
            return deployed;
        }

        (bool ok,) = CREATE2_FACTORY.call(abi.encodePacked(_salt, _initCode));
        require(ok && deployed.code.length != 0, string.concat(_name, " deployment failed"));
        console.log(string.concat(_name, " deployed:"), deployed);
    }

    /// @notice Storage configuration; the deployer owns it until ownership moves to the MultiSig.
    function _storageConfig(address _weth) internal view returns (IPaymentProcessorStorage.Configuration memory) {
        return IPaymentProcessorStorage.Configuration({
            owner: msg.sender, feeReceiver: msg.sender, intermediatedPlatformsOperator: msg.sender, weth: _weth
        });
    }

    /// @notice Deploys the MultiSig, PaymentProcessorStorage and Sweeper unless already there, and sets the fee signer.
    function _deployCore(bytes32 _salt, address _weth) internal returns (Core memory core) {
        console.log("--- Core ---");

        core.multiSig = MultiSig(_create2("MultiSig", _salt, _multiSigInitCode()));
        core.ppStorage = PaymentProcessorStorage(_create2("PaymentProcessorStorage", _salt, _storageInitCode(_weth)));
        core.sweeper = Sweeper(_create2("Sweeper", _salt, _sweeperInitCode(address(core.ppStorage))));

        // Without a fee signer every acceptPayment and payInvoice reverts with InvalidFeeAuthorization.
        address feeSigner = vm.envOr("FEE_SIGNER", DEFAULT_FEE_SIGNER);
        if (core.ppStorage.owner() != msg.sender) {
            console.log("Fee signer left as set by the owner:", core.ppStorage.getFeeSigner());
        } else if (core.ppStorage.getFeeSigner() != feeSigner) {
            core.ppStorage.setFeeSigner(feeSigner);
            console.log("Fee signer set:", feeSigner);
        }
        console.log("");
    }

    /// @notice The core {DeployIntermediated} put at this salt; reverts if it is not deployed yet.
    function _existingCore(bytes32 _salt, address _weth) internal view returns (Core memory core) {
        core.ppStorage = PaymentProcessorStorage(vm.computeCreate2Address(_salt, keccak256(_storageInitCode(_weth))));
        require(address(core.ppStorage).code.length != 0, "Core not deployed; run DeployIntermediated first");

        core.multiSig = MultiSig(vm.computeCreate2Address(_salt, keccak256(_multiSigInitCode())));
        core.sweeper = Sweeper(vm.computeCreate2Address(_salt, keccak256(_sweeperInitCode(address(core.ppStorage)))));

        console.log("--- Core ---");
        console.log("PaymentProcessorStorage (existing):", address(core.ppStorage));
        console.log("");
    }

    function _multiSigInitCode() private view returns (bytes memory) {
        return abi.encodePacked(type(MultiSig).creationCode, abi.encode(signers, INITIAL_THRESHOLD));
    }

    function _storageInitCode(address _weth) private view returns (bytes memory) {
        return abi.encodePacked(type(PaymentProcessorStorage).creationCode, abi.encode(_storageConfig(_weth)));
    }

    function _sweeperInitCode(address _ppStorage) private pure returns (bytes memory) {
        return abi.encodePacked(type(Sweeper).creationCode, abi.encode(_ppStorage));
    }

    /// @notice Hands storage ownership to the MultiSig when HANDOVER=true; set it on the last script you run.
    function _handover(Core memory _core) internal {
        if (!vm.envOr("HANDOVER", false)) {
            console.log("Storage owner (set HANDOVER=true to transfer):", _core.ppStorage.owner());
            return;
        }

        if (_core.ppStorage.owner() == msg.sender) _core.ppStorage.transferOwnership(address(_core.multiSig));
        console.log("Storage owner:", _core.ppStorage.owner());
    }

    /**
     * @notice The OracleManager to reuse, read from ORACLE_MANAGER; address(0) deploys a new one.
     * @dev A set address must hold code, so a typo cannot leave the processor pricing against an empty account.
     */
    function _existingOracleManager() internal view returns (address oracleManager) {
        oracleManager = vm.envOr("ORACLE_MANAGER", address(0));
        require(oracleManager == address(0) || oracleManager.code.length != 0, "ORACLE_MANAGER has no code");
    }

    /// @notice 30 days on Base mainnet, 5 minutes everywhere else.
    function _escrowHoldPeriod() internal view returns (uint32 holdPeriod) {
        holdPeriod = block.chainid == MAINNET_CHAIN_ID ? MAINNET_ESCROW_HOLD_PERIOD : TESTNET_ESCROW_HOLD_PERIOD;
    }

    function _networkName() internal view returns (string memory) {
        if (block.chainid == MAINNET_CHAIN_ID) return "Base Mainnet";
        if (block.chainid == LOCAL_CHAIN_ID) return "Localhost (Anvil)";
        return "Base Sepolia";
    }

    /// @notice Tokens and feeds for the current network, deploying mocks where the network has none.
    function _network(bytes32 _salt) internal returns (Addr memory) {
        if (block.chainid == MAINNET_CHAIN_ID) {
            return Addr({
                usdcPriceFeed: USDC_USD_PRICE_FEED,
                wbtcPriceFeed: WBTC_USD_PRICE_FEED,
                nativeTokenPriceFeed: NATIVE_TOKEN_USD_PRICE_FEED,
                sequencerUptimeFeed: MAINNET_SEQUENCER_UPTIME_FEED,
                usdc: USDC,
                wbtc: WBTC,
                weth: WETH
            });
        }

        if (block.chainid == TESTNET_CHAIN_ID) {
            return Addr({
                usdcPriceFeed: TESTNET_USDC_PRICE_FEED,
                wbtcPriceFeed: TESTNET_WBTC_PRICE_FEED,
                nativeTokenPriceFeed: TESTNET_NATIVE_TOKEN_PRICE_FEED,
                sequencerUptimeFeed: address(0),
                usdc: TESTNET_MOCK_USDC,
                wbtc: TESTNET_MOCK_WBTC,
                weth: WETH
            });
        }

        address usdc = _mockToken("MockUsdc", _salt, type(MockUsdc).creationCode, "Mock Usdc", "mUsdc");
        address wbtc = _mockToken("MockWbtc", _salt, type(MockWbtc).creationCode, "Mock WBtc", "mWBtc");

        if (block.chainid == LOCAL_CHAIN_ID) {
            return Addr({
                usdcPriceFeed: _mockFeed("Mock USDC feed", _salt, MOCK_USDC_PRICE),
                wbtcPriceFeed: _mockFeed("Mock WBTC feed", _salt, MOCK_WBTC_PRICE),
                nativeTokenPriceFeed: _mockFeed("Mock ETH feed", _salt, MOCK_NATIVE_TOKEN_PRICE),
                sequencerUptimeFeed: address(0),
                usdc: usdc,
                wbtc: wbtc,
                weth: _create2("MockWeth", _salt, type(MockWeth).creationCode)
            });
        }

        return Addr({
            usdcPriceFeed: TESTNET_USDC_PRICE_FEED,
            wbtcPriceFeed: TESTNET_WBTC_PRICE_FEED,
            nativeTokenPriceFeed: TESTNET_NATIVE_TOKEN_PRICE_FEED,
            sequencerUptimeFeed: address(0),
            usdc: usdc,
            wbtc: wbtc,
            weth: WETH
        });
    }

    /// @dev The constructor mints to the CREATE2 factory, so a fresh token also mints to the deployer.
    function _mockToken(
        string memory _label,
        bytes32 _salt,
        bytes memory _creationCode,
        string memory _name,
        string memory _symbol
    ) private returns (address token) {
        bytes memory initCode = abi.encodePacked(_creationCode, abi.encode(_name, _symbol));
        bool isNew = vm.computeCreate2Address(_salt, keccak256(initCode)).code.length == 0;

        token = _create2(_label, _salt, initCode);
        if (isNew) MockUsdc(token).mint(msg.sender, MockUsdc(token).INITIAL_SUPPLY());
    }

    function _mockFeed(string memory _label, bytes32 _salt, int256 _answer) private returns (address feed) {
        feed = _create2(
            _label,
            _salt,
            abi.encodePacked(type(MockV3Aggregator).creationCode, abi.encode(MOCK_FEED_DECIMALS, _answer))
        );
    }
}
