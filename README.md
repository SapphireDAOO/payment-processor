# Sapphire DAO Payment Processor

Foundry-based smart contracts for Sapphire DAO that support escrowed invoice flows. Two processors are provided:

1. `SimplePaymentProcessor` for native ETH only.
2. `AdvancedPaymentProcessor` for ERC20 + price-feed based USD pricing and disputes.

This repo focuses on on-chain payment state, escrow, and automated release/refund scheduling.

**Quick facts**

- Solidity: `0.8.28`
- Escrow model: one escrow per invoice
- Scheduler: min-heap (`TaskQueueLib`) with gas-aware processing
- Automation: Chainlink Automation compatible (`checkUpkeep`/`performUpkeep`)

## Contract Map

- `src/SimplePaymentProcessor.sol`
  - Native ETH invoices.
  - Seller decision window and hold period with scheduled release/refund.
  - Optional encrypted notes via `Notes`.
- `src/AdvancedPaymentProcessor.sol`
  - ERC20 and native payments.
  - USD pricing via Chainlink aggregators.
  - Meta invoices (batch), disputes, partial refunds.
- `src/PaymentProcessorStorage.sol`
  - Shared configuration: fee receiver, fee rate, default hold period, gas threshold, marketplace, and authorization.
  - Ownable.
- `src/Escrow.sol`
  - Minimal escrow that only allows the payment processor to withdraw funds.
- `src/EscrowFactory.sol`
  - Deterministic escrow deployment via CREATE3.
- `src/libraries/TaskQueueLib.sol`
  - Binary min-heap keyed by `(invoiceId, dueTime)`.
- Interfaces in `src/interface/*`.

## Architecture Overview

1. **Invoice creation**
   - Simple: seller creates invoice (price in wei).
   - Advanced: marketplace creates invoice (price in USD, 8 decimals).

2. **Payment**
   - Buyer pays invoice.
   - Escrow is deployed deterministically and receives funds.

3. **Decision + release**
   - Simple: seller accepts or rejects within a decision window.
   - Advanced: marketplace handles disputes and resolves releases.
   - A hold period delays release; when due, a task is scheduled in the heap.

4. **Automation**
   - `checkUpkeep` indicates if any task is due.
   - `performUpkeep` processes due tasks with a gas threshold to avoid OOG.

## Key Behaviors

- **Invoices**
  - Simple: `CREATED -> PAID -> ACCEPTED/REJECTED -> RELEASED/REFUNDED`
  - Advanced: `CREATED -> PAID -> (DISPUTED/RESOLVED/SETTLED/DISMISSED) -> RELEASED`
- **Fees**
  - Calculated in basis points and sent to `feeReceiver`.
- **Access control**
  - Storage owner manages configuration and authorizes processor contracts.
  - Advanced processor restricts creation/management to the marketplace address.
- **Notes**
  - `Notes` stores encrypted references and optional shareability flags.

## Configuration

`PaymentProcessorStorage` holds config used by both processors:

- `feeReceiver`: destination for fees.
- `feeRate`: BPS (100 = 1%).
- `defaultHoldPeriod`: escrow hold time in seconds.
- `gasThresold`: minimum gas to keep processing heap.
- `marketplace`: authorized address for Advanced processor.
- `authorized`: list of addresses allowed to call restricted storage functions.

## Using the Simple Processor

Typical flow:

1. Seller calls `createInvoice`.
2. Buyer pays with exact ETH value via `pay`.
3. Seller accepts with `acceptPayment`.
4. After `releaseAt`, funds are released to seller (manual or via Automation).
5. If the decision window expires, buyer can be refunded.

## Using the Advanced Processor

Typical flow:

1. Marketplace calls `createSingleInvoice` or `createMetaInvoice`.
2. Buyer calls `payInvoice` or `payMetaInvoice`.
3. Disputes are created and handled by marketplace.
4. When hold period expires, funds are released.

Price feeds must be configured with `setPriceFeed` before ERC20 payments.

## Getting Started

Prerequisites: [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
# Install dependencies
forge install

# Run tests
forge test

# Format code
forge fmt
```

## Tests

- Unit tests under `test/unit`.
- Invariant tests under `test/invariant`.
- Mocks for ERC20 and price feeds under `test/mock`.

If you already have invariants in Foundry, Echidna is optional.

## Static Analysis (Slither)

Prerequisite: [Slither](https://github.com/crytic/slither) installed.

```bash
# Run static analysis from repo root and write JSON report
slither . \
  --exclude-dependencies \
  --json slither-report.json
```

Slither will not overwrite an existing `slither-report.json`. Delete or rename the file before re-running if you need a fresh report.

**Interpreting Slither Output For This Repo**

- `incorrect-equality`: comparisons are against explicit state codes or zero-initialized fields (no floating-point or precision risk).
- `locked-ether`: `PaymentProcessorStorage` is not designed to receive ETH; any ETH sent would be accidental and is not part of protocol flow.
- `uninitialized-local`: local structs default to zero and are then assigned before use.
- `unused-return`: return values are intentionally ignored where only side effects matter.
- `events-maths`: some config setters do not emit events by design; not a correctness issue.
- `missing-zero-check`: zero values are either intentionally allowed (e.g., disabling a forwarder) or inputs are already validated by trusted callers.
- `calls-loop`: external calls occur in bounded loops (meta-invoice length) and are expected; gas cost is the main consideration.
- `reentrancy-benign` / `reentrancy-events`: external calls are to protocol-controlled contracts and state is updated before withdrawals; events after calls are not stateful.
- `timestamp`: time-based expiry and release logic is core to invoice/escrow behavior.
- `pragma`: dependencies use `^0.8.4` but compile cleanly with `0.8.28`.
- `dead-code`: `_release` is referenced via function pointer in `TaskQueueLib.processDueTask`, which Slither does not resolve.
- `naming-convention`: leading-underscore parameters are a project style choice.
- `too-many-digits`: false positive on generated bytecode literals; no impact.

## Operational Notes

- Ensure `PaymentProcessorStorage` authorizes processor contracts.
- Keep `gasThresold` conservative to avoid OOG in `performUpkeep`.
- Configure Chainlink feeds for each ERC20 token in the advanced processor.
