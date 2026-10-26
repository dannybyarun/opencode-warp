/**
 * opencode-warp-rotate.ts - live 429 recovery for OpenCode sessions running
 * through the local Cloudflare WARP proxy.
 *
 * This is the mid-session companion to the wrapper's launch-time preflight.
 * When a model request fails with 429 / "Free usage limit reached", it rotates
 * the WARP device registration and asks OpenCode to retry the same request.
 * If a rotation cannot be applied, it vetoes the retry instead of inheriting
 * the provider's multi-hour retry-after.
 *
 * The free tier is now limited per model and tied to the egress/network, so a
 * rotation only helps when the ingress itself is the problem. One rotation is
 * attempted per session; if it does not help, the plugin fails fast instead
 * of churning registrations. Switch models with /models to get a fresh bucket.
 *
 * It only activates when all of these are true:
 *   - opencode is talking through 127.0.0.1:${WARP_PROXY_PORT}
 *     (i.e. --stand, or a `serve` started through the wrapper)
 *   - OPENCODE_WARP_NO_ROTATE is not set (probe/preflight recursion guard)
 *   - the failure is a rate-limit/quota failure
 *   - the model id contains "free" (unless freeOnly is disabled)
 *
 * Install: copied to <config>/plugins/opencode-warp-rotate.ts by setup.sh.
 * Manual recovery remains available: warp-rotate.sh --rotate-only
 */

import { Plugin } from "@opencode/plugin"
import { spawn } from "node:child_process"
import { access, appendFile, mkdir } from "node:fs/promises"
import { constants } from "node:fs"
import { homedir } from "node:os"
import { dirname, extname, join } from "node:path"

type Options = {
  enabled?: boolean
  freeOnly?: boolean
  maxRotationsPerSession?: number
  cooldownMs?: number
  retryDelayMs?: number
  rotationTimeoutMs?: number
  script?: string
}

type RotateResult = {
  ok: boolean
  code?: number
  reused?: boolean
  reason?: string
}

type SessionState = {
  rotations: number
}

const DEBUG = process.env.OPENCODE_WARP_PLUGIN_DEBUG === "1"

const last429 = new Map<
  string,
  {
    at: number
    headers: Record<string, string>
    parsedDelayMs?: number
  }
>()
const sessions = new Map<string, SessionState>()

let rotationInFlight: { startedBy: string; promise: Promise<RotateResult> } | undefined
let lastRotation = { at: 0, ok: false }

function debug(message: string): void {
  if (DEBUG) console.error(`[opencode-warp] ${message}`)
}

function envBool(name: string, fallback: boolean): boolean {
  const value = process.env[name]
  if (value === undefined) return fallback
  return !/^(0|false|no|off)$/i.test(value.trim())
}

function envInt(name: string, fallback: number, min = 0): number {
  const value = Number(process.env[name])
  return Number.isFinite(value) && value >= min ? value : fallback
}

function proxyPort(): string {
  return process.env.WARP_PROXY_PORT || "40000"
}

/** True only for the wrapper's local proxy, not an arbitrary corporate proxy. */
function warpProxyActive(): boolean {
  const port = proxyPort()
  for (const key of ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"]) {
    const value = process.env[key]
    if (!value) continue
    try {
      const url = new URL(value)
      if (
        (url.hostname === "127.0.0.1" || url.hostname === "localhost") &&
        (url.port || "80") === port
      ) {
        return true
      }
    } catch {
      if (value.includes(`127.0.0.1:${port}`) || value.includes(`localhost:${port}`)) {
        return true
      }
    }
  }
  return false
}

function freeModel(model: { providerID?: string; id?: string } | undefined): boolean {
  return /free/i.test(model?.id ?? "")
}

function quotaError(error: { type?: string; message?: string; status?: number }): boolean {
  if (error.status === 429) return true
  return /free usage limit|free messages|rate.?limit|too many requests|quota|429/i.test(
    `${error.type ?? ""} ${error.message ?? ""}`,
  )
}

function retryAfterMs(value: string | null): number | undefined {
  if (!value) return undefined
  const trimmed = value.trim()
  if (/^\d+$/.test(trimmed)) return Number(trimmed) * 1000
  const at = Date.parse(trimmed)
  return Number.isNaN(at) ? undefined : Math.max(0, at - Date.now())
}

function responseHeaders(response: Response): Record<string, string> {
  const headers: Record<string, string> = {}
  for (const name of ["retry-after", "cf-ray", "x-ratelimit-reset"]) {
    const value = response.headers.get(name)
    if (value) headers[name] = value
  }
  return headers
}

function logPath(): string {
  return (
    process.env.OPENCODE_RATELIMIT_LOG ||
    join(homedir(), ".local", "share", "opencode", "ratelimit-retry.jsonl")
  )
}

async function logEvent(row: Record<string, unknown>): Promise<void> {
  try {
    const file = logPath()
    await mkdir(dirname(file), { recursive: true })
    await appendFile(file, `${JSON.stringify(row)}\n`)
  } catch {
    // Observability must never break a session.
  }
}

