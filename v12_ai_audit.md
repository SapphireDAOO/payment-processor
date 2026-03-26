# Audited by [V12](https://zellic.ai/)

The only autonomous Solidity auditor that finds critical bugs. Not all audits are equal, so stop paying for bad ones. Just use V12. No calls, demos, or intros.

---

# Meta invoices round down each payment

**#4**

- Severity: Critical
- Validity: Invalid

## Targets

- payMetaInvoice (AdvancedPaymentProcessor)

## Affected Locations

- **AdvancedPaymentProcessor.payMetaInvoice**: Single finding location

## Description

Single‑invoice payments compute the token amount with `getTokenValueFromUsd`, which rounds up using `mulDivUp` to prevent underpayment. The meta‑invoice path instead uses `_paySubInvoices`, which calculates each sub‑invoice price with `mulDiv` (round down) and then passes that value into `_pay`, which does not enforce a minimum amount. For low‑decimal tokens or small invoice prices relative to token value, this floor rounding can truncate away the entire payment amount for a sub‑invoice. The invoice is still marked `PAID`, and its recorded balance equals the truncated amount. As a result, buyers can pay via the meta‑invoice path to underpay each sub‑invoice, and in edge cases obtain some sub‑invoices for free.

## Root cause

Meta‑invoice payments use floor division for per‑invoice pricing and `_pay` accepts zero or truncated token amounts without validation.

## Impact

Sellers receive less than the advertised price for invoices paid through the meta‑invoice path, and rounding can reduce some sub‑invoice payments to zero for low‑decimal tokens. The shortfall is recorded as the invoice balance, so later release distributes only the reduced amount. This produces systematic value leakage for sellers and fee receivers.

## Proof of Concept

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { AdvancedPaymentProcessorSetUp } from "test/utils/AdvancedPaymentProcessorSetUp.sol";
import { getInvoiceCreationParams } from "test/utils/InvoiceTestHelpers.sol";
import { IAdvancedPaymentProcessor } from "src/interface/IAdvancedPaymentProcessor.sol";

contract MetaInvoiceRoundingPOC is AdvancedPaymentProcessorSetUp {
    function test_MetaInvoiceRoundingDownUnderpaysSubInvoices() public {
        // $1.00000001 in 8-decimal USD format; requires 1.000001 USDC when rounded up.
        uint256 price = 100_000_001;

        address[] memory sellers = new address[](2);
        sellers[0] = sellerOne;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = price;
        prices[1] = price;

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory params, uint216[] memory invoiceIds) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices);

        uint216 metaInvoiceId = advancedPP.createMetaInvoice(params);

        // Buyer pays the meta invoice in USDC; each sub-invoice uses floor rounding.
        vm.prank(buyerOne);
        advancedPP.payMetaInvoice(metaInvoiceId, address(mockUsdc));

        uint256 expectedPerInvoice = advancedPP.getTokenValueFromUsd(address(mockUsdc), price);

        for (uint256 i = 0; i < invoiceIds.length; i++) {
            IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceIds[i]);
            assertEq(inv.state, advancedPP.PAID());

            // Invariant: each sub-invoice should be funded with at least the rounded-up token amount.
            // This fails because meta-invoice payments round down per sub-invoice.
            assertGe(inv.balance, expectedPerInvoice);
        }
    }
}
```

## Remediation

**Status:** Complete

### Explanation

Add a per-sub-invoice check that compares the rounded-down token price against the rounded-up minimum and revert with `InvalidMetaInvoicePaymentAmount` if the meta-invoice path would underpay, preventing truncated payments from being accepted.

### Patch

```diff
diff --git a/payment-processor/src/AdvancedPaymentProcessor.sol b/payment-processor/src/AdvancedPaymentProcessor.sol
--- a/payment-processor/src/AdvancedPaymentProcessor.sol
+++ b/payment-processor/src/AdvancedPaymentProcessor.sol
@@ -548,6 +548,8 @@
             Invoice memory i = invoices[subInvoiceId];
             if (i.state == CREATED) {
                 uint256 price = i.price.mulDiv(10 ** _decimals, _tokenUsdPrice);
+                uint256 minimumPrice = i.price.mulDivUp(10 ** _decimals, _tokenUsdPrice);
+                if (price < minimumPrice) revert InvalidMetaInvoicePaymentAmount(price, minimumPrice);
                 amountPaid += _pay(i, subInvoiceId, _paymentToken, price);
                 invoices[subInvoiceId] = i;
             }
```

### Affected Files

- `payment-processor/src/AdvancedPaymentProcessor.sol`

### Validation Output

```
Compiling 4 files with Solc 0.8.28
Solc 0.8.28 finished in 2.97s
Compiler run successful with warnings:
Warning (2519): This declaration shadows an existing declaration.
   --> src/AdvancedPaymentProcessor.sol:551:17:
    |
551 |                 uint256 minimumPrice = i.price.mulDivUp(10 ** _decimals, _tokenUsdPrice);
    |                 ^^^^^^^^^^^^^^^^^^^^
Note: The shadowed declaration is here:
  --> src/AdvancedPaymentProcessor.sol:47:5:
   |
47 |     uint256 private minimumPrice;
   |     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^


