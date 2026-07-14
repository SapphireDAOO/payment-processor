import {
  CronCapability,
  EVMClient,
  getNetwork,
  handler,
  hexToBase64,
  bytesToHex,
  Runner,
  TxStatus,
  type Runtime,
} from "@chainlink/cre-sdk";
import {
  decodeFunctionResult,
  encodeAbiParameters,
  encodeFunctionData,
  parseAbiParameters,
  type Address,
} from "viem";
import { z } from "zod";

const configSchema = z.object({
  schedule: z.string(),
  chainSelectorName: z.string(),
  processorAddress: z.string(),
  gasLimit: z.string(),
});

export type Config = z.infer<typeof configSchema>;

const processorAbi = [
  {
    type: "function",
    name: "hasDueTasks",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "dueTasksExist", type: "bool" }],
  },
] as const;

/**
 * Cron-triggered replacement for the retired Chainlink Automation upkeep:
 * reads SimplePaymentProcessor.hasDueTasks() and, when a task is due, submits
 * a signed report that the CRE forwarder delivers via onReport, draining the
 * due-task heap.
 */
export const onCronTrigger = (runtime: Runtime<Config>): string => {
  const config = configSchema.parse(runtime.config);

  const network = getNetwork({
    chainFamily: "evm",
    chainSelectorName: config.chainSelectorName,
  });
  if (!network) {
    throw new Error(`Unknown network: ${config.chainSelectorName}`);
  }

  const evmClient = new EVMClient(network.chainSelector.selector);
  const processorAddress = config.processorAddress as Address;

  const callResult = evmClient
    .callContract(runtime, {
      call: {
        to: hexToBase64(processorAddress),
        data: hexToBase64(
          encodeFunctionData({ abi: processorAbi, functionName: "hasDueTasks" })
        ),
      },
    })
    .result();

  const dueTasksExist = decodeFunctionResult({
    abi: processorAbi,
    functionName: "hasDueTasks",
    data: bytesToHex(callResult.data),
  });

  if (!dueTasksExist) {
    runtime.log("No due invoice tasks; skipping onchain write.");
    return "skipped";
  }

  runtime.log("Due invoice tasks found; submitting report to processor.");

  // The processor ignores the report payload — delivery of a verified report
  // is the trigger — but a payload is required to produce a signed report.
  const reportPayload = encodeAbiParameters(parseAbiParameters("uint256 triggeredAt"), [
    BigInt(Math.floor(runtime.now().getTime() / 1000)),
  ]);

  const report = runtime
    .report({
      encodedPayload: hexToBase64(reportPayload),
      encoderName: "evm",
      signingAlgo: "ecdsa",
      hashingAlgo: "keccak256",
    })
    .result();

  const writeResult = evmClient
    .writeReport(runtime, {
      receiver: processorAddress,
      report,
      gasConfig: { gasLimit: config.gasLimit },
    })
    .result();

  if (writeResult.txStatus !== TxStatus.SUCCESS) {
    throw new Error(`writeReport failed with tx status ${writeResult.txStatus}`);
  }

  const txHash = writeResult.txHash ? bytesToHex(writeResult.txHash) : "unknown";
  runtime.log(`Due tasks processed. Tx: ${txHash}`);
  return txHash;
};

export const initWorkflow = (config: Config) => {
  const cron = new CronCapability();

  return [handler(cron.trigger({ schedule: config.schedule }), onCronTrigger)];
};

export async function main() {
  const runner = await Runner.newRunner<Config>();
  await runner.run(initWorkflow);
}
