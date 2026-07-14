import { describe, expect } from "bun:test";
import { test } from "@chainlink/cre-sdk/test";
import { initWorkflow } from "./main";
import type { Config } from "./main";

const config: Config = {
  schedule: "0 */5 * * * *",
  chainSelectorName: "ethereum-testnet-sepolia-base-1",
  processorAddress: "0xd70c10C73a716F85d97b5619dADfb6B1b6b6a706",
  gasLimit: "1000000",
};

describe("initWorkflow", () => {
  test("returns one cron handler with the configured schedule", async () => {
    const handlers = initWorkflow(config);

    expect(handlers).toBeArray();
    expect(handlers).toHaveLength(1);
    expect(handlers[0].trigger.config.schedule).toBe(config.schedule);
  });
});
