// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import { SimpleDeployer } from "../../src/SimpleDeployer.sol";
import { ISimpleDeployer } from "../../src/interface/ISimpleDeployer.sol";
import { IPaymentProcessorStorage, PaymentProcessorStorage } from "../../src/PaymentProcessorStorage.sol";
import { SimplePaymentProcessor } from "../../src/SimplePaymentProcessor.sol";
import { PaymentAutomation } from "../../src/PaymentAutomation.sol";
import { Notes } from "../../src/Notes.sol";
import { INotes } from "../../src/interface/INotes.sol";
import { MINIMUM_INVOICE_VALUE } from "../../src/constants/Simple.sol";
import { MockWeth } from "../mock/MockWeth.sol";
import { Test } from "forge-std/Test.sol";

contract SimpleDeployerTest is Test {
    SimpleDeployer deployer;
    PaymentProcessorStorage ppStorage;

    bytes32 constant SALT = keccak256("payment-processor.simple-deployer.test");
    uint32 constant HOLD_PERIOD = 1 days;
    address constant FORWARDER = address(0xf0);
    address constant WORKFLOW_OWNER = address(0xf1);

    function setUp() public {
        ppStorage = new PaymentProcessorStorage(
            IPaymentProcessorStorage.Configuration({
                owner: address(0xa11ce),
                feeReceiver: address(0xfee5),
                intermediatedPlatformsOperator: address(0x0b5),
                weth: address(new MockWeth())
            })
        );

        deployer = new SimpleDeployer(address(this));
        deployer.deploy(_params(), _initCodes());
    }

    function test_wiresTheProcessorToItsDependencies() public view {
        SimplePaymentProcessor processor = deployer.simplePaymentProcessor();
        PaymentAutomation automation = deployer.paymentAutomation();

        assertEq(address(processor.PP_STORAGE()), address(ppStorage));
        assertEq(processor.AUTOMATION(), address(automation));
        assertEq(processor.ESCROW_HOLD_PERIOD(), HOLD_PERIOD);

        assertEq(address(automation.PROCESSOR()), address(processor));
        assertEq(address(automation.PP_STORAGE()), address(ppStorage));
        assertEq(address(deployer.notes().PP_STORAGE()), address(ppStorage));
    }

    function test_notesAuthorizesTheProcessorAndDeployerOnly() public {
        Notes notes = deployer.notes();
        address seller = address(0x5e11);

        vm.prank(seller);
        uint216 invoiceId = deployer.simplePaymentProcessor().createInvoice(MINIMUM_INVOICE_VALUE, "ref", false);
        assertEq(notes.getNoteCount(invoiceId), 1);

        notes.createNote(invoiceId, address(this), "ref", false);
        assertEq(notes.getNoteCount(invoiceId), 2);

        vm.prank(address(0xbad));
        vm.expectRevert(INotes.Unauthorized.selector);
        notes.createNote(invoiceId, address(0xbad), "ref", false);
    }

    function test_deployIsSingleUse() public {
        vm.expectRevert(ISimpleDeployer.AlreadyDeployed.selector);
        deployer.deploy(_params(), _initCodes());
    }

    function test_onlyTheDeployerCanDeploy() public {
        SimpleDeployer fresh = new SimpleDeployer(address(this));

        vm.prank(address(0xbad));
        vm.expectRevert(ISimpleDeployer.NotDeployer.selector);
        fresh.deploy(_params(), _initCodes());
    }

    function test_clearsTheNotesAuthorizationList() public view {
        assertEq(deployer.authorizedAddresses().length, 0);
    }

    function _params() internal view returns (ISimpleDeployer.Params memory) {
        return ISimpleDeployer.Params({
            salt: SALT,
            ppStorage: address(ppStorage),
            escrowHoldPeriod: HOLD_PERIOD,
            forwarder: FORWARDER,
            workflowOwner: WORKFLOW_OWNER
        });
    }

    function _initCodes() internal pure returns (ISimpleDeployer.InitCodes memory) {
        return ISimpleDeployer.InitCodes({
            notes: type(Notes).creationCode,
            simplePaymentProcessor: type(SimplePaymentProcessor).creationCode,
            paymentAutomation: type(PaymentAutomation).creationCode
        });
    }
}
