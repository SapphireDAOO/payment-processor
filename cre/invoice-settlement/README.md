# Invoice Settlement Workflow

Chainlink CRE workflow that replaces the retired Chainlink Automation upkeep for
`SimplePaymentProcessor`.

Every cron tick it:

1. Reads `hasDueTasks()` on the processor (EVM read).
2. If no task is due, exits without writing onchain.
3. Otherwise generates a signed report and submits it with `writeReport`. The CRE
   forwarder verifies the report and calls `onReport(metadata, report)` on the
   processor, which drains due invoice tasks (auto-release / auto-refund) within
   the configured gas threshold.

The report payload is ignored by the contract — delivery of a verified report is
itself the trigger. Authorization happens onchain: `onReport` only accepts the
configured forwarder address (`setForwarderAddress`) and the workflow owner
carried in the report metadata (`setWorkflowOwner`).

## Configuration

`config.staging.json` / `config.production.json`:

| Field | Description |
|---|---|
| `schedule` | Cron schedule (6-field, e.g. `0 */5 * * * *` = every 5 minutes) |
| `chainSelectorName` | CRE chain selector name (`ethereum-testnet-sepolia-base-1` = Base Sepolia) |
| `processorAddress` | Deployed `SimplePaymentProcessor` address |
| `gasLimit` | Gas limit for the report-delivery transaction |

Update `processorAddress` after deploying the contracts.

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

After deploying, wire the contract to the workflow:

1. `setForwarderAddress(<CRE forwarder address for the target chain>)`
2. `setWorkflowOwner(<workflow owner address used to deploy the workflow>)`
