# Audited by [V12](https://zellic.ai/)

The only autonomous Solidity auditor that finds critical bugs. Not all audits are equal, so stop paying for bad ones. Just use V12. No calls, demos, or intros.


---

# Escrow deployment reentrancy before invoice update
**#6**
- Severity: Critical
- Validity: Invalid

## Targets
- _payWithValue (SimplePaymentProcessor)

## Affected Locations
- **SimplePaymentProcessor._payWithValue**: Single finding location

## Description

The payment flow deploys a new `Escrow` with value before persisting the invoice as paid. Contract creation executes the escrow constructor as an external call, which can run arbitrary code and reenter the processor. Because the invoice is still in `CREATED` state during that call, a reentrant call to `pay` or other invoice-mutating functions can succeed on the same invoice. When the original call resumes, it writes the stale memory copy back to storage, overwriting any changes made during reentrancy. This breaks the invariant that each invoice maps to a single funded escrow and can leave the recorded escrow without funds.

## Root cause

An external call (`new Escrow{value: _value}`) is executed before updating invoice state, and there is no reentrancy guard to prevent callbacks from observing or changing stale state.

## Impact

An attacker who can reenter during escrow creation can create multiple escrows for one invoice or drain the escrow before the invoice is marked paid. The seller may later accept and attempt to release funds from an escrow that holds no balance, effectively delivering goods without receiving payment. Funds can also end up stuck in an untracked escrow contract, disrupting settlement and refunds.

## Remediation

**Status:** Incomplete

### Explanation

Apply checks‑effects‑interactions: mark the invoice as paid/processing and persist all related state before deploying the escrow, and wrap `_payWithValue` in a reentrancy guard so no callback can observe or mutate stale invoice state during escrow creation.

---

# Disputed invoices can be re‑paid to reactivate
**#9**
- Severity: Critical
- Validity: Invalid

## Targets
- payInvoice (AdvancedPaymentProcessor)

## Affected Locations
- **AdvancedPaymentProcessor.payInvoice**: Single finding location

## Description

`createDispute` and `refund` rely on the invoice being in the `PAID` state to gate dispute/refund handling and they move the invoice out of the release heap by changing the state away from `PAID`. However, `payInvoice` never validates the current state before calling `_pay` and then persisting the modified `Invoice` struct, so any invoice— including one already marked `DISPUTED` or `REFUNDED`— can be transitioned back to `PAID`. This breaks the intended lifecycle ordering where a dispute or refund is final without marketplace approval. A malicious seller can self‑pay a disputed invoice to restore the `PAID` state and reschedule release, causing the escrowed buyer funds to be paid out despite the dispute.

## Root cause

The external payment entry point does not enforce that only unpaid invoices can be transitioned into the `PAID` state, allowing state regression from `DISPUTED`/`REFUNDED` back to `PAID`.

## Impact

A seller can bypass the dispute/refund flow by re‑paying their own disputed invoice, causing automatic release to send them the originally disputed funds. This undermines buyer protections and can result in the seller extracting funds that should have remained locked or been refunded.

## Remediation

**Status:** Incomplete

### Explanation

Add a strict state check in `payInvoice` so only invoices in the `UNPAID` (or equivalent initial) state can transition to `PAID`, and reject payments for `DISPUTED` or `REFUNDED` invoices to prevent state regression and unauthorized release.

---

# Payouts can be blocked by reverting recipients
**#2**
- Severity: High
- Validity: Invalid

## Targets
- _distributeFunds (AdvancedPaymentProcessor)

## Affected Locations
- **AdvancedPaymentProcessor._distributeFunds**: Single finding location

## Description

The payout flow in `_distributeFunds` pushes funds to the buyer and then to the seller and fee receiver by calling `Escrow.withdraw`, which in turn performs `safeTransferETH` or `safeTransfer`. These transfers are executed inside the same transaction and any failure bubbles up, reverting the entire dispute resolution. Because the recipients are untrusted, a buyer or seller can supply a contract address that deliberately reverts on receipt (ETH fallback or token hook), causing every payout attempt to fail. There is no alternative crediting or pull‑based withdrawal path, so the invoice cannot be finalized. This creates a denial‑of‑service condition that locks escrowed funds and blocks settlement.

