# Sapphire DAO Payment Processor

Foundry-based smart contracts for Sapphire DAO that support simple single-invoice flows and a more feature-rich processor with token support, price feeds, and automated releases.

## Contracts

- `src/SimplePaymentProcessor.sol`: Minimal escrowed invoice flow for native ETH. Supports creation, payment, seller decision window, release/refund, and Chainlink Automation based upkeep (heap of scheduled tasks).
- `src/AdvancedPaymentProcessor.sol`: Extends the simple flow with ERC20 support, partial refunds, price-feed based payments, and disputes. Shares the same upkeep/heap pattern.
- `src/PaymentProcessorStorage.sol`: Shared storage/config (owner, fee receiver, fee rate, default hold period, gas threshold, marketplace), plus authorization of processor contracts.
- `src/libraries/TaskQueueLib.sol`: Min-heap for scheduling release/refund tasks with gas-aware processing.
- `src/Escrow.sol`: Lightweight escrow used by the processors to hold funds until release/refund.
- Interfaces live under `src/interface/`.

## Key Behaviors

- **Invoices**: Seller creates, buyer pays exact amount, seller accepts/rejects within `DECISION_WINDOW`. After acceptance, funds release after hold period or can be adjusted by admin.
- **Automation**: `performUpkeep` processes due tasks from the heap and handles automatic refunds (expired decision window) or releases (due hold period).
- **Fees**: Collected in basis points and sent to `feeReceiver` on acceptance/release.
- **Admin controls**: Storage owner can set fee rate/receiver, default hold, gas threshold, forwarder, and authorize processors. Simple processor also exposes admin setters for minimum invoice value, valid period, and decision window.

## Getting Started

Prerequisites: [Foundry](https://book.getfoundry.sh/getting-started/installation) installed.

```bash
# Install dependencies
forge install

# Run unit tests
forge test

# Format code
forge fmt
```

## Tests

- Unit tests under `test/unit` cover invoice lifecycle, fee behavior, automation, and authorization.
- Invariant tests under `test/invariant` fuzz flows via handlers (heap and decision window assumptions).
- Mocks for ERC20 and price feeds live under `test/mock`.

## Usage Notes

- Callers interact with processors; storage is owned by admin and only authorizes processors/forwarder.
- Chainlink Automation (or an off-chain cron) should call `checkUpkeep`/`performUpkeep` to process due refunds/releases.
- For advanced token payments, ensure price feeds and token addresses are configured by admin before use.
