# Sapphire DAO Payment Processor

Foundry-based smart contracts for Sapphire DAO that support escrowed invoice flows. Two processors are provided:

1. `SimplePaymentProcessor` — native ETH invoices with seller decision window.
2. `IntermediatedPaymentProcessor` — ERC20 + native payments, USD pricing via Chainlink, disputes, and meta-invoices.

**Quick facts**

- Solidity: `0.8.28`
- Escrow model: one escrow per invoice, deployed via CREATE3
- Scheduler: min-heap (`TaskQueueLib`) with gas-aware processing
- Automation: Chainlink CRE workflow (`hasDueTasks` read + `onReport` write via the CRE forwarder, see `cre/`)
- Oracle: standalone `OracleManager` with sequencer uptime and heartbeat validation

## Contract Map

- `src/SimplePaymentProcessor.sol`
  - Native ETH invoices.
  - Seller decision window; scheduled release/refund via heap.
  - Manual `release` and `refundBuyer` paths.
  - `releaseLocked` for admin recovery of stuck funds.
  - Optional encrypted notes via `Notes`.
- `src/IntermediatedPaymentProcessor.sol`
  - ERC20 and native ETH payments.
  - USD pricing via `OracleManager` (Chainlink aggregators).
  - Single invoices, meta-invoices (batch), disputes, partial refunds.
  - `releaseLocked` for admin recovery of LOCKED invoices.
- `src/OracleManager.sol`
  - Standalone price-feed manager referenced by `IntermediatedPaymentProcessor`.
  - Validates sequencer uptime (L2 grace period) and feed heartbeat.
  - Ownership delegated to `PaymentProcessorStorage.owner()`.
- `src/PaymentProcessorStorage.sol`
  - Shared configuration: fee receiver, fee rate, default hold period, gas threshold, marketplace, and authorization list.
  - Ownable; authorizes processor contracts.
- `src/Escrow.sol`
  - Minimal per-invoice escrow; only the payment processor can withdraw.
  - Zero-amount withdrawals succeed without performing a transfer.
- `src/EscrowFactory.sol`
  - Deterministic escrow deployment via CREATE3.
- `src/Notes.sol`
  - Stores encrypted note content per invoice.
  - Per-note `share` flag controls public readability; `opened` mapping tracks whether an account has viewed a note.
- `src/libraries/TaskQueueLib.sol`
  - Binary min-heap keyed by `(invoiceId, dueTime)`.
  - `processDueTask` removes stale entries on `ERROR` / `NOT_ELIGIBLE_FOR_RELEASE` and continues, preventing queue stalls.
  - `getItems` returns IDs in heap order (linear scan, no sort).
- Interfaces in `src/interface/`.
- Constants in `src/constants/`.

## Architecture Overview

1. **Invoice creation**
   - Simple: seller calls `createInvoice` (price in wei).
   - Intermediated: marketplace calls `createSingleInvoice` or `createMetaInvoice` (price in USD, 8 decimals).

2. **Payment**
   - Buyer pays; a dedicated `Escrow` is deployed via CREATE3 and receives the funds.
   - Intermediated processor converts USD price to token amount via `OracleManager`.

3. **Decision + release**
   - Simple: seller has a configurable decision window to `acceptPayment` or `rejectPayment`.
   - Intermediated: marketplace handles disputes via `createDispute` / `handleDispute`.
   - A hold period delays release after acceptance; expiry is tracked in the heap.

4. **Automation (Chainlink CRE)**
   - A CRE workflow (`cre/`) runs on a cron trigger and reads `hasDueTasks()`; when a task is due it submits a report onchain.
   - The CRE forwarder delivers the verified report via `onReport`, which drains due tasks within a gas threshold.
   - `onReport` only accepts the configured forwarder (`setForwarderAddress`) and workflow owner (`setWorkflowOwner`).
   - `processDueTasks` is an owner-only manual fallback for the same processing loop.
   - Failed withdrawals are retried up to `MAX_WITHDRAWAL_RETRIES`; after exhaustion the invoice transitions to `LOCKED`.

5. **Recovery**
   - `releaseLocked` allows the owner to recover funds from a `LOCKED` invoice to any recipient.

## Invoice State Machines

**SimplePaymentProcessor**
```
CREATED → PAID → ACCEPTED → RELEASED
                           → LOCKED (retry exhausted)
               → REJECTED  (seller rejects)
               → REFUNDED  (decision window expired)
         → REFUNDED        (buyer refund after expiry)
         → LOCKED          (refund retry exhausted)
```

**IntermediatedPaymentProcessor**
```
CREATED → PAID → RELEASED           (automated or manual)
               → REFUNDED           (automated refund)
               → LOCKED             (retry exhausted)
               → DISPUTED → DISPUTE_RESOLVED → RELEASED
                          → DISPUTE_SETTLED
                          → DISPUTE_DISMISSED → RELEASED
```

## Key Behaviors

