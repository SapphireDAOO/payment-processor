// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script as ForgeScript, console } from "forge-std/Script.sol";
import { ISimplePaymentProcessor } from "../src/interface/ISimplePaymentProcessor.sol";

contract Script is ForgeScript {
    uint256 private constant INVOICE_COUNT = 100;

    function run() external {
        address simplePaymentProcessorAddress = vm.envAddress("SIMPLE_PAYMENT_PROCESSOR_ADDRESS");
        uint256 creatorPrivateKey = vm.envUint("CREATOR_PRIVATE_KEY");
        uint256 payerPrivateKey = vm.envUint("PAYER_PRIVATE_KEY");

        address creator = vm.addr(creatorPrivateKey);
        address payer = vm.addr(payerPrivateKey);

        require(creator != payer, "CREATOR_AND_PAYER_MUST_DIFFER");

        ISimplePaymentProcessor simplePP = ISimplePaymentProcessor(simplePaymentProcessorAddress);

        uint216[] memory items = simplePP.getItems();

        console.log("SimplePaymentProcessor:", simplePaymentProcessorAddress);
        console.log("Creator:", creator);
        console.log("Payer:", payer);
        console.log("Items pending:", items.length);

        vm.startBroadcast(creatorPrivateKey);
        uint256 acceptedCount = 0;
        for (uint256 i = 0; i < items.length; i++) {
            uint216 item = items[i];
            ISimplePaymentProcessor.Invoice memory invoice = simplePP.getInvoiceData(item);
            if (invoice.seller == creator && invoice.status == 3) {
                console.log("Accepting invoice:", uint256(item));
                console.log("Invoice status:", uint256(invoice.status));
                simplePP.acceptPayment(item);
                acceptedCount++;
            } else {
                console.log("Skipping invoice (not creator):", uint256(item));
            }
        }
        vm.stopBroadcast();

        console.log("Invoices accepted:", acceptedCount);
    }
}