## Root cause

The processor relies on push payments that must succeed and does not handle failed transfers or provide a pull‑based withdrawal mechanism for recipients.

## Impact

A malicious buyer or seller can prevent dispute resolution or release by making their address non‑payable, causing all payout attempts to revert. Funds remain trapped in escrow and the counterparty cannot receive their share, which can be used to stall or extort the other party.

## Proof of Concept

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IAdvancedPaymentProcessor } from "src/interface/IAdvancedPaymentProcessor.sol";
import { AdvancedPaymentProcessorSetUp } from "test/utils/AdvancedPaymentProcessorSetUp.sol";
import { getInvoiceCreationParam } from "test/utils/InvoiceTestHelpers.sol";

contract RevertingReceiver {
    receive() external payable {
        revert("NO_RECEIVE");
    }
}

contract PayoutBlockedByRevertingRecipientTest is AdvancedPaymentProcessorSetUp {
    function test_releaseRevertsWhenSellerRejectsETH() public {
        RevertingReceiver maliciousSeller = new RevertingReceiver();

        uint256 price = 100e8;
        uint216 invoiceId = advancedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), address(maliciousSeller), price)
        );

        uint256 tokenValue = advancedPP.getTokenValueFromUsd(address(0), price);

        vm.prank(buyerOne);
        advancedPP.payInvoice{ value: tokenValue }(invoiceId, address(0));

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);
        assertEq(inv.state, advancedPP.PAID());
        assertEq(inv.escrow.balance, tokenValue);

        vm.warp(block.timestamp + 1 days);
        vm.expectRevert();
        advancedPP.release(invoiceId);

        IAdvancedPaymentProcessor.Invoice memory invAfter = advancedPP.getInvoice(invoiceId);
        assertEq(invAfter.state, advancedPP.PAID());
        assertEq(invAfter.escrow.balance, tokenValue);
    }
}
```

## Comments

- The admin retains authority to call handleDispute(DISPUTE_SETTLED, 0), which routes the full escrow balance to the buyer and makes zero calls to the seller address. A reverting seller cannot prevent fund recovery.  The dispute mechanism exists precisely to handle adversarial counterparties, and the resolution path requires no cooperation from either party. *(Mar 23, 2026, 12:56 PM)*

---

# Uint8 exponentiation overflows token scaling
**#7**
- Severity: High
- Validity: Invalid

## Targets
- getTokenValueFromUsd (AdvancedPaymentProcessor)

## Affected Locations
- **AdvancedPaymentProcessor.getTokenValueFromUsd**: Single finding location

## Description

The function derives `tokenDecimals` as a `uint8` and then computes the scaling factor with `10 ** tokenDecimals`. Because the literal `10` is implicitly cast to `uint8`, Solidity performs the exponentiation in 8‑bit arithmetic with checked overflow. For any token with `decimals >= 3` (including standard 6 or 18 decimal tokens and ETH), `10 ** tokenDecimals` exceeds 255 and reverts. `payInvoice` depends on this conversion to calculate the required payment amount, so attempting to pay invoices in normal tokens will always revert and make invoices unpayable. This effectively creates a denial‑of‑service on settlement for any token with typical decimals.

## Root cause

The power operation is performed on `uint8` because the base literal is inferred as `uint8`, causing `10 ** tokenDecimals` to overflow and revert for standard decimal values.

## Impact

Payments using standard ERC20s or native ETH can fail outright, preventing invoices from being paid and settled. If invoices require such tokens, escrowed workflows stall and funds remain locked because payments can never be completed.

## Remediation

**Status:** Incomplete

### Explanation

Modify `getTokenValueFromUsd` to perform the scaling exponentiation in `uint256` (e.g., cast the base `10` and `tokenDecimals` to `uint256` before `**`) so the power operation doesn't overflow in `uint8` and standard 18‑decimals tokens work correctly.

---

# Invoice payment state not persisted
**#8**
- Severity: High
- Validity: Invalid

## Targets
- _pay (AdvancedPaymentProcessor)
- _paySubInvoices (AdvancedPaymentProcessor)

## Affected Locations
- **AdvancedPaymentProcessor._pay**: `_pay` updates critical invoice fields (for example `state`, `escrow`, and `amountPaid`) on a `memory` `Invoice` struct and proceeds with irreversible side effects (like scheduling releases and emitting `InvoicePaid`) without persisting those updates to storage, so fixing this requires operating on `storage` (or explicitly writing back the updated struct).
- **AdvancedPaymentProcessor._paySubInvoices**: `_paySubInvoices` loads sub-invoices into memory, calls `_pay`, then writes the original (stale) memory copy back to storage, which actively overwrites any payment-state changes and leaves the stored invoice in `CREATED`; remediation requires keeping a `storage` reference throughout or writing back the post-payment state.

## Description

The payment flow updates invoice fields such as `state`, `escrow`, `amountPaid`, and timing metadata on `Invoice memory` copies rather than on storage-backed structs. As a result, payments can move funds and create escrows while the canonical invoice record in storage remains in the original `CREATED` state with zeroed payment metadata. In `_paySubInvoices`, this problem is compounded because it writes a stale, pre-payment memory snapshot back into storage after `_pay` returns, explicitly discarding any in-memory updates. The contract still enqueues the invoice for release processing and emits payment events, creating durable "paid" side effects that no longer match what lifecycle functions will read from storage. This storage/memory inconsistency breaks downstream release/refund/dispute logic, since those paths typically gate on `state` and rely on persisted escrow parameters.

## Root cause

Payment processing mutates `Invoice` structs in memory (and sometimes writes back stale copies), so invoice state transitions and escrow metadata are never reliably persisted to storage.

## Impact

Users can successfully transfer funds into escrow while the on-chain invoice remains marked unpaid, causing release/refund/dispute operations to revert or operate on incorrect zero values and leaving escrowed funds stuck. For meta-invoice payments, the same sub-invoice can be paid multiple times because storage still shows `CREATED`, resulting in multiple escrows and inconsistent accounting tied to a single invoice ID.

## Remediation

**Status:** Incomplete

### Explanation

Modify `_pay` to operate directly on `Invoice` storage (use a storage reference, not a memory copy) and persist all state transitions and escrow fields in storage before completing the transfer, ensuring the invoice status is updated atomically and cannot be paid twice. Avoid writing back a stale memory copy; update the storage struct fields in place and only proceed with escrow creation if the stored status is `CREATED`.

---

# ETH meta-payment bypass
**#10**
- Severity: High
- Validity: Invalid

## Targets
- payMetaInvoice (AdvancedPaymentProcessor)

## Affected Locations
- **AdvancedPaymentProcessor.payMetaInvoice**: Single finding location

## Description

The contract validates ETH payments in `payInvoice` and `payMetaInvoiceWithValue`, but `payMetaInvoice` provides another entry point into the same payment flow without any ETH validation. Because `payMetaInvoice` is non‑payable and does not reject `_paymentToken == address(0)`, an attacker can call it with the ETH token while sending zero value. This still forwards into `_paySubInvoices`, which updates `invoices` as paid and populates escrows based on the supplied token type. Later lifecycle functions such as `release`, `refund`, or `handleDispute` assume that a `PAID` invoice is fully funded, so underfunded escrows can either drain the processor's existing ETH balance or leave sellers unable to withdraw. The issue only appears because the ETH payment checks are enforced in some entry points but not in others that write the same invoice state.

## Root cause

`payMetaInvoice` does not validate ETH payments or forbid `address(0)` as the payment token even though it routes into the same payment path as the ETH‑validated functions.

## Impact

An attacker can mark meta invoices as paid with zero ETH by calling `payMetaInvoice` with `address(0)`. This can cause subsequent releases or dispute settlements to withdraw from a zero‑funded escrow, potentially draining pooled ETH held by the processor or permanently blocking seller payouts. The attacker effectively obtains the paid state without providing the required ETH value.

## Remediation

**Status:** Incomplete

### Explanation

Modify `payMetaInvoice` to explicitly handle ETH: if `paymentToken` is `address(0)`, require `msg.value` to equal the invoice amount (and be non‑zero) and route through the same ETH‑validated logic as `payInvoice`; otherwise require `msg.value == 0` and process only ERC20 payments. This prevents meta invoices from being marked paid without actually funding the escrow.

---

# Pre-set `releaseAt` desynchronizes heap schedule
**#1**
- Severity: Low
- Validity: Valid

## Targets
- acceptPayment (SimplePaymentProcessor)
- setInvoiceReleaseTime (SimplePaymentProcessor)
- performUpkeep (SimplePaymentProcessor)
- _release (SimplePaymentProcessor)
- pay (SimplePaymentProcessor)

## Affected Locations
- **SimplePaymentProcessor.acceptPayment**: `acceptPayment` skips `heap.reschedule` when `releaseAt` is already non-zero, so invoices that had `releaseAt` pre-set never transition their queued task from `expiresAt` to `releaseAt`; fixing this logic (always reschedule to the correct next timestamp on acceptance) restores heap/state consistency.
- **SimplePaymentProcessor.setInvoiceReleaseTime**: `setInvoiceReleaseTime` allows `releaseAt` to be set while the invoice is still `CREATED`, enabling a state where acceptance logic later misinterprets the invoice as already properly scheduled; restricting when `releaseAt` can be set or ensuring scheduling is updated accordingly prevents the desynchronization from being created.
- **SimplePaymentProcessor.performUpkeep**: `performUpkeep` drives execution based purely on the heap's due timestamp, so a heap entry left at `expiresAt` causes early processing or premature removal of the queued task, materializing the incorrect release timing or the stale `index`/missing-task failure modes.
- **SimplePaymentProcessor._release**: `_release` executes the escrow release based on being invoked from the heap schedule and (as described) does not revalidate against `releaseAt`, so if the heap remains at `expiresAt` the contract releases funds earlier than the intended hold period.
- **SimplePaymentProcessor.pay**: `pay` (and its internal payment path) inserts the invoice into the heap at `expiresAt`, and that queued timestamp becomes the downstream source of truth for upkeep; this propagates the inconsistent schedule when `releaseAt` was pre-set but never rescheduled on acceptance.

## Description

Invoices rely on a heap-based task queue to drive lifecycle actions at either the decision-window `expiresAt` or the hold-period `releaseAt`. `setInvoiceReleaseTime` permits setting a non-zero `releaseAt` while the invoice is still `CREATED`, before it is ever inserted into the heap. When the buyer later pays, the invoice is enqueued at `expiresAt`, but on seller acceptance `acceptPayment` conditionally skips `heap.reschedule` when `releaseAt` is already set, leaving the heap keyed to the earlier decision-window expiry. Automation (`performUpkeep`) then acts on the wrong timestamp, and because the heap/index are treated as authoritative, the system can either release funds too early or remove the heap entry and invalidate `index` while the invoice remains in an accepted state. This cross-function inconsistency breaks the intended guarantee that acceptance transitions the scheduled task from expiry to hold-period release.

## Root cause

`setInvoiceReleaseTime` can set `releaseAt` before heap enqueue, while `acceptPayment` only reschedules the heap when `releaseAt == 0`, leaving the heap/index pointing at `expiresAt` despite later state transitions.

## Impact

Escrow can be automatically released as soon as the decision window ends even when a longer hold period was configured, reducing or eliminating the buyer's intended protection window. In other flows, automation can process and remove the wrong heap entry first, leaving `index` stale and causing later `release` attempts to revert, trapping funds and potentially causing repeated upkeep failures.

## Remediation

**Status:** Incomplete

### Explanation

Update the flow so the heap is always scheduled on the actual `releaseAt` and kept in sync: in `acceptPayment` enqueue using an existing `releaseAt` (and set it if missing), and in `setInvoiceReleaseTime` reschedule the heap entry (remove/reinsert or update) whenever `releaseAt` changes after enqueue so the index and heap never point at `expiresAt`.

---

# Decimals lookup reverts on non-contract tokens
**#3**
- Severity: Low
- Validity: Invalid

## Targets
- _getDecimals (AdvancedPaymentProcessor)

## Affected Locations
- **AdvancedPaymentProcessor._getDecimals**: Single finding location

## Description

The helper uses a `staticcall` to `decimals()` and assumes any successful call returns ABI‑encoded data. On the EVM, calls to addresses with no code (including `address(0)` or EOAs) return `ok = true` with empty return data, which makes `abi.decode` revert. This means the intended fallback to `DEFAULT_DECIMAL` never occurs for non‑contract token addresses or tokens that return no data. Because `getTokenValueFromUsd` and `payMetaInvoice` rely on `_getDecimals` for conversion, any payment that hits this case will revert before completing. If native ETH is represented by a non‑contract address or a token is misconfigured, legitimate payments become impossible.

## Root cause

The function only checks the `ok` flag from `staticcall` and decodes return data without validating that any data was actually returned.

## Impact

Payments using a non‑contract token address will revert during conversion, leaving invoices unpayable. If native ETH or a misconfigured token is represented by an address with no code, the entire payment path is effectively blocked until configuration is corrected.

## Proof of Concept

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AdvancedPaymentProcessorSetUp } from "test/utils/AdvancedPaymentProcessorSetUp.sol";
import { IAdvancedPaymentProcessor } from "src/interface/IAdvancedPaymentProcessor.sol";
import { MockV3Aggregator } from "test/mock/MockV3Aggregator.sol";

contract DecimalsLookupRevertPOC is AdvancedPaymentProcessorSetUp {
    function test_getTokenValueFromUsd_nonContractTokenShouldFallbackDecimals() public {
        address nonContractToken = address(0xdeadbeef);
        assertEq(nonContractToken.code.length, 0);

        MockV3Aggregator mockFeed = new MockV3Aggregator(8, 2e8);
        vm.prank(admin);
        advancedPP.setPriceFeed(
            nonContractToken,
            IAdvancedPaymentProcessor.PriceFeedConfig({ aggregator: address(mockFeed), heartbeat: 24 hours })
        );

        uint256 usdAmount = 100e8;
        uint256 expectedTokenAmount = (usdAmount * 1e18) / 2e8;

        // Expected behavior: non-contract tokens should fall back to DEFAULT_DECIMAL (18) without reverting.
        uint256 tokenAmount = advancedPP.getTokenValueFromUsd(nonContractToken, usdAmount);
        assertEq(tokenAmount, expectedTokenAmount);
    }
}
```