- **Fees** — Calculated in basis points against the invoice price; sent to `feeReceiver`. In automated paths, a failed fee transfer emits `TransferFailed` but does not revert (best-effort to avoid head-of-line blocking). In manual `release`, a failed fee transfer reverts.
- **Meta-invoices** — Batch of sub-invoices settled in a single call. Sub-invoices whose USD→token conversion rounds to zero are skipped (not reverted).
- **Access control** — Storage owner manages configuration. `IntermediatedPaymentProcessor` restricts invoice creation and dispute handling to the marketplace address. `OracleManager` writes are restricted to the storage owner.
- **Heartbeat validation** — `OracleManager.setPriceFeed` rejects a heartbeat of 0 when registering a live aggregator. Pass `aggregator = address(0)` to remove a token.
- **Notes** — `Notes` stores encrypted ciphertext. Notes with `share = true` are readable by any caller; the `opened` mapping tracks read status per account.

## Configuration

`PaymentProcessorStorage` holds shared config:

| Field | Description |
|---|---|
| `feeReceiver` | Destination for protocol fees |
| `feeRate` | Fee in basis points (e.g. 500 = 5%) |
| `defaultHoldPeriod` | Escrow hold time after acceptance (seconds) |
| `gasThreshold` | Minimum gas to keep processing the heap in `onReport` / `processDueTasks` |
| `marketplace` | Authorized caller for Intermediated processor invoice/dispute functions |
| `authorized` | Allowlist for restricted storage writes |

`OracleManager` must have a `PriceFeedConfig` registered for each payment token (including `address(0)` for native ETH) before the Intermediated processor can accept payments.

## Using the Simple Processor

```
1. Seller   → createInvoice(price, storageRef, share)
2. Buyer    → pay{value: price}(invoiceId, storageRef, share)
3. Seller   → acceptPayment(invoiceId)           // or rejectPayment
4. Auto     → CRE workflow → onReport(...)       // releases after hold period
   — or —
   Seller   → release(invoiceId)                 // manual release after hold period
   Buyer    → refundBuyer(invoiceId)             // if decision window expired
```

## Using the Intermediated Processor

```
1. Marketplace → createSingleInvoice(param)
               → createMetaInvoice(params[])
2. Buyer       → payInvoice(invoiceId, token)
               → payMetaInvoice(metaId, token)
               → payMetaInvoiceWithValue(metaId)  // ETH
3. Marketplace → createDispute(invoiceId)          // if disputed
               → handleDispute(invoiceId, resolution, sellerShare)
4. Auto        → CRE workflow → onReport(...)      // releases after hold period
   — or —
   Marketplace → release(invoiceId)                // manual release
```

Price feeds must be configured with `OracleManager.setPriceFeed` before ERC20 payments.

## Getting Started

Prerequisites: [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
# Clone the repo
git clone git@github.com:SapphireDAOO/payment-processor.git
cd payment-processor

# Install dependencies
forge install

# Run tests
forge test

# Format code
forge fmt
```

## Tests

- Unit tests in `test/unit/` — per-contract coverage including edge cases, retry paths, and LOCKED recovery.
- Invariant tests in `test/invariant/` — property-based fuzzing over invoice state machines.
- Harness contracts in `test/harness/` — thin wrappers exposing internal library functions for direct testing.
- Mocks in `test/mock/` — ERC20 tokens and Chainlink `MockV3Aggregator`.

## Static Analysis (Slither)

Prerequisite: [Slither](https://github.com/crytic/slither) installed.

```bash
slither . --exclude-dependencies --json slither-report.json
```

**Known Slither annotations for this repo**

- `incorrect-equality` — comparisons are against explicit state constants or zero-initialized fields.
- `locked-ether` — `PaymentProcessorStorage` intentionally has no ETH receive path.
- `uninitialized-local` — local structs default to zero and are fully assigned before use.
- `unused-return` — return values are intentionally ignored where only side effects matter (e.g. best-effort fee collection in automated paths).
- `calls-loop` — external calls occur in bounded loops (meta-invoice sub-invoices) and are expected.
- `reentrancy-benign` / `reentrancy-events` — `onReport` / `processDueTasks` and all pay functions are `nonReentrant`; remaining automated paths are reachable only through those guards.
- `timestamp` — time-based expiry and release logic is core to invoice lifecycle.
- `pragma` — dependencies use `^0.8.4` but compile cleanly with `0.8.28`.
- `dead-code` — `_release` is referenced via function pointer in `TaskQueueLib.processDueTask`, which Slither does not resolve.
- `naming-convention` — leading-underscore parameters are a project style choice.
- `too-many-digits` — false positive on generated bytecode literals.

## Operational Notes

- Authorize each processor in `PaymentProcessorStorage` before deployment goes live.
- Register a `PriceFeedConfig` in `OracleManager` for every ERC20 token and for `address(0)` (native ETH) before enabling Intermediated processor payments.
- Set the CRE forwarder (`setForwarderAddress`) and authorized workflow owner (`setWorkflowOwner`) on the Simple processor before deploying the workflow in `cre/`; `onReport` rejects every other caller.
- Set `gasThreshold` conservatively; too low a value causes `onReport` / `processDueTasks` to process more invoices per call than intended.
- Monitor `TransferFailed` events from automated release paths — a blocked fee receiver will silently skip fee collection until the address is updated.
- Use `releaseLocked` to recover funds from any invoice stuck in the `LOCKED` state.