Ran 1 test for test/PaymentProcessor.t.sol:MetaInvoiceRoundingPOC
[FAIL: InvalidMetaInvoicePaymentAmount(1000000 [1e6], 1000001 [1e6])] test_MetaInvoiceRoundingDownUnderpaysSubInvoices() (gas: 455656)
Traces:
  [9006400] MetaInvoiceRoundingPOC::setUp()
    ├─ [0] VM::deal(SHA-256: [0x0000000000000000000000000000000000000002], 100000000000000000000000 [1e23])
    │   └─ ← [Return]
    ├─ [0] VM::deal(Identity: [0x0000000000000000000000000000000000000004], 100000000000000000000000 [1e23])
    │   └─ ← [Return]
    ├─ [0] VM::deal(RIPEMD-160: [0x0000000000000000000000000000000000000003], 100000000000000000000000 [1e23])
    │   └─ ← [Return]
    ├─ [0] VM::deal(ModExp: [0x0000000000000000000000000000000000000005], 100000000000000000000000 [1e23])
    │   └─ ← [Return]
    ├─ [0] VM::prank(ECRecover: [0x0000000000000000000000000000000000000001])
    │   └─ ← [Return]
    ├─ [596935] → new PaymentProcessorStorage@0x522B3294E6d06aA25Ad0f1B8891242E335D3B459
    │   ├─ emit OwnershipTransferred(oldOwner: 0x0000000000000000000000000000000000000000, newOwner: ECRecover: [0x0000000000000000000000000000000000000001])
    │   └─ ← [Return] 2306 bytes of code
    ├─ [702271] → new Notes@0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f
    │   └─ ← [Return] 3396 bytes of code
    ├─ [0] VM::warp(7200)
    │   └─ ← [Return]
    ├─ [0] VM::mockCall(0xBCF85224fc0756B9Fa45aA7892530B47e10b6433, 0xfeaf968c, 0x0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001c200000000000000000000000000000000000000000000000000000000000000001)
    │   └─ ← [Return]
    ├─ [368041] → new MockV3Aggregator@0x2e234DAe75C793f67A35089C9d99245E1C58470b
    │   └─ ← [Return] 1061 bytes of code
    ├─ [368041] → new MockV3Aggregator@0xF62849F9A0B5Bf2913b396098F7c7019b51A820a
    │   └─ ← [Return] 1061 bytes of code
    ├─ [368041] → new MockV3Aggregator@0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9
    │   └─ ← [Return] 1061 bytes of code
    ├─ [471004] → new MockUsdc@0xc7183455a4C133Ae270771860664b6B7ec320bB1
    │   ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: MetaInvoiceRoundingPOC: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], value: 10000000000000000000000000 [1e25])
    │   └─ ← [Return] 1891 bytes of code
    ├─ [471004] → new MockWbtc@0xa0Cb889707d426A7A386870A03bc70d1b0697598
    │   ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: MetaInvoiceRoundingPOC: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], value: 10000000000000000000000000 [1e25])
    │   └─ ← [Return] 1891 bytes of code
    ├─ [0] VM::startPrank(ECRecover: [0x0000000000000000000000000000000000000001])
    │   └─ ← [Return]
    ├─ [4928281] → new AdvancedPaymentProcessor@0x535B3D7A252fa034Ed71F0C53ec0C6F784cB64E1
    │   └─ ← [Return] 24278 bytes of code
    ├─ [22785] PaymentProcessorStorage::setAuthorizedAddress(AdvancedPaymentProcessor: [0x535B3D7A252fa034Ed71F0C53ec0C6F784cB64E1], true)
    │   └─ ← [Stop]
    ├─ [23772] AdvancedPaymentProcessor::setPriceFeed(MockUsdc: [0xc7183455a4C133Ae270771860664b6B7ec320bB1], PriceFeedConfig({ aggregator: 0x2e234DAe75C793f67A35089C9d99245E1C58470b, heartbeat: 86400 [8.64e4] }))
    │   ├─ [327] PaymentProcessorStorage::owner() [staticcall]
    │   │   └─ ← [Return] ECRecover: [0x0000000000000000000000000000000000000001]
    │   └─ ← [Stop]
    ├─ [23772] AdvancedPaymentProcessor::setPriceFeed(MockWbtc: [0xa0Cb889707d426A7A386870A03bc70d1b0697598], PriceFeedConfig({ aggregator: 0xF62849F9A0B5Bf2913b396098F7c7019b51A820a, heartbeat: 86400 [8.64e4] }))
    │   ├─ [327] PaymentProcessorStorage::owner() [staticcall]
    │   │   └─ ← [Return] ECRecover: [0x0000000000000000000000000000000000000001]
    │   └─ ← [Stop]
    ├─ [23772] AdvancedPaymentProcessor::setPriceFeed(0x0000000000000000000000000000000000000000, PriceFeedConfig({ aggregator: 0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9, heartbeat: 86400 [8.64e4] }))
    │   ├─ [327] PaymentProcessorStorage::owner() [staticcall]
    │   │   └─ ← [Return] ECRecover: [0x0000000000000000000000000000000000000001]
    │   └─ ← [Stop]
    ├─ [0] VM::stopPrank()
    │   └─ ← [Return]
    ├─ [24905] MockUsdc::mint(SHA-256: [0x0000000000000000000000000000000000000002], 100000000000000000000000 [1e23])
    │   ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: SHA-256: [0x0000000000000000000000000000000000000002], value: 100000000000000000000000 [1e23])
    │   └─ ← [Stop]
    ├─ [24905] MockUsdc::mint(RIPEMD-160: [0x0000000000000000000000000000000000000003], 100000000000000000000000 [1e23])
    │   ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: RIPEMD-160: [0x0000000000000000000000000000000000000003], value: 100000000000000000000000 [1e23])
    │   └─ ← [Stop]
    ├─ [24905] MockWbtc::mint(SHA-256: [0x0000000000000000000000000000000000000002], 100000000000000000000000 [1e23])
    │   ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: SHA-256: [0x0000000000000000000000000000000000000002], value: 100000000000000000000000 [1e23])
    │   └─ ← [Stop]
    ├─ [24905] MockWbtc::mint(RIPEMD-160: [0x0000000000000000000000000000000000000003], 100000000000000000000000 [1e23])
    │   ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: RIPEMD-160: [0x0000000000000000000000000000000000000003], value: 100000000000000000000000 [1e23])
    │   └─ ← [Stop]
    ├─ [0] VM::startPrank(SHA-256: [0x0000000000000000000000000000000000000002])
    │   └─ ← [Return]
    ├─ [24734] MockUsdc::approve(AdvancedPaymentProcessor: [0x535B3D7A252fa034Ed71F0C53ec0C6F784cB64E1], 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   ├─ emit Approval(owner: SHA-256: [0x0000000000000000000000000000000000000002], spender: AdvancedPaymentProcessor: [0x535B3D7A252fa034Ed71F0C53ec0C6F784cB64E1], value: 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   └─ ← [Return] true
    ├─ [24734] MockWbtc::approve(AdvancedPaymentProcessor: [0x535B3D7A252fa034Ed71F0C53ec0C6F784cB64E1], 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   ├─ emit Approval(owner: SHA-256: [0x0000000000000000000000000000000000000002], spender: AdvancedPaymentProcessor: [0x535B3D7A252fa034Ed71F0C53ec0C6F784cB64E1], value: 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   └─ ← [Return] true
    ├─ [0] VM::stopPrank()
    │   └─ ← [Return]
    ├─ [0] VM::startPrank(RIPEMD-160: [0x0000000000000000000000000000000000000003])
    │   └─ ← [Return]
    ├─ [24734] MockUsdc::approve(AdvancedPaymentProcessor: [0x535B3D7A252fa034Ed71F0C53ec0C6F784cB64E1], 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   ├─ emit Approval(owner: RIPEMD-160: [0x0000000000000000000000000000000000000003], spender: AdvancedPaymentProcessor: [0x535B3D7A252fa034Ed71F0C53ec0C6F784cB64E1], value: 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   └─ ← [Return] true
    ├─ [24734] MockWbtc::approve(AdvancedPaymentProcessor: [0x535B3D7A252fa034Ed71F0C53ec0C6F784cB64E1], 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   ├─ emit Approval(owner: RIPEMD-160: [0x0000000000000000000000000000000000000003], spender: AdvancedPaymentProcessor: [0x535B3D7A252fa034Ed71F0C53ec0C6F784cB64E1], value: 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   └─ ← [Return] true
    ├─ [0] VM::stopPrank()
    │   └─ ← [Return]
    ├─ [0] VM::prank(ECRecover: [0x0000000000000000000000000000000000000001])
    │   └─ ← [Return]
    ├─ [23438] AdvancedPaymentProcessor::setForwarderAddress(0x00000000000000000000000000000000000000a0)
    │   ├─ [327] PaymentProcessorStorage::owner() [staticcall]
    │   │   └─ ← [Return] ECRecover: [0x0000000000000000000000000000000000000001]
    │   └─ ← [Stop]
    ├─ [0] VM::prank(ECRecover: [0x0000000000000000000000000000000000000001])
    │   └─ ← [Return]
    ├─ [23514] Notes::setAuthorized(AdvancedPaymentProcessor: [0x535B3D7A252fa034Ed71F0C53ec0C6F784cB64E1], true)
    │   ├─ [327] PaymentProcessorStorage::owner() [staticcall]
    │   │   └─ ← [Return] ECRecover: [0x0000000000000000000000000000000000000001]
    │   └─ ← [Stop]
    └─ ← [Stop]

  [455656] MetaInvoiceRoundingPOC::test_MetaInvoiceRoundingDownUnderpaysSubInvoices()
    ├─ [2385] PaymentProcessorStorage::getNextInvoiceNonce() [staticcall]
    │   └─ ← [Return] 1
    ├─ [376041] AdvancedPaymentProcessor::createMetaInvoice([InvoiceCreationParam({ invoiceId: "1", seller: 0x0000000000000000000000000000000000000004, price: 100000001 [1e8], escrowHoldPeriod: 0 }), InvoiceCreationParam({ invoiceId: "2", seller: 0x0000000000000000000000000000000000000005, price: 100000001 [1e8], escrowHoldPeriod: 0 })])
    │   ├─ [2332] PaymentProcessorStorage::getMarketplace() [staticcall]
    │   │   └─ ← [Return] MetaInvoiceRoundingPOC: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496]
    │   ├─ [385] PaymentProcessorStorage::getNextInvoiceNonce() [staticcall]
    │   │   └─ ← [Return] 1
    │   ├─ [2402] PaymentProcessorStorage::getPaymentValidityDuration() [staticcall]
    │   │   └─ ← [Return] 604800 [6.048e5]
    │   ├─ emit InvoiceCreated(invoiceId: 47469337584846097524001829613972953296694151841621382088733192561 [4.746e64], invoice: Invoice({ invoiceNonce: 1, paidAt: 0, createdAt: 7200, releaseAt: 0, expiresAt: 612000 [6.12e5], state: 1, escrowHoldPeriod: 0, metaInvoiceId: 32720166532801338348784428673478452617530548818593946480306833445 [3.272e64], buyer: 0x0000000000000000000000000000000000000000, seller: 0x0000000000000000000000000000000000000004, escrow: 0x0000000000000000000000000000000000000000, paymentToken: 0x0000000000000000000000000000000000000000, amountPaid: 0, price: 100000001 [1e8], balance: 0 }))
    │   ├─ [402] PaymentProcessorStorage::getPaymentValidityDuration() [staticcall]
    │   │   └─ ← [Return] 604800 [6.048e5]
    │   ├─ emit InvoiceCreated(invoiceId: 65832466245742900277100292685972731125692458422466644838442053833 [6.583e64], invoice: Invoice({ invoiceNonce: 2, paidAt: 0, createdAt: 7200, releaseAt: 0, expiresAt: 612000 [6.12e5], state: 1, escrowHoldPeriod: 0, metaInvoiceId: 32720166532801338348784428673478452617530548818593946480306833445 [3.272e64], buyer: 0x0000000000000000000000000000000000000000, seller: 0x0000000000000000000000000000000000000005, escrow: 0x0000000000000000000000000000000000000000, paymentToken: 0x0000000000000000000000000000000000000000, amountPaid: 0, price: 100000001 [1e8], balance: 0 }))
    │   ├─ [6208] PaymentProcessorStorage::updateInvoiceNonce(2)
    │   │   └─ ← [Return] 2
    │   ├─ emit MetaInvoiceCreated(metaInvoiceId: 32720166532801338348784428673478452617530548818593946480306833445 [3.272e64], totalPrice: 200000002 [2e8])
    │   └─ ← [Return] 32720166532801338348784428673478452617530548818593946480306833445 [3.272e64]
    ├─ [0] VM::prank(SHA-256: [0x0000000000000000000000000000000000000002])
    │   └─ ← [Return]
    ├─ [50331] AdvancedPaymentProcessor::payMetaInvoice(32720166532801338348784428673478452617530548818593946480306833445 [3.272e64], MockUsdc: [0xc7183455a4C133Ae270771860664b6B7ec320bB1])
    │   ├─ [0] OptimismValidator::latestRoundData() [staticcall]
    │   │   └─ ← [Return] 0x0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001c200000000000000000000000000000000000000000000000000000000000000001
    │   ├─ [8991] MockV3Aggregator::latestRoundData() [staticcall]
    │   │   └─ ← [Return] 1, 100000000 [1e8], 7200, 43200000 [4.32e7], 1
    │   ├─ [176] MockUsdc::decimals() [staticcall]
    │   │   └─ ← [Return] 6
    │   └─ ← [Revert] InvalidMetaInvoicePaymentAmount(1000000 [1e6], 1000001 [1e6])
    └─ ← [Revert] InvalidMetaInvoicePaymentAmount(1000000 [1e6], 1000001 [1e6])

Backtrace:
  at AdvancedPaymentProcessor.payMetaInvoice
  at MetaInvoiceRoundingPOC.test_MetaInvoiceRoundingDownUnderpaysSubInvoices

Suite result: FAILED. 0 passed; 1 failed; 0 skipped; finished in 3.91ms (695.26µs CPU time)

Ran 1 test suite in 1.57s (3.91ms CPU time): 0 tests passed, 1 failed, 0 skipped (1 total tests)

Failing tests:
Encountered 1 failing test in test/PaymentProcessor.t.sol:MetaInvoiceRoundingPOC
[FAIL: InvalidMetaInvoicePaymentAmount(1000000 [1e6], 1000001 [1e6])] test_MetaInvoiceRoundingDownUnderpaysSubInvoices() (gas: 455656)

Encountered a total of 1 failing tests, 0 tests succeeded

Tip: Run `forge test --rerun` to retry only the 1 failed test
```

## Comments

- The per-sub-invoice rounding shortfall is bounded by 1 token unit total across the entire batch — at 18 decimals that is 1 wei, at 8 decimals it is 1 satoshi. Both are economically negligible. The proportional distribution in \_paySubInvoices already mitigates this by computing a single ceiling aggregate for all CREATED sub-invoices and assigning the remainder to the last one, ensuring the full charged amount is distributed. No sub-invoice can receive zero unless the aggregate itself rounds to zero, which SubInvoicePriceUnderflow guards against _(Mar 26, 2026, 02:23 PM)_

---

# Reentrancy overwrites invoice escrow state

**#5**

- Severity: Critical
- Validity: Invalid

## Targets

- pay (SimplePaymentProcessor)

## Affected Locations

- **SimplePaymentProcessor.pay**: The function (via `_payWithValue`) deploys `new Escrow` before persisting the invoice’s paid/escrow fields and then writes a cached invoice back to storage; moving state finalization before the external call (and/or adding `nonReentrant` and avoiding stale memory writes) is what remediates the overwrite/reentrancy issue.

## Description

`SimplePaymentProcessor.pay` performs an external action (`new Escrow` funded with buyer ETH) before persisting the invoice’s updated state, leaving the invoice in its pre-payment `CREATED` state during escrow construction. Because contract creation executes the escrow constructor, an adversarial escrow (or constructor-side effects) can reenter the processor and call `pay` again while checks still pass. The function later writes back a cached in-memory copy of the invoice, so when the original call resumes it can overwrite storage with stale data that points to the wrong escrow instance. This breaks the invariant that a “paid” invoice references the escrow that actually holds the buyer’s funds. The end result is inconsistent invoice-to-escrow linkage that can be exploited for fund redirection or permanent lockup.

## Root cause

The payment flow performs an external call (escrow deployment) before updating invoice storage and then commits a stale memory copy without any reentrancy protection.

## Impact

An attacker able to reenter during escrow creation can cause multiple escrows to be created/funded while the invoice ends up referencing an empty or unintended escrow. The seller may be unable to release funds for the invoice marked as paid, while the attacker can reclaim or redirect the ETH via the reentrantly-created escrow, resulting in loss or indefinite lockup of funds.

## Remediation

**Status:** Incomplete

### Explanation

Update the invoice in storage (mark paid and set escrow address) before performing any external escrow deployment and avoid writing back a stale memory copy; use a storage reference and commit all state changes prior to interactions. Add a reentrancy guard on `pay` to block reentry during escrow creation so the state cannot be overwritten or duplicated.

## Comments

- `Escrow` is a concrete contract deployed by the processor itself. Its constructor only sets two immutables and emits `FundsDeposited` — no external calls, no reentrancy window during deployment. Even if reentrancy did occur during `new Escrow`, the invoice state is committed to storage (`invoices[_invoiceId] = i`) before the heap insert, and a reentrant `pay` call reads `i.state == PAID` and fails the `i.state != CREATED` guard. No stale-state overwrite is possible. _(Mar 26, 2026, 02:23 PM)_

---

# Unchecked escrow withdrawals finalize wrong state

**#1**

- Severity: High
- Validity: Invalid

## Targets

- acceptPayment (SimplePaymentProcessor)
- \_release (SimplePaymentProcessor)
- \_release (AdvancedPaymentProcessor)
- performUpkeep (SimplePaymentProcessor)

## Affected Locations

- **SimplePaymentProcessor.acceptPayment**: The function deducts the protocol fee from `Invoice.balance` and finalizes acceptance without enforcing that the subsequent `IEscrow.withdraw` succeeded. Checking the returned boolean (or reverting on failure) and/or only updating invoice accounting after a successful fee withdrawal prevents fee bypass and balance desynchronization.
- **SimplePaymentProcessor.\_release**: The function sets the invoice to `RELEASED`/`REFUNDED`, zeroes balance, and removes the heap entry before attempting `IEscrow.withdraw`, and it does not revert when `withdraw` returns `false`. Reordering to follow checks-effects-interactions (or reverting/retaining a retryable state on failure) is required to avoid permanently finalizing invoices without actual payouts.
- **AdvancedPaymentProcessor.\_release**: This release flow finalizes invoice state and then calls `_processSellerPayout` with `_revertOnFail = false`, explicitly allowing failed `IEscrow.withdraw` calls to be ignored. Making payout failures revert or leaving the invoice in a retryable state (and only finalizing after successful withdrawals) is necessary to prevent stuck escrow balances with an irreversibly released invoice.
- **SimplePaymentProcessor.performUpkeep**: Automation can call this function and indirectly finalize invoices via `_release` without any caller-controlled recovery step. Once automation runs, the invoice becomes ineligible for manual retry paths, so this entry point can lock funds when withdrawals fail.

## Description

Multiple payment flows treat `IEscrow.withdraw` as best-effort even though it signals failure by returning `false`, and they commit irreversible invoice/accounting changes before (or without) enforcing successful transfers. In `acceptPayment`, the invoice is marked accepted and its `balance` is reduced for protocol fees even if the fee withdrawal silently fails, desynchronizing invoice accounting from the escrow’s real holdings. In the release/refund path, invoices are marked `RELEASED`/`REFUNDED`, balances are zeroed, and heap entries are removed before attempting payouts, and failures only emit an event while the function still returns success. This breaks the retry invariants present in other manual paths that revert on failed withdrawals, because once state is finalized there is no on-chain way to re-attempt the transfer. The net effect is that protocol fees can be bypassed or left stranded and seller/buyer payouts can become permanently stuck in escrow despite invoices being “settled” on-chain.

## Root cause

The processors update invoice state/accounting and proceed as if transfers succeeded without requiring `IEscrow.withdraw(...) == true` (and in some paths they finalize state before attempting withdrawals at all).

## Impact

A malicious or non-compliant escrow/token/recipient can force `withdraw` to return `false` so fees are not actually paid while the invoice records them as paid, allowing fee bypass and creating stranded amounts. The same failure mode can permanently lock escrowed funds by finalizing invoices as released/refunded even though no payout occurred, preventing any later retry and denying sellers or buyers access to funds.

## Proof of Concept

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "src/SimplePaymentProcessor.sol";
import { PaymentProcessorStorage } from "src/PaymentProcessorStorage.sol";
import { Notes } from "src/Notes.sol";
import { IPaymentProcessorStorage } from "src/interface/IPaymentProcessorStorage.sol";

contract RevertingReceiver {
    receive() external payable {
        revert("no fee");
    }
}

contract PaymentProcessorFeeBypassTest is Test {
    SimplePaymentProcessor internal simplePP;
    PaymentProcessorStorage internal ppStorage;
    Notes internal notes;
    RevertingReceiver internal feeReceiver;

    address internal admin = address(1);
    address internal buyer = address(2);
    address internal seller = address(3);

    uint256 internal constant INITIAL_BALANCE = 100 ether;
    uint256 internal constant FEE_RATE = 500;
    uint256 internal constant DEFAULT_HOLD_PERIOD = 1 days;
    uint256 internal constant MINIMUM_INVOICE_VALUE = 1 ether;
    uint256 internal constant GAS_THRESHOLD = 100_000;

    function setUp() public {
        feeReceiver = new RevertingReceiver();

        IPaymentProcessorStorage.Configuration memory config = IPaymentProcessorStorage.Configuration({
            owner: admin,
            feeReceiver: address(feeReceiver),
            marketplace: address(this),
            feeRate: uint96(FEE_RATE),
            defaultHoldPeriod: uint96(DEFAULT_HOLD_PERIOD),
            gasThreshold: uint96(GAS_THRESHOLD)
        });

        vm.prank(admin);
        ppStorage = new PaymentProcessorStorage(config);
        notes = new Notes(address(ppStorage));

        vm.startPrank(admin);
        simplePP = new SimplePaymentProcessor(address(ppStorage), MINIMUM_INVOICE_VALUE, address(notes));
        ppStorage.setAuthorizedAddress(address(simplePP), true);
        notes.setAuthorized(address(simplePP), true);
        vm.stopPrank();

        vm.prank(address(ppStorage));
        simplePP.setForwarderAddress(address(0xb0));

        vm.deal(buyer, INITIAL_BALANCE);
        vm.deal(seller, INITIAL_BALANCE);
    }

    function test_feeWithdrawalFailureLeavesEscrowStranded() public {
        uint256 price = 10 ether;

        vm.prank(seller);
        uint216 invoiceId = simplePP.createInvoice(price, "", false);

        vm.prank(buyer);
        simplePP.pay{ value: price }(invoiceId, "", false);

        address escrow = simplePP.getInvoiceData(invoiceId).escrow;
        uint256 fee = simplePP.calculateFee(price);

        vm.prank(seller);
        simplePP.acceptPayment(invoiceId);

        assertEq(address(feeReceiver).balance, 0);
        assertEq(simplePP.getInvoiceData(invoiceId).balance, price - fee);
        assertEq(escrow.balance, price);

        vm.warp(block.timestamp + DEFAULT_HOLD_PERIOD + 1);
        uint256 sellerBefore = seller.balance;

        vm.prank(seller);
        simplePP.release(invoiceId);

        assertEq(seller.balance, sellerBefore + (price - fee));
        assertEq(address(feeReceiver).balance, 0);
        assertEq(escrow.balance, fee);
        assertEq(simplePP.getInvoiceData(invoiceId).state, simplePP.RELEASED());
    }
}
```

## Remediation

**Status:** Unfixable

### Explanation

Require every `IEscrow.withdraw(...)` call to succeed and revert on any `false`/failure, and only update invoice/payment state after all withdrawals complete successfully. This ensures failed payouts/refunds do not finalize invoices and keeps escrowed funds available for retry.

### Error

Unable to produce a surgical fix that both enforces `IEscrow.withdraw` success and preserves the current automation flow: enforcing failures in `acceptPayment` and automated releases still leaves best-effort withdrawals in other paths and would require broader refactoring (e.g., redesigning `IEscrow.withdraw` semantics or adding retryable state) beyond minimal changes.

## Comments

- The automation `_release` deliberately uses best-effort withdrawals to prevent a single rejecting recipient from permanently blocking the release queue (head-of-line DoS). Reverting on automation failures is the wrong fix — it would let one malicious buyer stall all other invoices. The legitimate sub-issue is `acceptPayment`: the fee withdraw return is genuinely unchecked, leaving fee ETH stuck in escrow if the receiver rejects. That is fixable in isolation (`if (!IEscrow(...).withdraw(...)) revert EscrowWithdrawFailed()`). The automation paths are working as designed. _(Mar 26, 2026, 02:23 PM)_

---

# Reentrancy during seller payout bypasses fee collection

**#6**

- Severity: High
- Validity: Invalid

## Targets

- \_processSellerPayout (AdvancedPaymentProcessor)

## Affected Locations

- **AdvancedPaymentProcessor.\_processSellerPayout**: The function initiates seller payment via `IEscrow.withdraw` before collecting fees or ensuring the related invoice/escrow cannot be acted on again; reordering to finalize state/collect fees first and/or adding a `nonReentrant` guard closes the reentrancy window.

## Description

`AdvancedPaymentProcessor._processSellerPayout` calls `IEscrow.withdraw` to pay the seller before attempting to withdraw the platform fee. `Escrow.withdraw` necessarily performs external calls (to the seller and/or a token), so a malicious seller contract can reenter the processor during this first withdrawal. Because this helper does not itself finalize invoice state and is used in flows that only mark invoices finalized after payouts, the system can remain in a state where additional payout/refund paths are still callable during reentrancy. The seller can use the reentrant window to trigger additional withdrawals/refunds from the same escrow, draining the remaining balance that would otherwise cover fees. If `_revertOnFail` is false, the subsequent fee withdrawal failure is only logged, allowing the transaction to succeed while fees are skipped.

## Root cause

The payout sequence makes an external call to the seller (via `IEscrow.withdraw`) before fee withdrawal/state finalization and lacks reentrancy protection, creating a reentrancy window in the payout flow.

## Impact

A malicious seller can reenter during their payout and drain the remaining escrow balance, including the portion intended for platform fees, before the fee withdrawal executes. This can cause fee withdrawal to fail while the overall operation continues, resulting in fee loss and potential overpayment to the seller. Any additional funds sitting in the escrow at that moment can also be captured through the reentrant actions.

## Remediation

**Status:** Incomplete

### Explanation

Update `_processSellerPayout` to follow checks‑effects‑interactions: compute and withdraw platform fees and finalize payout state before invoking the seller’s external `withdraw`, so reentrancy cannot steal fee funds. Add a reentrancy guard (or use a pull‑based claim flow) around the payout path to block any reentrant calls during the escrow withdrawal.

## Comments

- By the time `_processSellerPayout` is called from `_release`, invoice state is already `RELEASED` and `balance` is 0. Any reentrant call from the seller’s `receive()` into `release`, `refund`, or `handleDispute` will fail the state check on entry. The escrow holds exactly `sellerNetAmount + fee` at payout time — if the seller somehow drains `sellerNetAmount` via reentrancy, the subsequent fee withdraw returns false; the automation path only emits `TransferFailed` and the transaction still succeeds. No fee is captured by the seller and no funds are double-spent. _(Mar 26, 2026, 02:23 PM)_

---

# Heap/index mapping desynchronization

**#7**

- Severity: High
- Validity: Invalid

## Targets

- performUpkeep (SimplePaymentProcessor)
- release (AdvancedPaymentProcessor)

## Affected Locations

- **SimplePaymentProcessor.performUpkeep**: `performUpkeep` calls `heap.processDueTask` in a way that allows internal heap removals/swaps to occur without synchronizing the external `index` mapping, so invoice IDs can keep pointing to outdated heap positions; ensuring upkeep-driven heap mutations update/clear `index` is necessary to restore correctness for subsequent manual operations.
- **AdvancedPaymentProcessor.release**: `release` transitions an invoice to the released state via `_release` but does not remove its scheduled heap entry or clear `index`, leaving a stale task that automation will keep selecting; removing the heap entry and clearing/updating `index` here prevents upkeep from repeatedly targeting an already-released invoice and avoids queue poisoning.

## Description

Both processors maintain an `index` mapping as the authoritative link from an invoice ID to its position in the heap, and multiple settlement paths assume this mapping stays consistent with any heap swaps/removals. In `SimplePaymentProcessor.performUpkeep`, due-task processing can mutate the heap without any way to update the external `index` mapping, leaving invoice IDs pointing at stale positions after upkeep-driven removals or swaps. In `AdvancedPaymentProcessor.release`, the invoice is released but its scheduled heap entry and `index` mapping are not removed/cleared, so automation continues to target a task that no longer represents a valid pending invoice. Once the mapping is stale in either direction, later settlement actions that use `index` can remove/reschedule the wrong heap element or repeatedly attempt to process an already-finished invoice. The net effect is that the queue’s bookkeeping becomes unreliable, breaking liveness and correctness for unrelated invoices.

## Root cause

Heap state is mutated (or invoice scheduling state is changed) on some execution paths without correspondingly updating or clearing the `index` mapping that other paths treat as always correct.

## Impact

Attackers or misbehaving integrations can cause the scheduler to deschedule or mis-handle other users’ invoices by operating through stale `index` entries, leading to stuck escrow and delayed refunds/releases. Automated upkeep can also get trapped retrying stale tasks, causing repeated upkeep failures and preventing timely processing of unrelated invoices; if release logic is not strictly idempotent, repeated processing can risk duplicate payouts.

## Remediation

**Status:** Incomplete

### Explanation

Update the heap mutation logic used by `performUpkeep` (and any scheduling/descheduling paths) so that every remove/pop/swap updates the corresponding `index` mapping entry and clears it when an invoice is no longer scheduled, ensuring the mapping always mirrors the heap’s current positions. Enforce this invariant centrally in the heap library or a single internal function so no execution path can mutate the heap without synchronously fixing the `index` mapping.

## Comments

- `TaskQueueLib.removeAt` already maintains the `index` mapping atomically: it moves the last heap element into the vacated slot, updates `_index[movedId]` to the new position, and calls `delete _index[removedId]`. Every heap mutation that changes element positions synchronizes `index` in the same operation. `AdvancedPaymentProcessor._release` calls `heap.removeAt(pos - 1, index)` before the payout — the entry is removed and the mapping is cleared before any external call. No stale entries remain. _(Mar 26, 2026, 02:23 PM)_

---

# Native payments revert on decimals lookup

**#2**

- Severity: Medium
- Validity: Invalid

## Targets

- payMetaInvoice (AdvancedPaymentProcessor)

## Affected Locations

- **AdvancedPaymentProcessor.payMetaInvoice**: Single finding location

## Description

`payMetaInvoice` allows any `_paymentToken` that has a configured price feed, and the system supports native payments by using `address(0)` as the native token key. The function then unconditionally calls `_getDecimals(_paymentToken)` to derive the token’s decimal precision. `_getDecimals` performs a `staticcall` to `decimals()` and immediately `abi.decode`s the returned data without checking for empty return data or handling `address(0)`. For the native token address (or any token that doesn’t implement `decimals()`), the `staticcall` succeeds with zero‑length data and `abi.decode` reverts. This causes the entire payment to revert before any funds are processed, effectively disabling native‑token payments through this entry point.

## Root cause

The decimals helper assumes every supported token implements `decimals()` and does not guard against `address(0)` or zero‑length return data.

## Impact

Users cannot pay meta‑invoices with the native token (or any non‑standard token lacking `decimals()`), even if a price feed is configured. This blocks an advertised payment route and can prevent invoice settlement when native payments are expected.

## Proof of Concept

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import { AdvancedPaymentProcessor } from "src/AdvancedPaymentProcessor.sol";
import { IAdvancedPaymentProcessor } from "src/interface/IAdvancedPaymentProcessor.sol";
import { AdvancedPaymentProcessorSetUp } from "test/utils/AdvancedPaymentProcessorSetUp.sol";
import { getInvoiceCreationParams } from "test/utils/InvoiceTestHelpers.sol";

contract PaymentProcessorTest is AdvancedPaymentProcessorSetUp {
    function test_nativeMetaInvoicePaymentRevertsOnDecimalsLookup() public {
        address[] memory sellers = new address[](2);
        sellers[0] = sellerOne;
        sellers[1] = sellerTwo;

        uint256[] memory prices = new uint256[](2);
        prices[0] = 100e8;
        prices[1] = 200e8;

        (IAdvancedPaymentProcessor.InvoiceCreationParam[] memory params,) =
            getInvoiceCreationParams(ppStorage.getNextInvoiceNonce(), sellers, prices);

        uint216 metaInvoiceId = advancedPP.createMetaInvoice(params);

        vm.prank(buyerOne);
        (bool success,) = address(advancedPP).call(
            abi.encodeWithSelector(AdvancedPaymentProcessor.payMetaInvoice.selector, metaInvoiceId, address(0))
        );

        assertTrue(success, "native-token meta invoice payment should succeed but reverted");
    }
}
```

## Remediation

**Status:** Error

### Explanation

Modify the decimals helper (and its usage in `payMetaInvoice`) to explicitly handle native payments by returning a fixed native decimals value (e.g., 18) when `token == address(0)` and to query ERC‑20 decimals via a low‑level `staticcall` that checks success and return length; if the call fails or returns empty, fall back to a configured decimals value (or revert with a clear error). This prevents unintended reverts and allows native and non‑standard tokens to be used as advertised.

### Error

Error code: 400 - {'error': {'message': 'Your input exceeds the context window of this model. Please adjust your input and try again.', 'type': 'invalid_request_error', 'param': 'input', 'code': 'context_length_exceeded'}}

## Comments

- `payMetaInvoice` is not `payable`, so ETH cannot be sent to it regardless of what token address is passed. The native ETH path for meta-invoices is `payMetaInvoiceWithValue`, which is `payable` and handles the full ETH flow correctly. Calling `payMetaInvoice` with `address(0)` does revert (via `_getDecimals` decoding empty return data from a staticcall to the zero address), but this is not a blocked advertised route — the function was never intended to accept ETH. The fix is to add an explicit `address(0)` guard at the entry point to return a clearer error, not to enable native payment through this function. _(Mar 26, 2026, 02:23 PM)_

---

# Rounding mismatch DoS in ETH meta-invoices

**#9**

- Severity: Medium
- Validity: Invalid

## Targets

- payMetaInvoiceWithValue (AdvancedPaymentProcessor)
- \_paySubInvoices (AdvancedPaymentProcessor)
- createMetaInvoice (AdvancedPaymentProcessor)

## Affected Locations

- **AdvancedPaymentProcessor.payMetaInvoiceWithValue**: This function converts the meta-invoice’s aggregated USD price to a single once-rounded `priceInToken` and requires `msg.value` to match it exactly, then later relies on `priceInToken - amountPaid` not underflowing; changing this to use the sum of per-sub-invoice rounded requirements (or to allow `msg.value` to cover the maximum and refund excess) remediates the mismatch.
- **AdvancedPaymentProcessor.\_paySubInvoices**: This routine necessarily computes and settles each sub-invoice separately with its own USD→ETH rounding, so when many small sub-invoices exist the rounding deltas accumulate and push the total required value above the once-rounded aggregate, magnifying the chance of reverts.
- **AdvancedPaymentProcessor.createMetaInvoice**: This function stores the meta-invoice total as a simple sum of sub-invoice USD prices without accounting for how per-sub-invoice rounding will be applied later, propagating an aggregate price that is not guaranteed to be fundable when execution pays sub-invoices using per-item rounding.

## Description

The ETH meta-invoice payment path computes a single once-rounded `priceInToken` from the meta-invoice’s aggregated USD total and requires `msg.value` to equal that exact amount. However, the execution path that actually settles the meta-invoice necessarily prices and pays each sub-invoice individually, applying USD→ETH conversion and rounding per line item. For meta-invoices with many small sub-invoices, the sum of per-sub-invoice rounded payments can exceed the once-rounded aggregate total. When that happens, the contract runs out of value for later sub-invoices and/or `priceInToken - amountPaid` underflows, causing a full revert even though each individual sub-invoice price is valid. This makes some meta-invoices unpayable via the native-currency meta flow purely due to rounding divergence.

## Root cause

The contract assumes that “round once on the aggregate” equals “sum of per-item rounded amounts” and enforces exact `msg.value`, even though per-sub-invoice rounding can make the summed requirement larger.

## Impact

Some meta-invoices cannot be paid with native currency because the required once-rounded `msg.value` is insufficient to cover the sum of individually rounded sub-invoice payments, so payments revert deterministically. A malicious or compromised invoice creator can amplify this by splitting amounts into many small sub-invoices to accumulate rounding overhead and effectively block the ETH meta-invoice payment path, forcing users into alternative payment flows.

## Remediation

**Status:** Incomplete

### Explanation

Compute the required native value for a meta-invoice as the sum of each sub-invoice’s individually rounded native amount using the same rounding logic as `payInvoice`, and require `msg.value` to be at least that sum (refunding any excess) instead of enforcing an exact once‑rounded aggregate. This keeps the ETH path consistent with per-item rounding and eliminates deterministic reverts caused by rounding overhead.

## Comments

- The premise is mathematically false. For any non-negative values `a_i` and positive `b`: `sum(floor(a_i / b)) ≤ floor(sum(a_i) / b) ≤ ceil(sum(a_i) / b)`. The aggregate ceiling used for `priceInToken` is always ≥ the sum of per-sub-invoice floors produced by `_paySubInvoices`. Therefore `priceInToken - amountPaid` is guaranteed non-negative and cannot underflow. No payment can revert due to this arithmetic relationship. _(Mar 26, 2026, 02:23 PM)_

---

# Oracle decimals not normalized

**#3**

- Severity: Low
- Validity: Invalid

## Targets

- getTokenValueFromUsd (AdvancedPaymentProcessor)

## Affected Locations

- **AdvancedPaymentProcessor.getTokenValueFromUsd**: Single finding location

## Description

Invoice prices are stored as raw USD amounts with 8‑decimal precision (the minimum price is set to `1e8`). The conversion path in `_usdPerToken` returns the raw Chainlink `answer` without normalizing by the feed’s `decimals()`, and every payment function relies on this value via `getTokenValueFromUsd` or `_paySubInvoices`. If a supported token’s feed uses a different precision (e.g., 18 decimals on many L2 feeds), the computed token amount is off by 10^(decimals−8). The payment functions accept that mispriced amount and mark the invoice as paid, permanently locking in the incorrect balance. This lets buyers drastically underpay (or overpay) whenever a feed’s decimals differ from the assumed 8‑decimal USD format.

## Root cause

The contract assumes all price feeds return 8‑decimal USD values and never reads or normalizes the oracle’s actual `decimals()` value.

## Impact

Buyers can pay far less than the intended USD price when a token’s oracle uses higher precision, yet the invoice is still marked as paid and released. Sellers and the fee receiver receive only the mispriced amount and cannot recover the shortfall. The discrepancy can be orders of magnitude if a feed uses 18 decimals.

## Proof of Concept

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAdvancedPaymentProcessor, AdvancedPaymentProcessor } from "src/AdvancedPaymentProcessor.sol";
import { MockV3Aggregator } from "test/mock/MockV3Aggregator.sol";
import { AdvancedPaymentProcessorSetUp } from "test/utils/AdvancedPaymentProcessorSetUp.sol";
import { getInvoiceCreationParam } from "test/utils/InvoiceTestHelpers.sol";

contract OracleDecimalsMismatchTest is AdvancedPaymentProcessorSetUp {
    function test_oracleDecimalsMismatchAllowsUnderpayment() public {
        // Replace the USDC price feed with an 18-decimal feed ($1 with 18 decimals).
        MockV3Aggregator highDecimalsFeed = new MockV3Aggregator(18, 1e18);
        vm.prank(admin);
        advancedPP.setPriceFeed(
            address(mockUsdc),
            IAdvancedPaymentProcessor.PriceFeedConfig({ aggregator: address(highDecimalsFeed), heartbeat: 24 hours })
        );

        uint256 price = 100e8; // $100 with 8 decimals.
        uint216 invoiceId = advancedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price)
        );

        uint256 quotedTokenAmount = advancedPP.getTokenValueFromUsd(address(mockUsdc), price);
        assertLt(quotedTokenAmount, 1e6); // Less than 1 USDC due to decimals mismatch.

        vm.prank(buyerOne);
        advancedPP.payInvoice(invoiceId, address(mockUsdc));

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);

        // Convert the paid amount to USD with 8 decimals using the actual 18-decimal price feed.
        uint256 paidUsd8 = (inv.amountPaid * uint256(1e18) / (10 ** mockUsdc.decimals())) / 1e10;
        assertLt(paidUsd8, price); // Payment accepted despite being worth far less than the invoice price.

        assertEq(inv.state, advancedPP.PAID());
        assertEq(IERC20(mockUsdc).balanceOf(inv.escrow), inv.amountPaid);
    }
}
```

## Remediation

**Status:** Complete

### Explanation

Normalize the oracle `answer` to 8 decimals in `_usdPerToken` by scaling it using the feed’s reported `decimals()`, ensuring all USD conversions use consistent precision. Add `decimals()` to `AggregatorV3Interface` so the contract can read the feed precision and prevent under/overpayment when feeds differ from 8 decimals.

### Patch

```diff
diff --git a/payment-processor/src/interface/AggregatorV3Interface.sol b/payment-processor/src/interface/AggregatorV3Interface.sol
--- a/payment-processor/src/interface/AggregatorV3Interface.sol
+++ b/payment-processor/src/interface/AggregatorV3Interface.sol
@@ -20,4 +20,6 @@
         external
         view
         returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
+
+    function decimals() external view returns (uint8);
 }
diff --git a/payment-processor/src/AdvancedPaymentProcessor.sol b/payment-processor/src/AdvancedPaymentProcessor.sol
--- a/payment-processor/src/AdvancedPaymentProcessor.sol
+++ b/payment-processor/src/AdvancedPaymentProcessor.sol
@@ -432,7 +432,15 @@
         if (answer <= 0) revert InvalidPrice();
         if (block.timestamp > updatedAt + config.heartbeat) revert StalePriceFeed();

-        return answer.toUint256(); // 8 decimals from Chainlink
+        uint256 price = answer.toUint256();
+        uint8 feedDecimals = AggregatorV3Interface(config.aggregator).decimals();
+        if (feedDecimals > 8) {
+            price = price / (10 ** (feedDecimals - 8));
+        } else if (feedDecimals < 8) {
+            price = price * (10 ** (8 - feedDecimals));
+        }
+
+        return price;
     }

     /**
```

### Affected Files

- `payment-processor/src/interface/AggregatorV3Interface.sol`
- `payment-processor/src/AdvancedPaymentProcessor.sol`

### Validation Output

```
Compiling 33 files with Solc 0.8.28
Solc 0.8.28 finished in 2.97s
Compiler run successful!

Ran 1 test for test/PaymentProcessor.t.sol:OracleDecimalsMismatchTest
[FAIL: assertion failed: 100000000 >= 1000000] test_oracleDecimalsMismatchAllowsUnderpayment() (gas: 572461)
Traces:
  [9039500] OracleDecimalsMismatchTest::setUp()
    ├─ [0] VM::deal(SHA-256: [0x0000000000000000000000000000000000000002], 100000000000000000000000 [1e23])
    │   └─ ← [Return]
    ├─ [0] VM::deal(Identity: [0x0000000000000000000000000000000000000004], 100000000000000000000000 [1e23])
    │   └─ ← [Return]
    ├─ [0] VM::deal(RIPEMD-160: [0x0000000000000000000000000000000000000003], 100000000000000000000000 [1e23])
    │   └─ ← [Return]
    ├─ [0] VM::deal(ModExp: [0x0000000000000000000000000000000000000005], 100000000000000000000000 [1e23])
    │   └─ ← [Return]
    ├─ [0] VM::prank(ECRecover: [0x0000000000000000000000000000000000000001])
    │   └─ ← [Return]
    ├─ [596935] → new PaymentProcessorStorage@0x522B3294E6d06aA25Ad0f1B8891242E335D3B459
    │   ├─ emit OwnershipTransferred(oldOwner: 0x0000000000000000000000000000000000000000, newOwner: ECRecover: [0x0000000000000000000000000000000000000001])
    │   └─ ← [Return] 2306 bytes of code
    ├─ [702271] → new Notes@0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f
    │   └─ ← [Return] 3396 bytes of code
    ├─ [0] VM::warp(7200)
    │   └─ ← [Return]
    ├─ [0] VM::mockCall(0xBCF85224fc0756B9Fa45aA7892530B47e10b6433, 0xfeaf968c, 0x0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001c200000000000000000000000000000000000000000000000000000000000000001)
    │   └─ ← [Return]
    ├─ [368041] → new MockV3Aggregator@0x2e234DAe75C793f67A35089C9d99245E1C58470b
    │   └─ ← [Return] 1061 bytes of code
    ├─ [368041] → new MockV3Aggregator@0xF62849F9A0B5Bf2913b396098F7c7019b51A820a
    │   └─ ← [Return] 1061 bytes of code
    ├─ [368041] → new MockV3Aggregator@0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9
    │   └─ ← [Return] 1061 bytes of code
    ├─ [471004] → new MockUsdc@0xc7183455a4C133Ae270771860664b6B7ec320bB1
    │   ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: OracleDecimalsMismatchTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], value: 10000000000000000000000000 [1e25])
    │   └─ ← [Return] 1891 bytes of code
    ├─ [471004] → new MockWbtc@0xa0Cb889707d426A7A386870A03bc70d1b0697598
    │   ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: OracleDecimalsMismatchTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], value: 10000000000000000000000000 [1e25])
    │   └─ ← [Return] 1891 bytes of code
    ├─ [0] VM::startPrank(ECRecover: [0x0000000000000000000000000000000000000001])
    │   └─ ← [Return]
    ├─ [4961326] → new AdvancedPaymentProcessor@0x535B3D7A252fa034Ed71F0C53ec0C6F784cB64E1
    │   └─ ← [Return] 24443 bytes of code
    ├─ [22785] PaymentProcessorStorage::setAuthorizedAddress(AdvancedPaymentProcessor: [0x535B3D7A252fa034Ed71F0C53ec0C6F784cB64E1], true)
    │   └─ ← [Stop]
    ├─ [23772] AdvancedPaymentProcessor::setPriceFeed(MockUsdc: [0xc7183455a4C133Ae270771860664b6B7ec320bB1], PriceFeedConfig({ aggregator: 0x2e234DAe75C793f67A35089C9d99245E1C58470b, heartbeat: 86400 [8.64e4] }))
    │   ├─ [327] PaymentProcessorStorage::owner() [staticcall]
    │   │   └─ ← [Return] ECRecover: [0x0000000000000000000000000000000000000001]
    │   └─ ← [Stop]
    ├─ [23772] AdvancedPaymentProcessor::setPriceFeed(MockWbtc: [0xa0Cb889707d426A7A386870A03bc70d1b0697598], PriceFeedConfig({ aggregator: 0xF62849F9A0B5Bf2913b396098F7c7019b51A820a, heartbeat: 86400 [8.64e4] }))
    │   ├─ [327] PaymentProcessorStorage::owner() [staticcall]
    │   │   └─ ← [Return] ECRecover: [0x0000000000000000000000000000000000000001]
    │   └─ ← [Stop]
    ├─ [23772] AdvancedPaymentProcessor::setPriceFeed(0x0000000000000000000000000000000000000000, PriceFeedConfig({ aggregator: 0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9, heartbeat: 86400 [8.64e4] }))
    │   ├─ [327] PaymentProcessorStorage::owner() [staticcall]
    │   │   └─ ← [Return] ECRecover: [0x0000000000000000000000000000000000000001]
    │   └─ ← [Stop]
    ├─ [0] VM::stopPrank()
    │   └─ ← [Return]
    ├─ [24905] MockUsdc::mint(SHA-256: [0x0000000000000000000000000000000000000002], 100000000000000000000000 [1e23])
    │   ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: SHA-256: [0x0000000000000000000000000000000000000002], value: 100000000000000000000000 [1e23])
    │   └─ ← [Stop]
    ├─ [24905] MockUsdc::mint(RIPEMD-160: [0x0000000000000000000000000000000000000003], 100000000000000000000000 [1e23])
    │   ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: RIPEMD-160: [0x0000000000000000000000000000000000000003], value: 100000000000000000000000 [1e23])
    │   └─ ← [Stop]
    ├─ [24905] MockWbtc::mint(SHA-256: [0x0000000000000000000000000000000000000002], 100000000000000000000000 [1e23])
    │   ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: SHA-256: [0x0000000000000000000000000000000000000002], value: 100000000000000000000000 [1e23])
    │   └─ ← [Stop]
    ├─ [24905] MockWbtc::mint(RIPEMD-160: [0x0000000000000000000000000000000000000003], 100000000000000000000000 [1e23])
    │   ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: RIPEMD-160: [0x0000000000000000000000000000000000000003], value: 100000000000000000000000 [1e23])
    │   └─ ← [Stop]
    ├─ [0] VM::startPrank(SHA-256: [0x0000000000000000000000000000000000000002])
    │   └─ ← [Return]
    ├─ [24734] MockUsdc::approve(AdvancedPaymentProcessor: [0x535B3D7A252fa034Ed71F0C53ec0C6F784cB64E1], 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   ├─ emit Approval(owner: SHA-256: [0x0000000000000000000000000000000000000002], spender: AdvancedPaymentProcessor: [0x535B3D7A252fa034Ed71F0C53ec0C6F784cB64E1], value: 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   └─ ← [Return] true
    ├─ [24734] MockWbtc::approve(AdvancedPaymentProcessor: [0x535B3D7A252fa034Ed71F0C53ec0C6F784cB64E1], 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   ├─ emit Approval(owner: SHA-256: [0x0000000000000000000000000000000000000002], spender: AdvancedPaymentProcessor: [0x535B3D7A252fa034Ed71F0C53ec0C6F784cB64E1], value: 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   └─ ← [Return] true
    ├─ [0] VM::stopPrank()
    │   └─ ← [Return]
    ├─ [0] VM::startPrank(RIPEMD-160: [0x0000000000000000000000000000000000000003])
    │   └─ ← [Return]
    ├─ [24734] MockUsdc::approve(AdvancedPaymentProcessor: [0x535B3D7A252fa034Ed71F0C53ec0C6F784cB64E1], 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   ├─ emit Approval(owner: RIPEMD-160: [0x0000000000000000000000000000000000000003], spender: AdvancedPaymentProcessor: [0x535B3D7A252fa034Ed71F0C53ec0C6F784cB64E1], value: 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   └─ ← [Return] true
    ├─ [24734] MockWbtc::approve(AdvancedPaymentProcessor: [0x535B3D7A252fa034Ed71F0C53ec0C6F784cB64E1], 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   ├─ emit Approval(owner: RIPEMD-160: [0x0000000000000000000000000000000000000003], spender: AdvancedPaymentProcessor: [0x535B3D7A252fa034Ed71F0C53ec0C6F784cB64E1], value: 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   └─ ← [Return] true
    ├─ [0] VM::stopPrank()
    │   └─ ← [Return]
    ├─ [0] VM::prank(ECRecover: [0x0000000000000000000000000000000000000001])
    │   └─ ← [Return]
    ├─ [23438] AdvancedPaymentProcessor::setForwarderAddress(0x00000000000000000000000000000000000000a0)
    │   ├─ [327] PaymentProcessorStorage::owner() [staticcall]
    │   │   └─ ← [Return] ECRecover: [0x0000000000000000000000000000000000000001]
    │   └─ ← [Stop]
    ├─ [0] VM::prank(ECRecover: [0x0000000000000000000000000000000000000001])
    │   └─ ← [Return]
    ├─ [23514] Notes::setAuthorized(AdvancedPaymentProcessor: [0x535B3D7A252fa034Ed71F0C53ec0C6F784cB64E1], true)
    │   ├─ [327] PaymentProcessorStorage::owner() [staticcall]
    │   │   └─ ← [Return] ECRecover: [0x0000000000000000000000000000000000000001]
    │   └─ ← [Stop]
    └─ ← [Stop]

  [572461] OracleDecimalsMismatchTest::test_oracleDecimalsMismatchAllowsUnderpayment()
    ├─ [368041] → new MockV3Aggregator@0x1d1499e622D69689cdf9004d05Ec547d650Ff211
    │   └─ ← [Return] 1061 bytes of code
    ├─ [0] VM::prank(ECRecover: [0x0000000000000000000000000000000000000001])
    │   └─ ← [Return]
    ├─ [11172] AdvancedPaymentProcessor::setPriceFeed(MockUsdc: [0xc7183455a4C133Ae270771860664b6B7ec320bB1], PriceFeedConfig({ aggregator: 0x1d1499e622D69689cdf9004d05Ec547d650Ff211, heartbeat: 86400 [8.64e4] }))
    │   ├─ [2327] PaymentProcessorStorage::owner() [staticcall]
    │   │   └─ ← [Return] ECRecover: [0x0000000000000000000000000000000000000001]
    │   └─ ← [Stop]
    ├─ [2385] PaymentProcessorStorage::getNextInvoiceNonce() [staticcall]
    │   └─ ← [Return] 1
    ├─ [125395] AdvancedPaymentProcessor::createSingleInvoice(InvoiceCreationParam({ invoiceId: "1", seller: 0x0000000000000000000000000000000000000004, price: 10000000000 [1e10], escrowHoldPeriod: 0 }))
    │   ├─ [2332] PaymentProcessorStorage::getMarketplace() [staticcall]
    │   │   └─ ← [Return] OracleDecimalsMismatchTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496]
    │   ├─ [6208] PaymentProcessorStorage::updateInvoiceNonce(1)
    │   │   └─ ← [Return] 1
    │   ├─ [2402] PaymentProcessorStorage::getPaymentValidityDuration() [staticcall]
    │   │   └─ ← [Return] 604800 [6.048e5]
    │   ├─ emit InvoiceCreated(invoiceId: 47469337584846097524001829613972953296694151841621382088733192561 [4.746e64], invoice: Invoice({ invoiceNonce: 1, paidAt: 0, createdAt: 7200, releaseAt: 0, expiresAt: 612000 [6.12e5], state: 1, escrowHoldPeriod: 0, metaInvoiceId: 0, buyer: 0x0000000000000000000000000000000000000000, seller: 0x0000000000000000000000000000000000000004, escrow: 0x0000000000000000000000000000000000000000, paymentToken: 0x0000000000000000000000000000000000000000, amountPaid: 0, price: 10000000000 [1e10], balance: 0 }))
    │   └─ ← [Return] 47469337584846097524001829613972953296694151841621382088733192561 [4.746e64]
    ├─ [13442] AdvancedPaymentProcessor::getTokenValueFromUsd(MockUsdc: [0xc7183455a4C133Ae270771860664b6B7ec320bB1], 10000000000 [1e10]) [staticcall]
    │   ├─ [0] 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433::latestRoundData() [staticcall]
    │   │   └─ ← [Return] 1, 0, 0, 7200, 1
    │   ├─ [991] MockV3Aggregator::latestRoundData() [staticcall]
    │   │   └─ ← [Return] 1, 1000000000000000000 [1e18], 7200, 43200000 [4.32e7], 1
    │   ├─ [301] MockV3Aggregator::decimals() [staticcall]
    │   │   └─ ← [Return] 18
    │   ├─ [176] MockUsdc::decimals() [staticcall]
    │   │   └─ ← [Return] 6
    │   └─ ← [Return] 100000000 [1e8]
    ├─ [0] VM::assertLt(100000000 [1e8], 1000000 [1e6]) [staticcall]
    │   └─ ← [Revert] assertion failed: 100000000 >= 1000000
    └─ ← [Revert] assertion failed: 100000000 >= 1000000

Backtrace:
  at VM.assertLt
  at OracleDecimalsMismatchTest.test_oracleDecimalsMismatchAllowsUnderpayment

Suite result: FAILED. 0 passed; 1 failed; 0 skipped; finished in 2.56ms (386.14µs CPU time)

Ran 1 test suite in 1.30s (2.56ms CPU time): 0 tests passed, 1 failed, 0 skipped (1 total tests)

Failing tests:
Encountered 1 failing test in test/PaymentProcessor.t.sol:OracleDecimalsMismatchTest
[FAIL: assertion failed: 100000000 >= 1000000] test_oracleDecimalsMismatchAllowsUnderpayment() (gas: 572461)

Encountered a total of 1 failing tests, 0 tests succeeded

Tip: Run `forge test --rerun` to retry only the 1 failed test
```

## Comments

- All Chainlink USD/token feeds return 8-decimal answers on every supported chain, including L2s (Arbitrum, Optimism, Base). The 18-decimal Chainlink feeds are ETH-denominated pairs (e.g. stETH/ETH), not USD pairs — this contract only registers USD feeds, so the assumption is always satisfied. decimals() normalization is therefore unnecessary. _(Mar 26, 2026, 02:21 PM)_

---

# Invoice updates only in memory

**#8**

- Severity: Low
- Validity: Invalid

## Targets

- \_pay (AdvancedPaymentProcessor)

## Affected Locations

- **AdvancedPaymentProcessor.\_pay**: Single finding location

## Description

The function mutates critical invoice fields (`buyer`, `state`, `escrow`, `paidAt`, `balance`, `amountPaid`, `paymentToken`, `releaseAt`) on the `Invoice memory _i` parameter, but never commits those changes to storage inside `_pay`. Despite that, it creates the escrow contract, transfers tokens, inserts a release task into the heap, and emits `InvoicePaid` based on the in‑memory values. If the caller does not explicitly write the mutated struct back to storage after `_pay` returns, the on‑chain invoice remains in `CREATED` with no escrow or buyer while funds are already locked in the escrow and a heap task exists. This stale state enables the same invoice to be paid or cancelled again and can cause automated release processing to revert because storage still shows an unpaid invoice.

## Root cause

State transitions are applied to a `memory` struct and `_pay` never persists those changes to storage before performing external side effects.

## Impact

Payments can move funds into escrows and schedule releases while the canonical invoice state remains unchanged. This can orphan escrow balances, allow repeat payments or cancellations against an invoice that appears unpaid, and break or block automated release processing. The result is locked buyer funds and inconsistent accounting between the heap and invoice storage.

## Remediation

**Status:** Incomplete

### Explanation

Load the invoice into a storage reference and apply all state updates directly to storage, then persist any derived fields before performing escrow transfers or scheduling release logic, so the canonical invoice state reflects the payment. Use a checks‑effects‑interactions pattern to ensure storage mutations are finalized prior to any external side effects.

## Comments

- In Solidity, `memory` structs are passed to internal functions by reference (the stack holds a pointer to the memory allocation, not a copy). Modifications to `_i` inside `_pay` are directly visible via the caller's `i` variable after the call returns. Both callers of `_pay` — `payInvoice` and `_paySubInvoices` — explicitly commit the mutated struct with `invoices[id] = i` immediately after the call. There is no path where the state mutations are lost or left uncommitted. _(Mar 26, 2026, 02:23 PM)_
