import { afterEach, describe, expect, test } from "bun:test";
import { childEnv, runProcess } from "./process.ts";

const SECRET = "sk-akari-test-do-not-leak";

afterEach(() => {
  delete process.env["DASHSCOPE_API_KEY"];
  delete process.env["AKARI_TEST_SECRET"];
});

describe("runProcess", () => {
  test("does not hand the core's secrets to a child", async () => {
    // The core loads the repo .env into process.env at startup; an inherited
    // environment would put the DashScope key inside every spawned process,
    // one `echo $DASHSCOPE_API_KEY` away from the model.
    process.env["DASHSCOPE_API_KEY"] = SECRET;
    process.env["AKARI_TEST_SECRET"] = SECRET;

    const result = await runProcess([
      "/bin/sh",
      "-c",
      'echo "[$DASHSCOPE_API_KEY][$AKARI_TEST_SECRET]"; env',
    ]);

    expect(result.code).toBe(0);
    expect(result.stdout).toContain("[][]");
    expect(result.stdout).not.toContain(SECRET);
    expect(result.stderr).not.toContain(SECRET);
  });

  test("still gives the child the basics it needs to run", async () => {
    const result = await runProcess(["/bin/sh", "-c", "echo $PATH; echo $HOME"]);
    const [path, home] = result.stdout.trim().split("\n");
    expect(path).toBeTruthy();
    expect(home).toBe(process.env["HOME"] ?? "");
  });
});

describe("childEnv", () => {
  test("is an allow-list, so a new secret cannot arrive by accident", () => {
    process.env["AKARI_TEST_SECRET"] = SECRET;
    const env = childEnv();
    expect(env["AKARI_TEST_SECRET"]).toBeUndefined();
    expect(Object.keys(env).length).toBeLessThanOrEqual(9);
    expect(env["PATH"]).toBeTruthy();
  });
});