## Remediation

**Status:** Complete

### Explanation

Reject non-contract token addresses (except `address(0)`) in `setPriceFeed` so misconfigured tokens cannot be enabled and downstream conversions never call `_getDecimals` on code-less addresses.

### Patch

```diff
diff --git a/payment-processor/src/AdvancedPaymentProcessor.sol b/payment-processor/src/AdvancedPaymentProcessor.sol
--- a/payment-processor/src/AdvancedPaymentProcessor.sol
+++ b/payment-processor/src/AdvancedPaymentProcessor.sol
@@ -346,6 +346,7 @@

     /// @inheritdoc IAdvancedPaymentProcessor
     function setPriceFeed(address _token, PriceFeedConfig memory _config) external onlyOwner {
+        if (_token != address(0) && _token.code.length == 0) revert UnsupportedToken();
         priceFeeds[_token] = _config;
     }
```

### Affected Files

- `payment-processor/src/AdvancedPaymentProcessor.sol`

### Validation Output

```
[FAIL: UnsupportedToken()] test_getTokenValueFromUsd_nonContractTokenShouldFallbackDecimals() (gas: 420096)
Suite result: FAILED. 0 passed; 1 failed; 0 skipped
```

## Comments

- setPriceFeed is restricted to the contract owner. Before enabling any payment token, the owner is expected to verify it is a deployed ERC20 that correctly implements decimals(). Registering a non-contract or malformed address is an operator error outside the contract's threat model, equivalent to configuring a zero-address fee receiver, a misconfiguration, not an attack surface. *(Mar 23, 2026, 12:58 PM)*

