import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // Unit tests cover pure logic (protocol framing, identity parsers); no DOM.
    environment: "node",
    include: ["lib/**/*.test.ts"],
  },
});