function log(row: Record<string, unknown>): void {
  void logEvent({ ts: new Date().toISOString(), source: "opencode-warp-plugin", ...row })
}

/**
 * Platform selection is overridable so the Windows spawn path can be exercised
 * on Linux CI. Production always uses process.platform.
 */
function isWindows(): boolean {
  return (process.env.OPENCODE_WARP_TEST_PLATFORM || process.platform) === "win32"
}

function windowsLocalAppData(): string {
  return process.env.LOCALAPPDATA || join(homedir(), "AppData", "Local")
}

async function findScript(override?: string): Promise<string | undefined> {
  const candidates = isWindows()
    ? [
        override,
        process.env.OPENCODE_WARP_ROTATE,
        join(windowsLocalAppData(), "opencode-warp", "bin", "warp-rotate.ps1"),
        join(windowsLocalAppData(), "opencode-warp", "bin", "warp-rotate.cmd"),
      ]
    : [
        override,
        process.env.OPENCODE_WARP_ROTATE,
        "/usr/local/lib/opencode-warp/warp-rotate.sh",
      ]

  const mode = isWindows() ? constants.F_OK : constants.X_OK
  for (const candidate of candidates) {
    if (!candidate) continue
    try {
      await access(candidate, mode)
      return candidate
    } catch {
      // try the next path
    }
  }
  return undefined
}

function rotationInvocation(script: string): {
  command: string
  args: string[]
  verbatim?: boolean
} {
  if (!isWindows()) return { command: script, args: ["--rotate-only"] }

  const extension = extname(script).toLowerCase()
  if (extension === ".ps1") {
    return {
      command: process.env.OPENCODE_WARP_POWERSHELL || "powershell.exe",
      args: [
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        script,
        "--rotate-only",
      ],
    }
  }
  if (extension === ".cmd" || extension === ".bat") {
    // cmd.exe /s /c strips its first and last quote. Wrapping the quoted
    // script path in one extra pair keeps paths such as
    // C:\Program Files\nodejs\warp-rotate.cmd intact. Building the whole
    // command string here and passing it verbatim avoids Node adding its own
    // (single) layer of quoting.
    return {
      command: process.env.ComSpec || "cmd.exe",
      args: ["/d", "/s", "/c", `""${script}" --rotate-only"`],
      verbatim: true,
    }
  }
  return { command: script, args: ["--rotate-only"] }
}

function killRotationTree(child: ReturnType<typeof spawn>): void {
  if (isWindows() && child.pid) {
    try {
      const killer = spawn("taskkill", ["/PID", String(child.pid), "/T", "/F"], {
        stdio: "ignore",
        windowsHide: true,
      })
      killer.on("error", () => {
        try {
          child.kill()
        } catch {
          // already gone
        }
      })
      return
    } catch {
      // fall through to child.kill
    }
  }
  try {
    child.kill("SIGKILL")
  } catch {
    // already gone
  }
}

function runRotation(
  script: string,
  timeoutMs: number,
): Promise<{ code: number; output: string }> {
  return new Promise((resolve) => {
    let output = ""
    let settled = false
    let timer: ReturnType<typeof setTimeout> | undefined
    const invocation = rotationInvocation(script)
    const child = spawn(invocation.command, invocation.args, {
      env: { ...process.env, OPENCODE_WARP_NO_ROTATE: "1" },
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: isWindows(),
      windowsVerbatimArguments: invocation.verbatim === true,
    })

    const finish = (code: number) => {
      if (settled) return
      settled = true
      if (timer) clearTimeout(timer)
      resolve({ code, output: output.slice(-4000) })
    }

    timer = setTimeout(() => {
      output += "\n[rotation timed out]"
      killRotationTree(child)
      // Do not wait for `close`: a grandchild that inherited the pipes can keep
      // them open long after the script itself is gone.
      finish(124)
    }, timeoutMs)

    child.stdout?.on("data", (chunk) => {
      output += String(chunk)
    })
    child.stderr?.on("data", (chunk) => {
      output += String(chunk)
    })
    child.on("error", (error) => {
      output += `\n${error.message}`
      finish(127)
    })
    child.on("close", (code) => finish(code ?? 1))
  })
}

async function doRotate(script: string, timeoutMs: number): Promise<RotateResult> {
  const { code, output } = await runRotation(script, timeoutMs)
  const ok = code === 0
  lastRotation = { at: Date.now(), ok }
  if (!ok) debug(`rotation failed (exit ${code})\n${output.trim()}`)
  return { ok, code }
}