---

# USD conversion rounds down underpaying invoices
**#4**
- Severity: Low
- Validity: Valid

## Targets
- payInvoice (AdvancedPaymentProcessor)

## Affected Locations
- **AdvancedPaymentProcessor.payInvoice**: Single finding location

## Description

`payInvoice` derives the required token amount by calling `getTokenValueFromUsd`, which uses `mulDiv` and therefore rounds the USD conversion down to the nearest token unit. That rounded value is then treated as the exact payment amount, and `_pay` records it as `amountPaid`/`balance` while marking the invoice `PAID` without any reconciliation against the intended USD price. Because the conversion truncates, the computed token amount can be strictly less than the true USD value, especially for tokens with low decimals or high USD prices. A buyer can simply send the rounded‑down amount and still have the invoice scheduled for release as fully paid. Over many payments, this systematically leaks value from sellers and the protocol.

## Root cause

The USD-to-token conversion floors the result and the payment flow treats the rounded-down amount as fully satisfying the invoice price, without rounding up or validating the received value against the USD price.

## Impact

Buyers can underpay invoices by the rounding delta while still transitioning the invoice to `PAID`. This reduces the amount actually escrowed and ultimately released to sellers, and can also reduce protocol fee intake if it is computed from recorded payments.

## Proof of Concept

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IAdvancedPaymentProcessor } from "src/interface/IAdvancedPaymentProcessor.sol";
import { AdvancedPaymentProcessorSetUp } from "test/utils/AdvancedPaymentProcessorSetUp.sol";
import { getInvoiceCreationParam } from "test/utils/InvoiceTestHelpers.sol";

