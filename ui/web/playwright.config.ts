import { defineConfig } from "@playwright/test";

const isCI = !!process.env.CI;

export default defineConfig({
  testDir: "./tests/e2e",
  use: { baseURL: "http://localhost:3000" },
  webServer: {
    // CI uses production build for parity with Vercel deploy; local uses dev server for HMR speed.
    command: isCI ? "pnpm build && pnpm start" : "pnpm dev",
    port: 3000,
    // Locally reuse a server you already have running. On CI, always own the lifecycle.
    reuseExistingServer: !isCI,
    timeout: 120_000,
  },
});