async function rotateWarp(
  sessionID: string,
  script: string,
  options: { maxRotationsPerSession: number; cooldownMs: number; rotationTimeoutMs: number },
): Promise<RotateResult> {
  const state = sessions.get(sessionID) ?? { rotations: 0 }
  sessions.set(sessionID, state)

  if (state.rotations >= options.maxRotationsPerSession) {
    return { ok: false, reason: "session-rotation-limit" }
  }

  // A rotation already underway benefits every session: one WARP identity is
  // shared, so wait for it instead of deleting the registration again. The
  // session that started it already gets credit below; do not count it twice.
  if (rotationInFlight) {
    const current = rotationInFlight
    const result = await current.promise
    if (result.ok && current.startedBy !== sessionID) state.rotations++
    return result
  }

  const since = Date.now() - lastRotation.at
  if (since < options.cooldownMs) {
    if (lastRotation.ok && state.rotations === 0) return { ok: true, reused: true }
    if (lastRotation.ok) return { ok: false, reason: "cooldown" }
    // A failed rotation should be retried immediately rather than sitting out
    // the cooldown.
  }

  const current = {
    startedBy: sessionID,
    promise: doRotate(script, options.rotationTimeoutMs).finally(() => {
      if (rotationInFlight === current) rotationInFlight = undefined
    }),
  }
  rotationInFlight = current

  const result = await current.promise
  if (result.ok) state.rotations++
  return result
}

export default Plugin.define({
  id: "opencode-warp.rotate",
  async setup(ctx) {
    // probe.sh / the CLI preflight set this while testing the ingress. Rotating
    // there would recurse into (or race) the caller's own recovery.
    if (process.env.OPENCODE_WARP_NO_ROTATE === "1") return
    if (!envBool("OPENCODE_WARP_PLUGIN", true)) return
    if (!envBool("OPENCODE_WARP_AUTO_ROTATE", true)) return
    if (!warpProxyActive()) return

    const opts = (ctx.options ?? {}) as Options
    const script = await findScript(opts.script)
    if (!script) {
      debug("warp-rotate.sh not executable; live recovery disabled")
      return
    }

    const config = {
      freeOnly: opts.freeOnly ?? envBool("OPENCODE_WARP_PLUGIN_FREE_ONLY", true),
      // One rotation is enough to test a new egress. A second usually lands
      // on the same per-model bucket and only churns registrations.
      maxRotationsPerSession:
        opts.maxRotationsPerSession ??
        envInt("OPENCODE_WARP_PLUGIN_MAX_ROTATIONS", 1),
      cooldownMs: opts.cooldownMs ?? envInt("OPENCODE_WARP_PLUGIN_COOLDOWN_MS", 5000),
      retryDelayMs: opts.retryDelayMs ?? envInt("OPENCODE_WARP_PLUGIN_RETRY_DELAY_MS", 1500),
      rotationTimeoutMs:
        opts.rotationTimeoutMs ?? envInt("OPENCODE_WARP_PLUGIN_TIMEOUT_MS", 90_000),
    }

    debug(
      `active: script=${script} proxy=127.0.0.1:${proxyPort()} ` +
        `maxRotations=${config.maxRotationsPerSession} cooldownMs=${config.cooldownMs}`,
    )

    const httpRegistration = await ctx.session.hook("http.response", (event) => {
      const response = event.response
      if (response.status !== 429) return

      const headers = responseHeaders(response)
      const parsedDelayMs = retryAfterMs(headers["retry-after"] ?? null)
      last429.set(event.sessionID, { at: Date.now(), headers, parsedDelayMs })
      log({
        event: "http.response.429",
        sessionID: event.sessionID,
        model: event.model,
        headers,
        parsedDelayMs,
      })
    })

    const retryRegistration = await ctx.session.hook("retry", async (event) => {
      if (!quotaError(event.error)) return
      if (config.freeOnly && !freeModel(event.model)) return

      const observed = last429.get(event.sessionID)
      const result = await rotateWarp(event.sessionID, script, config)
      if (result.ok) {
        const reason = result.reused ? "reused recent rotation" : "rotated WARP ingress"
        debug(`${reason} for ${event.sessionID}; retrying in ${config.retryDelayMs}ms`)
        log({
          event: "warp.rotate",
          ok: true,
          reused: result.reused === true,
          sessionID: event.sessionID,
          agent: event.agent,
          model: event.model,
          attempt: event.attempt,
          error: { type: event.error.type, status: event.error.status },
          headers: observed?.headers,
          retryAfterMs: observed?.parsedDelayMs,
        })
        last429.delete(event.sessionID)
        event.decision = { retry: true, delay: config.retryDelayMs }
        return
      }

      debug(
        `rotation not applied for ${event.sessionID}: ${result.reason ?? `exit ${result.code}`}`,
      )
      // Do not fall through to OpenCode's proposed policy when we cannot
      // rotate. The free-tier 429 carries a retry-after measured in hours
      // (until the UTC reset), which looks like a hung session. Failing the
      // request immediately is clearer, and a manual retry still works once
      // the quota resets or a rotation succeeds.
      event.decision = { retry: false }
      log({
        event: "warp.rotate",
        ok: false,
        reason: result.reason ?? `exit ${result.code}`,
        gaveUp: true,
        sessionID: event.sessionID,
        agent: event.agent,
        model: event.model,
        attempt: event.attempt,
        error: { type: event.error.type, status: event.error.status },
        headers: observed?.headers,
        retryAfterMs: observed?.parsedDelayMs,
      })
    })

    return async () => {
      await Promise.allSettled([httpRegistration.dispose(), retryRegistration.dispose()])
    }
  },
})
