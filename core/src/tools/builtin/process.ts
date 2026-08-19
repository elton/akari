/**
 * Spawning helper for the built-in tools.
 *
 * Arguments are always passed as an argv array — never a shell string — so a
 * value that reached us from the model (or, worse, from a web page the model
 * read) cannot become a second command. There is no shell here to inject into.
 *
 * The child also gets a built environment, never this process's own. The core
 * loads the repo `.env` into `process.env` at startup, so an inherited
 * environment would hand DASHSCOPE_API_KEY to every child — and the day
 * `run_shell` lands, one injected "run `env`" is the whole key. The allow-list
 * below is the smallest set that keeps `open` and `pbpaste` behaving.
 */

export interface ProcessOutput {
  code: number;
  stdout: string;
  stderr: string;
  timedOut: boolean;
}

export interface RunOptions {
  timeoutMs?: number;
  signal?: AbortSignal;
}

/**
 * Variables a child may inherit. Nothing here is a credential:
 *
 *   PATH/HOME/USER/LOGNAME     the identity `open` and friends expect
 *   TMPDIR                     per-user scratch; without it children use /tmp
 *   LANG/LC_ALL/LC_CTYPE       text encoding
 *   __CF_USER_TEXT_ENCODING    CoreFoundation's own encoding hint — without it
 *                              `pbpaste` can hand back mis-decoded non-ASCII
 *
 * Never add a variable by pattern, and never fall back to `...process.env`:
 * the point of this list is that a secret cannot arrive here by accident.
 */
const INHERITED = [
  "PATH",
  "HOME",
  "USER",
  "LOGNAME",
  "TMPDIR",
  "LANG",
  "LC_ALL",
  "LC_CTYPE",
  "__CF_USER_TEXT_ENCODING",
] as const;

const FALLBACK_PATH = "/usr/bin:/bin:/usr/sbin:/sbin";

/** The environment a child process gets: allow-listed values only. */
export function childEnv(): Record<string, string> {
  const env: Record<string, string> = {};
  for (const key of INHERITED) {
    const value = process.env[key];
    if (typeof value === "string" && value.length > 0) env[key] = value;
  }
  env["PATH"] ??= FALLBACK_PATH;
  return env;
}

export async function runProcess(
  argv: string[],
  options: RunOptions = {},
): Promise<ProcessOutput> {
  const timeoutMs = options.timeoutMs ?? 10_000;
  const child = Bun.spawn(argv, {
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
    // Passing `env` replaces the environment; it does not extend it.
    env: childEnv(),
  });

  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    child.kill();
  }, timeoutMs);
  const onAbort = () => child.kill();
  options.signal?.addEventListener("abort", onAbort, { once: true });

  try {
    const [stdout, stderr] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
    ]);
    const code = await child.exited;
    return { code, stdout, stderr, timedOut };
  } finally {
    clearTimeout(timer);
    options.signal?.removeEventListener("abort", onAbort);
  }
}
