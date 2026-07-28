# Invoice Settlement Workflow

Chainlink CRE workflow that replaces the retired Chainlink Automation upkeep for
`SimplePaymentProcessor`.

It talks to `PaymentAutomation`, the keeper adapter that fronts the processor —
not to the processor itself. The adapter is both the read and the write target,
so the workflow only needs one address.

Every cron tick it:

1. Reads `hasDueTasks()` on the adapter (EVM read; passes through to the processor).
2. If no task is due, exits without writing onchain.
3. Otherwise generates a signed report and submits it with `writeReport`. The CRE
   forwarder verifies the report and calls `onReport(metadata, report)` on the
   adapter, which calls `processDueTasks()` on the processor, draining due invoice
   tasks (auto-release / auto-refund) within the configured gas threshold.

The report payload is ignored by the contract — delivery of a verified report is
itself the trigger. Authorization happens onchain: `onReport` only accepts the
configured forwarder address (`setForwarderAddress`) and the workflow owner
carried in the report metadata (`setWorkflowOwner`), both set on
`PaymentAutomation`. The processor in turn only accepts `processDueTasks` from
its owner or the adapter registered via `setAutomation`.

The same adapter also exposes a Gelato resolver (`checker()`), so a Gelato Web3
Function can drive the identical queue. Only one keeper network is meant to be
active at a time — Gelato is redundancy, to be switched on if CRE stalls or is
decommissioned. Running both at once is still safe: whichever fires first drains
the queue and the other finds nothing due.

## Configuration

`config.staging.json` / `config.production.json`:

| Field | Description |
|---|---|
| `schedule` | Cron schedule (6-field, e.g. `0 */5 * * * *` = every 5 minutes) |
| `chainSelectorName` | CRE chain selector name (`ethereum-testnet-sepolia-base-1` = Base Sepolia) |
| `automationAddress` | Deployed `PaymentAutomation` address |
| `gasLimit` | Gas limit for the report-delivery transaction |

`automationAddress` ships as the zero address — set it to the deployed
`PaymentAutomation` address before simulating or deploying the workflow.

## Setup

1. Add a funded private key to the project `.env` (only needed for chain-write
   simulation): `CRE_ETH_PRIVATE_KEY=...`
2. Install dependencies (requires bun >= 1.2.21):

```bash
bun install
```

## Test & simulate

```bash
bun run typecheck
bun test

# from the cre/ project root:
cre workflow simulate invoice-settlement --target staging-settings
```

## Deploy

```bash
cre workflow deploy invoice-settlement --target staging-settings
```

After deploying, wire the contracts to the workflow:

1. `SimplePaymentProcessor.setAutomation(<PaymentAutomation address>)` — done by
   `script/Deploy.s.sol` for fresh deployments.
2. `PaymentAutomation.setForwarderAddress(<CRE forwarder address for the target chain>)`
3. `PaymentAutomation.setWorkflowOwner(<workflow owner address used to deploy the workflow>)`