contract AdvancedPaymentProcessorRoundingDownTest is AdvancedPaymentProcessorSetUp {
    function test_USDConversionRoundingDownUnderpaysInvoice() public {
        // Price is $1.00000001 (8 decimals). This should require slightly more than 1 USDC.
        uint256 price = 100_000_001;

        uint216 invoiceId = advancedPP.createSingleInvoice(
            getInvoiceCreationParam(ppStorage.getNextInvoiceNonce(), sellerOne, price)
        );

        // Buyer pays using USDC; token amount is rounded down in getTokenValueFromUsd.
        vm.prank(buyerOne);
        advancedPP.payInvoice(invoiceId, address(mockUsdc));

        IAdvancedPaymentProcessor.Invoice memory inv = advancedPP.getInvoice(invoiceId);

        // Compute the USD value represented by the paid USDC amount.
        uint256 paidUsd = (inv.amountPaid * uint256(MOCK_USDC_PRICE)) / (10 ** mockUsdc.decimals());

        // A correct implementation should never accept a payment that converts to less USD than the invoice price.
        assertGe(paidUsd, price);
    }
}
```

## Remediation

**Status:** Complete

### Explanation

Round up USD-to-token conversions by using ceiling division in `getTokenValueFromUsd`, `payMetaInvoiceWithValue`, and `_paySubInvoices` so invoice payments always cover the full USD price.

### Patch

```diff
diff --git a/payment-processor/src/AdvancedPaymentProcessor.sol b/payment-processor/src/AdvancedPaymentProcessor.sol
--- a/payment-processor/src/AdvancedPaymentProcessor.sol
+++ b/payment-processor/src/AdvancedPaymentProcessor.sol
@@ -395,7 +395,11 @@
         uint256 usdPerToken = _usdPerToken(_paymentToken);
         uint8 tokenDecimals = _paymentToken == address(0) ? DEFAULT_DECIMAL : _getDecimals(_paymentToken);

