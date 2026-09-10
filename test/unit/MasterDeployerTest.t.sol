// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { MasterDeployer } from "../../src/MasterDeployer.sol";
import { IMasterDeployer } from "../../src/interface/IMasterDeployer.sol";
import { IPaymentProcessorStorage, PaymentProcessorStorage } from "../../src/PaymentProcessorStorage.sol";
import { SimplePaymentProcessor } from "../../src/SimplePaymentProcessor.sol";
import { PaymentAutomation } from "../../src/PaymentAutomation.sol";
import { IntermediatedPaymentProcessor } from "../../src/IntermediatedPaymentProcessor.sol";
import { OracleManager } from "../../src/OracleManager.sol";
import { Notes } from "../../src/Notes.sol";
import { MultiSig } from "../../src/MultiSig.sol";
import { Sweeper } from "../../src/Sweeper.sol";
import { ISweeper } from "../../src/interface/ISweeper.sol";
import { MockUsdc } from "../mock/mERC20.sol";
import { MockWeth } from "../mock/MockWeth.sol";
import { Test } from "forge-std/Test.sol";

contract MasterDeployerTest is Test {
    MasterDeployer deployer;
    MockWeth weth;

    address internal owner = address(0xa11ce);
    address internal feeReceiver = address(0xfee5);
    address internal operator = address(0x0b5);

    bytes32 constant SALT = keccak256("payment-processor.master-deployer.test");

    function setUp() public {
        weth = new MockWeth();
        deployer = new MasterDeployer(address(this));
        deployer.deployCore(_params(), _coreInitCodes());
        deployer.deploySystem(_params(), _systemInitCodes());
    }

    function test_deploysEveryContract() public view {
        assertTrue(address(deployer.multiSig()) != address(0));
        assertTrue(address(deployer.ppStorage()) != address(0));
        assertTrue(address(deployer.notes()) != address(0));
        assertTrue(address(deployer.simplePaymentProcessor()) != address(0));
        assertTrue(address(deployer.paymentAutomation()) != address(0));
        assertTrue(address(deployer.oracleManager()) != address(0));
        assertTrue(address(deployer.intermediatedPaymentProcessor()) != address(0));
        assertTrue(address(deployer.sweeper()) != address(0), "sweeper should be deployed");
    }

    function test_sweeperIsLinkedToTheDeployedStorage() public view {
        assertEq(address(deployer.sweeper().ppStorage()), address(deployer.ppStorage()));
    }

    function test_deployedSweeperIsGatedOnTheStorageOwner() public {
        Sweeper sweeper = deployer.sweeper();
        MockUsdc token = new MockUsdc("Mock Usdc", "mUsdc");

        address holder = address(0xB0B);
        token.mint(holder, 100e6);
        vm.prank(holder);
        token.approve(address(sweeper), type(uint256).max);

        address[] memory from = new address[](1);
        from[0] = holder;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100e6;

        vm.expectRevert(ISweeper.NotAuthorized.selector);
        sweeper.sweep(address(token), from, amounts, feeReceiver);

        vm.prank(owner);
        sweeper.sweep(address(token), from, amounts, feeReceiver);

        assertEq(token.balanceOf(feeReceiver), 100e6);
    }

    function test_eachPhaseIsSingleUse() public {
        vm.expectRevert(IMasterDeployer.AlreadyDeployed.selector);
        deployer.deployCore(_params(), _coreInitCodes());

        vm.expectRevert(IMasterDeployer.AlreadyDeployed.selector);
        deployer.deploySystem(_params(), _systemInitCodes());
    }

    function test_deploySystemRequiresCoreFirst() public {
        MasterDeployer fresh = new MasterDeployer(address(this));

        vm.expectRevert(IMasterDeployer.CoreNotDeployed.selector);
        fresh.deploySystem(_params(), _systemInitCodes());
    }

    function test_phasesShareOnePredictedStorageAddress() public view {
        // The address the core phase recorded is the one the storage contract actually landed at.
        assertEq(deployer.predictedStorage(), address(deployer.ppStorage()));
    }

    function test_onlyDeployerCanRunEitherPhase() public {
        MasterDeployer fresh = new MasterDeployer(address(this));

        vm.prank(address(0xbad));
        vm.expectRevert(IMasterDeployer.NotDeployer.selector);
        fresh.deployCore(_params(), _coreInitCodes());

        vm.prank(address(0xbad));
        vm.expectRevert(IMasterDeployer.NotDeployer.selector);
        fresh.deploySystem(_params(), _systemInitCodes());
    }

    function _params() internal view returns (IMasterDeployer.Params memory params) {
        address[] memory signers = new address[](2);
        signers[0] = address(0x51);
        signers[1] = address(0x52);

        params = IMasterDeployer.Params({
            salt: SALT,
            config: IPaymentProcessorStorage.Configuration({
                owner: owner,
                feeReceiver: feeReceiver,
                intermediatedPlatformsOperator: operator,
                feeRate: 500,
                gasThreshold: 100_000
            }),
            minimumInvoiceValue: 1 ether,
            weth: address(weth),
            sequencerUptimeFeed: address(0),
            multiSigSigners: signers,
            multiSigThreshold: 2
        });
    }

    function _coreInitCodes() internal pure returns (IMasterDeployer.CoreInitCodes memory initCodes) {
        initCodes = IMasterDeployer.CoreInitCodes({
            multiSig: type(MultiSig).creationCode,
            notes: type(Notes).creationCode,
            simplePaymentProcessor: type(SimplePaymentProcessor).creationCode,
            paymentAutomation: type(PaymentAutomation).creationCode,
            ppStorage: type(PaymentProcessorStorage).creationCode
        });
    }

    function _systemInitCodes() internal pure returns (IMasterDeployer.SystemInitCodes memory initCodes) {
        initCodes = IMasterDeployer.SystemInitCodes({
            oracleManager: type(OracleManager).creationCode,
            intermediatedPaymentProcessor: type(IntermediatedPaymentProcessor).creationCode,
            sweeper: type(Sweeper).creationCode,
            ppStorage: type(PaymentProcessorStorage).creationCode
        });
    }
}
