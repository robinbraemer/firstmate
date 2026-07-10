// Firstmate primary watcher bridge for Pi.
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

type ArmResult = {
  ok: boolean;
  message: string;
};

type LockOwnership = "owned" | "missing" | "other";
type CoordinatorState = "idle" | "starting" | "running" | "stopping";

type ArmRecord = {
  child: ChildProcess;
  generation: number;
  intentionalStopReason: string;
  settled: boolean;
  completion: Promise<void>;
  resolveCompletion: () => void;
  stdout: string;
  stderr: string;
  sendWake: (message: string) => Promise<void>;
};

type ArmCoordinator = {
  current: ArmRecord | null;
  generation: number;
  sequence: number;
  state: CoordinatorState;
  startPromise: Promise<ArmResult> | null;
  clients: Set<symbol>;
  exitListener?: () => void;
};

type CoordinatorHost = typeof globalThis & {
  __firstmatePiWatchCoordinators?: Map<string, ArmCoordinator>;
};

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = resolve(process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root);
const fmRoot = resolve(process.env.FM_ROOT_OVERRIDE || root);
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const armScript = `${fmRoot}/bin/fm-watch-arm.sh`;
const lockScript = `${fmRoot}/bin/fm-lock.sh`;
const marker = `${state}/.pi-watch-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;
const coordinatorHost = globalThis as CoordinatorHost;
const coordinators = coordinatorHost.__firstmatePiWatchCoordinators ??= new Map<string, ArmCoordinator>();

function coordinatorForHome(): ArmCoordinator {
  const existing = coordinators.get(fmHome);
  if (existing) return existing;
  const coordinator: ArmCoordinator = {
    current: null,
    generation: 0,
    sequence: 0,
    state: "idle",
    startPromise: null,
    clients: new Set<symbol>(),
  };
  coordinators.set(fmHome, coordinator);
  return coordinator;
}

function parentPid(pid: string): string {
  const result = spawnSync("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" });
  if (result.status !== 0) return "";
  return result.stdout.trim();
}

function pidAlive(pid: string): boolean {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

function lockOwnership(): LockOwnership {
  let lockPid = "";
  try {
    lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
  } catch {
    return "missing";
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "other";
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) return "owned";
    pid = parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return pidAlive(lockPid) ? "other" : "missing";
}

function claimSessionLock(): Promise<void> {
  return new Promise((resolvePromise) => {
    const child = spawn(lockScript, [], {
      cwd: fmRoot,
      env: {
        ...process.env,
        FM_HOME: fmHome,
        FM_ROOT_OVERRIDE: fmRoot,
        FM_STATE_OVERRIDE: state,
      },
      stdio: "ignore",
    });
    let settled = false;
    const settle = () => {
      if (settled) return;
      settled = true;
      resolvePromise();
    };
    child.on("error", settle);
    child.on("close", settle);
  });
}

function markLoaded(): void {
  if (lockOwnership() === "other") return;
  mkdirSync(state, { recursive: true });
  writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
}

function actionableLine(output: string): string {
  const lines = output.split(/\r?\n/);
  return lines.find((line) => /^(signal:|stale:|check:|heartbeat($|:))/.test(line)) || "";
}

function failureLine(stdout: string, stderr: string, code: number | null): string {
  const combined = `${stdout}\n${stderr}`.trim();
  const healthy = combined.split(/\r?\n/).find((line) => /^watcher: healthy\b/.test(line));
  if (healthy) return `watcher: FAILED - Pi extension arm child found an external healthy watcher instead of owning wake delivery\n${healthy}`;
  const failed = combined.split(/\r?\n/).find((line) => /^watcher: FAILED/.test(line));
  if (failed) return failed;
  if (code && code !== 0) return `watcher: FAILED - fm-watch-arm.sh exited ${code}${combined ? `\n${combined}` : ""}`;
  return "";
}

function settleArm(
  coordinator: ArmCoordinator,
  record: ArmRecord,
  code: number | null,
  error?: Error,
): void {
  if (record.settled) return;
  record.settled = true;
  const ownsGeneration = coordinator.current === record && coordinator.generation === record.generation;
  if (ownsGeneration) {
    coordinator.current = null;
    coordinator.state = "idle";
  }
  record.resolveCompletion();
  if (!ownsGeneration || record.intentionalStopReason) return;

  const reason = error
    ? `watcher: FAILED - Pi extension arm child ${record.generation} failed: ${error.message}`
    : actionableLine(`${record.stdout}\n${record.stderr}`);
  const failure = reason || error ? "" : failureLine(record.stdout, record.stderr, code);
  const message = reason || failure;
  if (!message) return;
  void record.sendWake(message).catch(() => {
    // Pi owns delivery errors; fail open so the extension never wedges the session.
  });
}

function stopArm(coordinator: ArmCoordinator, reason: string): Promise<void> {
  const record = coordinator.current;
  if (!record) return Promise.resolve();
  if (!record.intentionalStopReason) record.intentionalStopReason = reason;
  if (coordinator.current === record) coordinator.state = "stopping";
  record.child.kill("SIGTERM");
  return record.completion;
}

export default function (pi: ExtensionAPI) {
  const coordinator = coordinatorForHome();
  const client = Symbol("pi-watch-extension-client");
  coordinator.clients.add(client);

  const cleanupOnProcessExit = () => {
    void stopArm(coordinator, "process-exit");
  };
  if (!coordinator.exitListener) {
    coordinator.exitListener = cleanupOnProcessExit;
    process.once("exit", cleanupOnProcessExit);
  }

  async function sendWake(message: string): Promise<void> {
    await pi.sendUserMessage(
      `FIRSTMATE WATCHER WAKE: ${message}\n\nRun bin/fm-wake-drain.sh first, handle the queued wake, then resume Pi supervision.`,
      { deliverAs: "followUp" },
    );
  }

  async function startArmOnce(): Promise<ArmResult> {
    if (lockOwnership() !== "owned") await claimSessionLock();
    if (lockOwnership() !== "owned") return { ok: false, message: "watcher: read-only - session lock is held by another firstmate session" };
    markLoaded();
    if (coordinator.current) return { ok: true, message: "watcher: healthy - Pi extension already has an arm child" };

    const id = ++coordinator.sequence;
    const generation = ++coordinator.generation;
    const env = {
      ...process.env,
      FM_HOME: fmHome,
      FM_ROOT_OVERRIDE: fmRoot,
      FM_CONFIG_OVERRIDE: config,
      FM_WATCH_ARM_SCRIPT: armScript,
    };
    const child = spawn("bash", ["-lc", "config_dir=\"${FM_CONFIG_OVERRIDE:-$FM_HOME/config}\"; [ -f \"$config_dir/x-mode.env\" ] && . \"$config_dir/x-mode.env\"; exec \"$FM_WATCH_ARM_SCRIPT\" --restart"], {
      cwd: fmRoot,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let resolveCompletion = () => {};
    const completion = new Promise<void>((resolvePromise) => {
      resolveCompletion = resolvePromise;
    });
    const record: ArmRecord = {
      child,
      generation,
      intentionalStopReason: "",
      settled: false,
      completion,
      resolveCompletion,
      stdout: "",
      stderr: "",
      sendWake,
    };
    coordinator.current = record;
    coordinator.state = "running";
    child.stdout?.on("data", (chunk: Buffer) => {
      record.stdout += chunk.toString();
    });
    child.stderr?.on("data", (chunk: Buffer) => {
      record.stderr += chunk.toString();
    });
    child.on("close", (code: number | null) => {
      settleArm(coordinator, record, code);
    });
    child.on("error", (error: Error) => {
      settleArm(coordinator, record, null, error);
    });
    return { ok: true, message: `watcher: started Pi extension arm child ${id}` };
  }

  function startArm(): Promise<ArmResult> {
    if (coordinator.startPromise) return coordinator.startPromise;
    coordinator.state = "starting";
    let startPromise: Promise<ArmResult>;
    startPromise = startArmOnce().finally(() => {
      if (coordinator.startPromise !== startPromise) return;
      coordinator.startPromise = null;
      coordinator.state = coordinator.current ? "running" : "idle";
    });
    coordinator.startPromise = startPromise;
    return startPromise;
  }

  pi.on?.("session_start", () => {
    markLoaded();
  });
  pi.on?.("session_shutdown", async () => {
    coordinator.clients.delete(client);
    if (coordinator.clients.size > 0) return;
    await stopArm(coordinator, "session-shutdown");
    if (coordinator.clients.size === 0 && coordinator.exitListener) {
      process.off("exit", coordinator.exitListener);
      coordinator.exitListener = undefined;
    }
  });

  pi.registerCommand?.("fm-watch-arm-pi", {
    description: "Arm firstmate watcher supervision through the Pi extension instead of foreground bash.",
    handler: async (_args, ctx) => {
      const result = await startArm();
      ctx.ui.notify(result.message, result.ok ? "info" : "warning");
    },
  });

  pi.registerTool?.({
    name: "fm_watch_arm_pi",
    label: "Arm firstmate watcher",
    description: "Arm Pi watcher supervision. Always use this tool instead of running bin/fm-watch-arm.sh through bash.",
    promptSnippet: "Arm firstmate watcher supervision through Pi without a foreground bash arm.",
    promptGuidelines: [
      "For Pi watcher supervision, call fm_watch_arm_pi instead of running bin/fm-watch-arm.sh through bash.",
    ],
    parameters: Type.Object({}),
    execute: async () => {
      const result = await startArm();
      return {
        content: [{ type: "text", text: result.message }],
        details: result,
      };
    },
  });

  markLoaded();
}
