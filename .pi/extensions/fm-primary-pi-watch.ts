// Firstmate primary watcher bridge for Pi.
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
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
type WakeKind = "actionable" | "failure";

type WakeDetails = {
  generation: number;
  kind: WakeKind;
  reason: string;
  exitCode: number | null;
  signal: NodeJS.Signals | null;
  truncated: boolean;
  stdoutTruncated: boolean;
  stderrTruncated: boolean;
};

type WakeSender = (message: string, details: WakeDetails) => Promise<void>;

type CompletedCapture = {
  stdout: string;
  stderr: string;
};

type ArmRecord = {
  child: ChildProcess;
  generation: number;
  intentionalStopReason: string;
  settled: boolean;
  stdout: string;
  stderr: string;
  stdoutPending: string;
  stderrPending: string;
  stdoutTruncated: boolean;
  stderrTruncated: boolean;
  actionable: string;
  failureHint: string;
};

type ArmCoordinator = {
  current: ArmRecord | null;
  lastCompleted: CompletedCapture | null;
  generation: number;
  sequence: number;
  state: CoordinatorState;
  startPromise: Promise<ArmResult> | null;
  startCancelled: boolean;
  clients: Map<symbol, WakeSender>;
  exitListener?: () => void;
};

type CoordinatorHost = typeof globalThis & {
  __firstmatePiWatchCoordinators?: Map<string, ArmCoordinator>;
};

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = realpathSync(resolve(extensionDir, "../.."));
const fmHome = resolve(process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root);
const fmRoot = resolve(process.env.FM_ROOT_OVERRIDE || root);
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const armScript = `${fmRoot}/bin/fm-watch-arm.sh`;
const lockScript = `${fmRoot}/bin/fm-lock.sh`;
const marker = `${state}/.pi-watch-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;
const MAX_CAPTURE_BYTES = 16 * 1024;
const MAX_PENDING_LINE_BYTES = 4 * 1024;
const requestedStopGrace = Number(process.env.FM_PI_WATCH_STOP_GRACE_MS ?? "1000");
const STOP_GRACE_MS = Number.isFinite(requestedStopGrace) && requestedStopGrace >= 0 ? requestedStopGrace : 1000;
const STOP_KILL_GRACE_MS = 500;
const coordinatorHost = globalThis as CoordinatorHost;
const coordinators = coordinatorHost.__firstmatePiWatchCoordinators ??= new Map<string, ArmCoordinator>();

function supervisingHome(): boolean {
  if (existsSync(`${root}/.fm-secondmate-home`)) return true;
  if (!existsSync(`${root}/AGENTS.md`) || !existsSync(`${root}/bin`)) return false;
  if (process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE) {
    try {
      if (realpathSync(fmHome) === root) return true;
    } catch {
      return false;
    }
  }
  const gitDir = spawnSync("git", ["-C", root, "rev-parse", "--git-dir"], { encoding: "utf8" });
  const commonDir = spawnSync("git", ["-C", root, "rev-parse", "--git-common-dir"], { encoding: "utf8" });
  if (gitDir.status !== 0 || commonDir.status !== 0) return false;
  return gitDir.stdout.trim() === commonDir.stdout.trim();
}

function coordinatorForHome(): ArmCoordinator {
  const existing = coordinators.get(fmHome);
  if (existing) return existing;
  const coordinator: ArmCoordinator = {
    current: null,
    lastCompleted: null,
    generation: 0,
    sequence: 0,
    state: "idle",
    startPromise: null,
    startCancelled: false,
    clients: new Map<symbol, WakeSender>(),
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

function canonicalLockIsStale(): boolean {
  const result = spawnSync(lockScript, ["status"], {
    cwd: fmRoot,
    env: {
      ...process.env,
      FM_HOME: fmHome,
      FM_ROOT_OVERRIDE: fmRoot,
      FM_STATE_OVERRIDE: state,
    },
    encoding: "utf8",
  });
  return result.status === 0 && /^lock: stale\b/.test(result.stdout.trim());
}

function markLoaded(): void {
  if (lockOwnership() === "other" && !canonicalLockIsStale()) return;
  mkdirSync(state, { recursive: true });
  writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
}

function actionableLine(line: string): string {
  return /^(signal:|stale:|check:|heartbeat($|:))/.test(line) ? line : "";
}

function appendBoundedTail(current: string, text: string): { value: string; truncated: boolean } {
  const combined = Buffer.from(current + text);
  if (combined.byteLength <= MAX_CAPTURE_BYTES) return { value: combined.toString(), truncated: false };
  return {
    value: combined.subarray(combined.byteLength - MAX_CAPTURE_BYTES).toString(),
    truncated: true,
  };
}

function inspectOutputLine(record: ArmRecord, line: string): void {
  const lineBuffer = Buffer.from(line);
  const boundedLine = lineBuffer.byteLength > MAX_PENDING_LINE_BYTES
    ? lineBuffer.subarray(0, MAX_PENDING_LINE_BYTES).toString()
    : line;
  if (!record.actionable) record.actionable = actionableLine(boundedLine);
  if (!record.failureHint && (/^watcher: healthy\b/.test(boundedLine) || /^watcher: FAILED/.test(boundedLine))) {
    record.failureHint = boundedLine;
  }
}

function captureOutput(record: ArmRecord, stream: "stdout" | "stderr", chunk: Buffer): void {
  const text = chunk.toString();
  const tail = appendBoundedTail(record[stream], text);
  record[stream] = tail.value;
  const truncatedKey = stream === "stdout" ? "stdoutTruncated" : "stderrTruncated";
  record[truncatedKey] ||= tail.truncated;

  const pendingKey = stream === "stdout" ? "stdoutPending" : "stderrPending";
  const lines = `${record[pendingKey]}${text}`.split(/\r?\n/);
  record[pendingKey] = lines.pop() ?? "";
  for (const line of lines) inspectOutputLine(record, line);
  if (Buffer.byteLength(record[pendingKey]) > MAX_PENDING_LINE_BYTES) {
    inspectOutputLine(record, record[pendingKey]);
    record[pendingKey] = Buffer.from(record[pendingKey]).subarray(0, MAX_PENDING_LINE_BYTES).toString();
    record[truncatedKey] = true;
  }
}

function failureLine(record: ArmRecord, code: number | null, signal: NodeJS.Signals | null): string {
  const combined = `${record.stdout}\n${record.stderr}`.trim();
  if (/^watcher: healthy\b/.test(record.failureHint)) {
    return `watcher: FAILED - Pi extension arm child found an external healthy watcher instead of owning wake delivery\n${record.failureHint}`;
  }
  if (/^watcher: FAILED/.test(record.failureHint)) return record.failureHint;
  if (signal) return `watcher: FAILED - fm-watch-arm.sh terminated by ${signal}${combined ? `\n${combined}` : ""}`;
  if (code !== null && code !== 0) return `watcher: FAILED - fm-watch-arm.sh exited ${code}${combined ? `\n${combined}` : ""}`;
  return `watcher: FAILED - fm-watch-arm.sh exited unexpectedly with code ${code ?? "unknown"}${combined ? `\n${combined}` : ""}`;
}

function settleArm(
  coordinator: ArmCoordinator,
  record: ArmRecord,
  code: number | null,
  signal: NodeJS.Signals | null,
  error?: Error,
): void {
  if (record.settled) return;
  record.settled = true;
  inspectOutputLine(record, record.stdoutPending);
  inspectOutputLine(record, record.stderrPending);
  const ownsGeneration = coordinator.current === record && coordinator.generation === record.generation;
  if (ownsGeneration) {
    coordinator.current = null;
    coordinator.lastCompleted = { stdout: record.stdout, stderr: record.stderr };
    coordinator.state = "idle";
  }
  if (!ownsGeneration || record.intentionalStopReason) return;

  const message = error
    ? `watcher: FAILED - Pi extension arm child ${record.generation} failed: ${error.message}`
    : record.actionable || failureLine(record, code, signal);
  const kind: WakeKind = record.actionable && !error ? "actionable" : "failure";
  const details: WakeDetails = {
    generation: record.generation,
    kind,
    reason: message,
    exitCode: code,
    signal,
    truncated: record.stdoutTruncated || record.stderrTruncated,
    stdoutTruncated: record.stdoutTruncated,
    stderrTruncated: record.stderrTruncated,
  };
  const sendWake = [...coordinator.clients.values()].at(-1);
  if (!sendWake) return;
  void sendWake(message, details).catch(() => {
    // Pi owns delivery errors; fail open so the extension never wedges the session.
  });
}

function signalArm(record: ArmRecord, signal: NodeJS.Signals): void {
  const pid = record.child.pid;
  if (pid) {
    try {
      process.kill(-pid, signal);
      return;
    } catch {
      // Fall back to the direct child only when group signaling is unavailable.
    }
  }
  try {
    record.child.kill(signal);
  } catch {
    // The process may already be gone; settlement remains event-driven or bounded below.
  }
}

function processGroupAlive(record: ArmRecord): boolean {
  const pid = record.child.pid;
  if (!pid) return false;
  try {
    process.kill(-pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code !== "ESRCH";
  }
}

function stopsWithin(record: ArmRecord, milliseconds: number): Promise<boolean> {
  return new Promise<boolean>((resolvePromise) => {
    const deadline = Date.now() + milliseconds;
    const check = () => {
      if (record.settled && !processGroupAlive(record)) {
        resolvePromise(true);
        return;
      }
      const remaining = deadline - Date.now();
      if (remaining <= 0) {
        resolvePromise(false);
        return;
      }
      setTimeout(check, Math.min(10, remaining));
    };
    check();
  });
}

async function stopArm(coordinator: ArmCoordinator, reason: string): Promise<void> {
  const record = coordinator.current;
  if (!record) return;
  if (!record.intentionalStopReason) record.intentionalStopReason = reason;
  if (coordinator.current === record) coordinator.state = "stopping";
  signalArm(record, "SIGTERM");
  if (await stopsWithin(record, STOP_GRACE_MS)) return;
  signalArm(record, "SIGKILL");
  if (await stopsWithin(record, STOP_KILL_GRACE_MS)) return;
  if (!record.settled) settleArm(coordinator, record, null, "SIGKILL");
  if (processGroupAlive(record)) throw new Error(`watcher: FAILED - process group ${record.child.pid} survived SIGKILL`);
}

function stopArmOnProcessExit(coordinator: ArmCoordinator): void {
  const record = coordinator.current;
  if (!record) return;
  if (!record.intentionalStopReason) record.intentionalStopReason = "process-exit";
  signalArm(record, "SIGTERM");
  signalArm(record, "SIGKILL");
}

function runPretoolCheck(command: string): Promise<{ code: number; stderr: string }> {
  return new Promise((resolveResult) => {
    const child = spawn(`${fmRoot}/bin/fm-arm-pretool-check.sh`, ["--command", command], {
      stdio: ["ignore", "ignore", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolveResult({ code: 0, stderr: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stderr }));
  });
}

export default function (pi: ExtensionAPI) {
  if (!supervisingHome()) return;
  const coordinator = coordinatorForHome();
  const client = Symbol("pi-watch-extension-client");

  async function sendWake(message: string, details: WakeDetails): Promise<void> {
    pi.sendMessage(
      {
        customType: "firstmate-watcher-wake",
        content: `FIRSTMATE WATCHER WAKE: ${message}\n\nRun bin/fm-wake-drain.sh first, handle the queued wake, then resume Pi supervision.`,
        display: true,
        details,
      },
      { deliverAs: "followUp", triggerTurn: true },
    );
  }

  coordinator.clients.set(client, sendWake);

  const cleanupOnProcessExit = () => {
    stopArmOnProcessExit(coordinator);
  };
  if (!coordinator.exitListener) {
    coordinator.exitListener = cleanupOnProcessExit;
    process.once("exit", cleanupOnProcessExit);
  }

  async function startArmOnce(): Promise<ArmResult> {
    if (lockOwnership() !== "owned") await claimSessionLock();
    if (coordinator.startCancelled || coordinator.clients.size === 0) {
      return { ok: false, message: "watcher: not started - Pi extension session shut down" };
    }
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
      detached: true,
      stdio: ["ignore", "pipe", "pipe"],
    });
    const record: ArmRecord = {
      child,
      generation,
      intentionalStopReason: "",
      settled: false,
      stdout: "",
      stderr: "",
      stdoutPending: "",
      stderrPending: "",
      stdoutTruncated: false,
      stderrTruncated: false,
      actionable: "",
      failureHint: "",
    };
    coordinator.current = record;
    coordinator.state = "running";
    child.stdout?.on("data", (chunk: Buffer) => {
      captureOutput(record, "stdout", chunk);
    });
    child.stderr?.on("data", (chunk: Buffer) => {
      captureOutput(record, "stderr", chunk);
    });
    child.on("close", (code: number | null, signal: NodeJS.Signals | null) => {
      settleArm(coordinator, record, code, signal);
    });
    child.on("error", (error: Error) => {
      settleArm(coordinator, record, null, null, error);
    });
    return { ok: true, message: `watcher: started Pi extension arm child ${id}` };
  }

  function startArm(): Promise<ArmResult> {
    if (coordinator.startPromise) return coordinator.startPromise;
    if (coordinator.clients.size === 0) {
      return Promise.resolve({ ok: false, message: "watcher: not started - Pi extension session shut down" });
    }
    coordinator.startCancelled = false;
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
    coordinator.startCancelled = true;
    const pendingStart = coordinator.startPromise;
    if (pendingStart) await pendingStart.catch(() => undefined);
    if (coordinator.clients.size > 0) return;
    await stopArm(coordinator, "session-shutdown");
    if (coordinator.clients.size === 0 && coordinator.exitListener) {
      process.off("exit", coordinator.exitListener);
      coordinator.exitListener = undefined;
    }
  });

  pi.on("tool_call", async (event) => {
    if (event.type !== "tool_call" || event.toolName !== "bash") return {};
    const command = String((event.input as { command?: unknown })?.command ?? "");
    if (!command) return {};
    const result = await runPretoolCheck(command);
    if (result.code !== 2) return {};
    return { block: true, reason: result.stderr.trim() || "denied by the watcher-arm PreToolUse seatbelt" };
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
