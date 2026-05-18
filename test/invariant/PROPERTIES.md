# Invariant Properties

This file tracks the properties implemented in `test/invariant/invariant.t.sol`.

## Scope

- `SimplePaymentProcessor`
- `AdvancedPaymentProcessor`
- `PaymentProcessorStorage`
- `MultiSig`
- Handlers:
  - `test/invariant/handlers/SimplePaymentProcessorHandler.sol`
  - `test/invariant/handlers/AdvancedPaymentProcessorHandler.sol`
  - `test/invariant/handlers/MultiSigHandler.sol`

## Global Invariants

| Id | Invariant Function | Property |
| --- | --- | --- |
| INV-1 | `invariant_consistentId` | `sHandler.getTotalInvoiceCreated() + aHandler.getTotalSingleInvoiceCreated() == PaymentProcessorStorage.totalInvoiceCreated()` |
| INV-2 | `invariant_consistentMetaInvoiceId` | `aHandler.getTotalMetaInvoiceCreated() == advancedPaymentProcessor.totalMetaInvoiceCreated()` |

## Simple Processor State Invariants

| Id | Invariant Function | Property |
| --- | --- | --- |
| SIM-1 | `invariant_simpleInvoiceStateConsistency` | If `status` is `CREATED` or `CANCELLED`: `balance == 0`, `escrow == address(0)`, `buyer == address(0)` |
| SIM-2 | `invariant_simpleInvoiceStateConsistency` | If `status` is `PAID`: escrow exists, buyer exists, `balance == price`, and `escrow.balance == balance` |
| SIM-3 | `invariant_simpleInvoiceStateConsistency` | If `status` is `ACCEPTED`: `balance == price` and `escrow.balance == balance` |
| SIM-4 | `invariant_simpleInvoiceStateConsistency` | If `status` is `REJECTED`, `REFUNDED`, or `RELEASED`: `balance == 0` and escrow balance is zero when escrow exists |
| SIM-5 | `invariant_simpleInvoiceStateConsistency` | If `status` is `LOCKED`: `escrow != address(0)` and `escrow.balance == price` |

## Advanced Processor State Invariants

| Id | Invariant Function | Property |
| --- | --- | --- |
| ADV-1 | `invariant_advancedInvoiceStateConsistency` | If `state` is `CREATED` or `CANCELED`: `balance == 0`, `amountPaid == 0`, `escrow == address(0)`, `buyer == address(0)` |
| ADV-2 | `invariant_advancedInvoiceStateConsistency` | For non-created/non-canceled invoices: escrow exists, buyer exists, `amountPaid > 0`, and `balance <= amountPaid` |
| ADV-3 | `invariant_advancedInvoiceStateConsistency` | If `state` is `RELEASED`, `REFUNDED`, or `DISPUTE_SETTLED`: `balance == 0` |
| ADV-4 | `invariant_advancedInvoiceStateConsistency` | If `state` is `PAID`/`DISPUTED`/`DISPUTE_RESOLVED`/`DISPUTE_DISMISSED`/`LOCKED`: escrow asset balance equals invoice `balance` (ETH or ERC20) |
| ADV-5 | `invariant_advancedInvoiceStateConsistency` | If `state` is `LOCKED`: `balance > 0` (funds remain in escrow, not drained) |

## Meta-Invoice Invariants

| Id | Invariant Function | Property |
| --- | --- | --- |
| META-1 | `invariant_metaInvoicePriceConsistency` | `metaInvoice.price == sum(subInvoice.price where subInvoice.state != CANCELED)` |

## Processor Native Balance Invariants

| Id | Invariant Function | Property |
| --- | --- | --- |
| BAL-1 | `invariant_simpleProcessorNativeTokenBalanceIsAlwaysZero` | `address(simplePaymentProcessor).balance == 0` |
| BAL-2 | `invariant_advancedProcessorNativeTokenBalanceAlwaysZero` | `address(advancedPaymentProcessor).balance == 0` |

## MultiSig Invariants

| Id | Invariant Function | Property |
| --- | --- | --- |
| MSG-1 | `invariant_thresholdBounds` | `threshold >= 1 && threshold <= signerCount` always holds — threshold can never be zero or exceed the active signer set |
| MSG-2 | `invariant_executedStatusIsPermanent` | Once a transaction reaches `EXECUTED` status it never reverts to `PROPOSED`, `APPROVED`, or `CANCELED` |
| MSG-3 | `invariant_canceledStatusIsPermanent` | Once a transaction reaches `CANCELED` status it never transitions to any other state |
| MSG-4 | `invariant_validTransactionStatus` | Every tracked transaction has status in `{PROPOSED=1, APPROVED=2, EXECUTED=3, CANCELED=4}` — no other value is possible |

