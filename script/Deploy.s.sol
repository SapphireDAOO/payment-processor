// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { IPaymentProcessorStorage, PaymentProcessorStorage } from "../src/PaymentProcessorStorage.sol";
import { MasterDeployer } from "../src/MasterDeployer.sol";
import { IMasterDeployer } from "../src/interface/IMasterDeployer.sol";
import { SimplePaymentProcessor } from "../src/SimplePaymentProcessor.sol";
import { PaymentAutomation } from "../src/PaymentAutomation.sol";
import { IntermediatedPaymentProcessor } from "../src/IntermediatedPaymentProcessor.sol";
import { MultiSig } from "../src/MultiSig.sol";
import { OracleManager } from "../src/OracleManager.sol";
import { IOracleManager } from "../src/interface/IOracleManager.sol";
import { MockUsdc, MockWbtc } from "../test/mock/mERC20.sol";
import { MockV3Aggregator } from "../test/mock/MockV3Aggregator.sol";
import { Notes } from "../src/Notes.sol";

struct Addr {
    address usdcPriceFeed;
    address wbtcPriceFeed;
    address nativeTokenPriceFeed;
    address sequencerUptimeFeed;
    address usdc;
    address wbtc;
}

contract Deploy is Script {
    MockUsdc mockUsdc;
    MockWbtc mockWBtc;

    uint96 constant FEE_RATE = 500;
    uint96 constant DEFAULT_HOLD_PERIOD = 10 minutes;
    uint256 constant MINIMUM_INVOICE_VALUE = 0.005 ether;
    uint96 constant DEFAULT_GAS_THRESHOLD = 100_000;

    // Base mainnet tokens
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WBTC = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;

    // Base mainnet Chainlink price feeds
    address constant USDC_USD_PRICE_FEED = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
    address constant WBTC_USD_PRICE_FEED = 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F;
    address constant NATIVE_TOKEN_USD_PRICE_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant MAINNET_SEQUENCER_UPTIME_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

    // Base Sepolia testnet Chainlink price feeds
    address constant TESTNET_USDC_PRICE_FEED = 0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165;
    address constant TESTNET_WBTC_PRICE_FEED = 0x0FB99723Aee6f420beAD13e6bBB79b7E6F034298;
    address constant TESTNET_NATIVE_TOKEN_PRICE_FEED = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;

    // Mock price feed answers (8 decimals) used for local Anvil deployments.
    uint8 constant MOCK_FEED_DECIMALS = 8;
    int256 constant MOCK_USDC_PRICE = 1e8;
    int256 constant MOCK_WBTC_PRICE = 90_000e8;
    int256 constant MOCK_NATIVE_TOKEN_PRICE = 1960e8;

    uint96 constant FEED_HEARTBEAT = 24 hours;

    uint256 constant TESTNET_CHAIN_ID = 84532;
    uint256 constant MAINNET_CHAIN_ID = 8453;
    uint256 constant LOCAL_CHAIN_ID = 31337;

    uint256 constant INITIAL_THRESHOLD = 2;

    address constant SIGNER_ONE = 0x60D7dD3b4248D53Abba8DA999B22023656A2E4B3;
    address constant SIGNER_TWO = 0x0f447989b14A3f0bbf08808020Ec1a6DE0b8cbC4;
    address[] signers = [SIGNER_ONE, SIGNER_TWO];

    // Default CREATE2 salt; bump the version (or set CREATE2_SALT) to redeploy at fresh addresses.
    bytes32 constant DEFAULT_SALT = keccak256("sapphiredao.payment-processor");

    function run() external {
        bool isMainnet = block.chainid == MAINNET_CHAIN_ID;
        bytes32 salt = vm.envOr("CREATE2_SALT", DEFAULT_SALT);

        console.log("=== SapphireDAO Payment Processor Deployment ===");
        console.log("Network:  ", _networkName());
        console.log("Chain ID: ", block.chainid);
        console.log("Deployer: ", msg.sender);
        console.log("");
        console.log("--- Config ---");
        console.log("Fee rate (bps):      ", FEE_RATE);
        console.log("Hold period (s):     ", DEFAULT_HOLD_PERIOD);
        console.log("Min invoice (wei):   ", MINIMUM_INVOICE_VALUE);
        console.log("Gas threshold:       ", DEFAULT_GAS_THRESHOLD);
        console.log("MultiSig threshold:  ", INITIAL_THRESHOLD);
        console.log("Signer[0]:           ", SIGNER_ONE);
        console.log("Signer[1]:           ", SIGNER_TWO);
        console.log("CREATE2 salt:");
        console.logBytes32(salt);
        console.log("");
        console.log("--- Deploying ---");

        vm.startBroadcast();

        MasterDeployer masterDeployer = new MasterDeployer{ salt: salt }(msg.sender);
        console.log("MasterDeployer deployed:          ", address(masterDeployer));

        Addr memory addr = _setUp(salt);
        if (!isMainnet) {
            console.log("MockUsdc deployed:                ", addr.usdc);
            console.log("MockWbtc deployed:                ", addr.wbtc);
        }

        // Owned by the deployer for post-deploy wiring; ownership moves to the MultiSig below.
        IMasterDeployer.Params memory params = IMasterDeployer.Params({
            salt: salt,
            config: IPaymentProcessorStorage.Configuration({
                owner: msg.sender,
                feeReceiver: msg.sender,
                intermediatedPlatformsOperator: msg.sender,
                feeRate: FEE_RATE,
                gasThreshold: DEFAULT_GAS_THRESHOLD
            }),
            minimumInvoiceValue: MINIMUM_INVOICE_VALUE,
            sequencerUptimeFeed: addr.sequencerUptimeFeed,
            multiSigSigners: signers,
            multiSigThreshold: INITIAL_THRESHOLD
        });

        // Creation code is passed in rather than embedded so MasterDeployer stays under the
        // EIP-170 size limit.
        IMasterDeployer.InitCodes memory initCodes = IMasterDeployer.InitCodes({
            multiSig: type(MultiSig).creationCode,
            notes: type(Notes).creationCode,
            simplePaymentProcessor: type(SimplePaymentProcessor).creationCode,
            paymentAutomation: type(PaymentAutomation).creationCode,
            oracleManager: type(OracleManager).creationCode,
            intermediatedPaymentProcessor: type(IntermediatedPaymentProcessor).creationCode,
            ppStorage: type(PaymentProcessorStorage).creationCode
        });

        address predictedStorage = masterDeployer.predictStorageAddress(salt, params.config, initCodes.ppStorage);
        console.log("Predicted PaymentProcessorStorage:", predictedStorage);

        masterDeployer.deployAll(params, initCodes);

        _wire(masterDeployer, addr, isMainnet);

        vm.stopBroadcast();

        _report(masterDeployer, addr, isMainnet);
    }

    /// @dev Post-deploy wiring: notes authorization, the automation adapter, price feeds, and the
    ///      ownership handover to the MultiSig. Split out of `run` to keep its stack frame in bounds.
    function _wire(MasterDeployer _masterDeployer, Addr memory _addr, bool _isMainnet) internal {
        address multisig = address(_masterDeployer.multiSig());
        address simplePP = address(_masterDeployer.simplePaymentProcessor());
        address automation = address(_masterDeployer.paymentAutomation());
        address intermediatedPP = address(_masterDeployer.intermediatedPaymentProcessor());
        Notes notes = _masterDeployer.notes();

        console.log("MultiSig deployed:                ", multisig);
        console.log("PaymentProcessorStorage deployed: ", address(_masterDeployer.ppStorage()));
        console.log("Notes deployed:                   ", address(notes));
        console.log("SimplePaymentProcessor deployed:  ", simplePP);
        console.log("PaymentAutomation deployed:       ", automation);
        console.log("OracleManager deployed:           ", address(_masterDeployer.oracleManager()));
        console.log("IntermediatedPaymentProcessor deployed:", intermediatedPP);

        console.log("");
        console.log("--- Wiring ---");

        notes.setAuthorized(msg.sender, true);
        notes.setAuthorized(simplePP, true);
        notes.setAuthorized(intermediatedPP, true);
        console.log("Notes authorized: deployer, SimplePaymentProcessor, IntermediatedPaymentProcessor");
        console.log("Storage authorized at construction: SimplePaymentProcessor, IntermediatedPaymentProcessor");

        // The keeper entrypoints live on PaymentAutomation; the processor only trusts its address.
        // The CRE forwarder and workflow owner are still set on PaymentAutomation post-deploy.
        SimplePaymentProcessor(simplePP).setAutomation(automation);
        console.log("SimplePaymentProcessor automation set:", automation);

        _setPriceFeeds(_masterDeployer.oracleManager(), _addr, _isMainnet);

        _masterDeployer.ppStorage().transferOwnership(multisig);
        console.log("Ownership transferred to MultiSig:", multisig);
    }

    /// @dev Prints the final address summary once broadcasting has stopped.
    function _report(MasterDeployer _masterDeployer, Addr memory _addr, bool _isMainnet) internal view {
        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("MasterDeployer:          ", address(_masterDeployer));
        console.log("MultiSig:                ", address(_masterDeployer.multiSig()));
        console.log("PaymentProcessorStorage: ", address(_masterDeployer.ppStorage()));
        console.log("Notes:                   ", address(_masterDeployer.notes()));
        console.log("SimplePaymentProcessor:  ", address(_masterDeployer.simplePaymentProcessor()));
        console.log("PaymentAutomation:       ", address(_masterDeployer.paymentAutomation()));
        console.log("OracleManager:           ", address(_masterDeployer.oracleManager()));
        console.log("IntermediatedPaymentProcessor:", address(_masterDeployer.intermediatedPaymentProcessor()));
        if (!_isMainnet) {
            console.log("MockUsdc:                ", _addr.usdc);
            console.log("MockWbtc:                ", _addr.wbtc);
        }
    }

    /// @dev Registers the ETH, USDC and WBTC price feeds on the oracle manager. Mock feeds (non-mainnet)
    ///      report a static timestamp, so the staleness check is disabled there with heartbeat 0.
    function _setPriceFeeds(OracleManager _oracle, Addr memory _addr, bool _isMainnet) internal {
        uint96 heartbeat = _isMainnet ? FEED_HEARTBEAT : 0;

        _oracle.setPriceFeed(
            address(0), IOracleManager.PriceFeedConfig({ aggregator: _addr.nativeTokenPriceFeed, heartbeat: heartbeat })
        );
        _oracle.setPriceFeed(
            _addr.usdc, IOracleManager.PriceFeedConfig({ aggregator: _addr.usdcPriceFeed, heartbeat: heartbeat })
        );
        _oracle.setPriceFeed(
            _addr.wbtc, IOracleManager.PriceFeedConfig({ aggregator: _addr.wbtcPriceFeed, heartbeat: heartbeat })
        );
        console.log("Price feeds set: ETH/USD, USDC/USD, WBTC/USD");
    }

    function _setUp(bytes32 _salt) internal returns (Addr memory) {
        if (block.chainid == MAINNET_CHAIN_ID) {
            return Addr({
                usdcPriceFeed: USDC_USD_PRICE_FEED,
                wbtcPriceFeed: WBTC_USD_PRICE_FEED,
                nativeTokenPriceFeed: NATIVE_TOKEN_USD_PRICE_FEED,
                sequencerUptimeFeed: MAINNET_SEQUENCER_UPTIME_FEED,
                usdc: USDC,
                wbtc: WBTC
            });
        }

        mockUsdc = new MockUsdc{ salt: _salt }("Mock Usdc", "mUsdc");
        mockWBtc = new MockWbtc{ salt: _salt }("Mock WBtc", "mWBtc");

        // Under CREATE2 the constructor mints the initial supply to the factory, so mint to the deployer here.
        mockUsdc.mint(msg.sender, mockUsdc.INITIAL_SUPPLY());
        mockWBtc.mint(msg.sender, mockWBtc.INITIAL_SUPPLY());

        // Local Anvil has no Chainlink feeds, so deploy mock aggregators with fixed answers.
        if (block.chainid == LOCAL_CHAIN_ID) {
            address usdcFeed = address(new MockV3Aggregator{ salt: _salt }(MOCK_FEED_DECIMALS, MOCK_USDC_PRICE));
            address wbtcFeed = address(new MockV3Aggregator{ salt: _salt }(MOCK_FEED_DECIMALS, MOCK_WBTC_PRICE));
            address nativeFeed =
                address(new MockV3Aggregator{ salt: _salt }(MOCK_FEED_DECIMALS, MOCK_NATIVE_TOKEN_PRICE));

            return Addr({
                usdcPriceFeed: usdcFeed,
                wbtcPriceFeed: wbtcFeed,
                nativeTokenPriceFeed: nativeFeed,
                // No L2 sequencer locally; address(0) makes OracleManager skip the uptime check.
                sequencerUptimeFeed: address(0),
                usdc: address(mockUsdc),
                wbtc: address(mockWBtc)
            });
        }

        return Addr({
            usdcPriceFeed: TESTNET_USDC_PRICE_FEED,
            wbtcPriceFeed: TESTNET_WBTC_PRICE_FEED,
            nativeTokenPriceFeed: TESTNET_NATIVE_TOKEN_PRICE_FEED,
            sequencerUptimeFeed: address(0),
            usdc: address(mockUsdc),
            wbtc: address(mockWBtc)
        });
    }

    /// @notice Human-readable network label for the current chain id.
    function _networkName() internal view returns (string memory) {
        if (block.chainid == MAINNET_CHAIN_ID) return "Base Mainnet";
        if (block.chainid == LOCAL_CHAIN_ID) return "Localhost (Anvil)";
        return "Base Sepolia";
    }
}