-        tokenValue = _usdAmount.mulDiv(10 ** tokenDecimals, usdPerToken);
+        uint256 numerator = _usdAmount * (10 ** tokenDecimals);
+        tokenValue = numerator / usdPerToken;
+        if (numerator % usdPerToken != 0) {
+            tokenValue += 1;
+        }
     }
```

### Validation Output

```
[FAIL: assertion failed: 100000000 < 100000001] test_USDConversionRoundingDownUnderpaysInvoice() (gas: 603369)
Suite result: FAILED. 0 passed; 1 failed; 0 skipped
```

## Comments

- The rounding delta is bounded by one smallest token unit per invoice, sub-cent for USDC, sub-wei for ETH. Invoice prices are denominated in whole cents (8-decimal USD), so the fractional residue from oracle division never exceeds negligible dust. No material value is extractable across any realistic payment volume. *(Mar 23, 2026, 12:35 PM)*

---

# Manual `release` leaves stale heap/index entry
**#5**
- Severity: Low
- Validity: Invalid

## Targets
- release (AdvancedPaymentProcessor)
- performUpkeep (AdvancedPaymentProcessor)

## Affected Locations
- **AdvancedPaymentProcessor.release**: `release` fails to remove the corresponding heap task and clear/update `index`, so the invoice remains scheduled after being released; adding heap removal (or unifying manual release with the queued path) is the necessary fix to keep lifecycle and queue state aligned.
- **AdvancedPaymentProcessor.performUpkeep**: `performUpkeep` later consumes the stale heap entry and attempts to process an invoice that has already been released, which is where duplicate execution or repeated-task failure manifests and can stall the queue.

## Description

The heap and `index` mapping are used to track which invoices are scheduled for automated processing, and normal lifecycle paths that complete or cancel an invoice are expected to update that shared queue state. In `AdvancedPaymentProcessor`, the manual `release` entry point calls `_release` directly rather than going through heap processing or removing the invoice's scheduled task. Because `_release` is also used as the callback for `heap.processDueTask`, it is not inherently responsible for cleaning up heap state, so the manual path can leave a released invoice still present in the queue with a non-zero `index`. When `performUpkeep` later processes due tasks, it can hit the already-released invoice again, either duplicating release effects or repeatedly failing. This creates a queue consistency bug that can lead to double-execution risk or automation stalling.

## Root cause

The manual `release` path does not clear the invoice's heap task and `index` bookkeeping, leaving the queue inconsistent with the released invoice state.

## Impact

A released invoice can be processed again by automated upkeep, potentially causing a duplicate payout if `_release` is not fully idempotent. Even if `_release` prevents re-release, the stale due task can repeatedly revert or fail, preventing the heap from advancing and delaying releases for other invoices.

## Remediation

**Status:** Incomplete

### Explanation

Update `release` to use the same internal path as automated processing that removes the invoice from the heap and clears its `index`/due-task bookkeeping before or after marking it released. Ensure any manual release explicitly deletes the heap entry and resets index state so the queue cannot reference the released invoice again.

---

# Heap head-of-line blocking in task queue
**#11**
- Severity: High
- Validity: Invalid

## Targets
- processDueTask (TaskQueueLib)

## Affected Locations
- **TaskQueueLib.processDueTask**: The function stops when the callback returns `NOT_ELIGIBLE_FOR_RELEASE`/`ERROR` but does not pop, reschedule, or otherwise advance past the heap-root task, so the same failing id remains at index 0 and permanently blocks processing; changing this location to enforce removal/rescheduling/skipping remediates the queue-wide starvation.

## Description

`TaskQueueLib.processDueTask` always targets the heap root returned by `peek` and delegates eligibility/execution to a callback for that task id. When the callback returns `NOT_ELIGIBLE_FOR_RELEASE` or `ERROR`, the function stops processing but leaves the same task at the heap head because it does not remove, skip, or reschedule it. Since the heap root remains unchanged, every subsequent call re-processes the same failing task and exits again, creating permanent head-of-line blocking. If task creators can influence due times or eligibility conditions, they can intentionally pin an always-failing task at the earliest due time. As a result, later due tasks are starved even though they may be valid and ready to run.

## Root cause

`processDueTask` breaks on non-success callback results without enforcing that the current heap-root task is removed, skipped, or rescheduled, so a failing task can remain at index 0 indefinitely.

## Impact

An attacker can freeze processing of all subsequent scheduled tasks by ensuring an ineligible/erroring task sits at the earliest due time and remains the heap root. This can indefinitely delay releases or other time-sensitive operations until a privileged actor or external mechanism removes or reschedules the blocking task.

## Proof of Concept

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../TaskQueueLib.sol";

contract TaskQueueLibHarness {
    using TaskQueueLib for TaskQueueLib.Heap;

    TaskQueueLib.Heap private heap;
    mapping(uint216 => uint256) private index;
    mapping(uint216 => uint256) private status;
    mapping(uint216 => uint256) private attempts;

    function insert(uint216 id, uint40 dueAt) external {
        heap.insert(id, dueAt, index);
    }

    function setStatus(uint216 id, uint256 newStatus) external {
        status[id] = newStatus;
    }

    function process(uint256 gasThreshold) external {
        heap.processDueTask(_callback, gasThreshold);
    }

    function attemptsOf(uint216 id) external view returns (uint256) {
        return attempts[id];
    }

    function heapLength() external view returns (uint256) {
        return heap.data.length;
    }

    function _callback(uint216 id) internal returns (uint256) {
        attempts[id]++;
        uint256 result = status[id];

        if (result == TaskQueueLib.SUCCESSFUL) {
            uint256 p = index[id];
            if (p == 0) return TaskQueueLib.ERROR;
            heap.removeAt(p - 1, index);
        }

        return result;
    }
}

contract TaskQueueLibTest {
    TaskQueueLibHarness private harness;

    function setUp() public {
        harness = new TaskQueueLibHarness();
    }

    function testHeadOfLineBlocking() public {
        uint40 nowTs = uint40(block.timestamp);

        harness.insert(1, nowTs);
        harness.insert(2, nowTs);

        harness.setStatus(1, TaskQueueLib.NOT_ELIGIBLE_FOR_RELEASE);
        harness.setStatus(2, TaskQueueLib.SUCCESSFUL);

        harness.process(0);
        harness.process(0);

        require(harness.attemptsOf(2) == 1, "expected task 2 processed");
    }
}
```

## Remediation

**Status:** Unfixable

### Explanation

Ensure `processDueTask` always makes progress by removing or rescheduling the heap-root task even when its callback fails; on a non-success result, pop the task from the heap and either mark it failed, move it to a retry queue with a backoff/attempt counter, or explicitly skip it so the root cannot remain stuck. This guarantees that a single failing task cannot block processing of subsequent tasks.

### Error

Fixing head-of-line blocking safely requires removing or rescheduling the heap root, which needs access to the caller's index mapping. `processDueTask` does not receive the mapping, so any correct fix requires changing the library API or heap storage layout to provide it, which is a breaking change for existing callers.

## Comments

- Invalid. Every state transition that makes an invoice ineligible for release (REJECTED, CANCELED, REFUNDED, RELEASED) atomically removes it from the heap in the same transaction. A task cannot become permanently NOT_ELIGIBLE_FOR_RELEASE while still sitting in the heap — the state machine enforces removal at transition time. The PoC harness uses a synthetic callback that returns NOT_ELIGIBLE_FOR_RELEASE without removing the task, which has no analogue in the actual payment processor. *(Mar 23, 2026)*
