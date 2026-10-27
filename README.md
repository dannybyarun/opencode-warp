# opencode-warp

Run [opencode](https://opencode.ai) through a **local Cloudflare WARP proxy**,
so it egresses from a different IP than the machine's normal address.

```bash
# Linux / macOS shells
opencode --stand run -m opencode/deepseek-v4.1-flash-free "hello"
```

```powershell
# Windows PowerShell
opencode --stand run -m opencode/deepseek-v4.1-flash-free "hello"
```

WARP runs in **proxy mode** on `127.0.0.1:40000`. Your machine's normal routing
and default egress IP are untouched — only the traffic you explicitly send
through the wrapper changes.

---

## Quick start

### Linux

```bash
git clone <this-repo>
cd opencode-warp
sudo ./setup.sh

source ~/.bashrc        # or open a new shell
opencode --stand run -m opencode/deepseek-v4.1-flash-free "hello"
```

`setup.sh` checks every requirement **before** it changes anything, and fails
with an explanation instead of dying halfway through.

### Windows

```powershell
git clone <this-repo>
cd opencode-warp

# If WARP is not installed yet, use an elevated PowerShell for this step.
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\setup.ps1

# Open a new PowerShell window, then:
opencode --stand run -m opencode/deepseek-v4.1-flash-free "hello"
```

`setup.ps1` installs per-user files under `%LOCALAPPDATA%\opencode-warp`, adds
that directory to your user `PATH`, installs the live 429 plugin, and adds an
`opencode --stand` function to your PowerShell profiles. It is idempotent and
safe to re-run.

If WARP is already installed and connected, the setup can run as a normal user.
Installing WARP itself, starting its service, or using `-Purge` needs an
elevated PowerShell (right-click → **Run as administrator**).

In cmd.exe, where a PowerShell function is not available, use the shims:

```bat
opencode-stand run -m opencode/deepseek-v4.1-flash-free "hello"
opencode-warp  run -m opencode/deepseek-v4.1-flash-free "hello"
```

If `opencode --stand` is not recognised on Windows, the profile either was not
loaded yet (open a new window) or execution policy blocks profiles. The
`opencode-warp` / `opencode-stand` shims call PowerShell with
`-ExecutionPolicy Bypass` and work regardless; alternatively set
`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

If the free tier is already throttled, `opencode --stand` probes the WARP
ingress and rotates the anonymous registration before starting. A plugin also
handles a 429 that happens mid-session. See
[Automatic recovery](#automatic-recovery-when-already-rate-limited).

## Optional: usque IPv4 MASQUE proxy

Official WARP can egress over IPv6 ranges that some providers flag. `usque` is
an open-source MASQUE client that can provide an IPv4 egress and expose it as
a local HTTP proxy. Install it as a systemd service on `127.0.0.1:40001`:

```bash
sudo ./usque-setup.sh
```

The installer downloads a pinned `usque` release, verifies its SHA-256
checksum, registers an anonymous WARP account if `/etc/usque/config.json` does
not exist, and enables `usque-proxy.service`. The registration is written with
mode `600` and is never stored in this repository.

`opencode-warp` prefers a running usque proxy on `127.0.0.1:40001` and falls
back to official WARP on `127.0.0.1:40000` when it is not available. The
normal command works unchanged:

```bash
opencode --stand run -m opencode/deepseek-v4.1-flash-free "hello"
```

Force usque in any shell:

```bash
opencode-usque run -m opencode/deepseek-v4.1-flash-free "hello"
```

Automatic WARP rotation is disabled while usque is selected, because
`warp-rotate.sh` and the live plugin rotate the official WARP registration. To
deliberately get a fresh usque identity:

```bash
sudo USQUE_REREGISTER=1 ./usque-setup.sh
```

Remove the service and wrapper (the registration is kept):

```bash
sudo ./usque-setup.sh --uninstall
```

Use `--purge` to also remove `/etc/usque` and the `usque` binary.

## Supported systems

| Platform | Status |
|---|---|
| Debian / Ubuntu / Raspbian | ✅ official `.deb` |
| RHEL / Rocky / Alma / CentOS / Fedora / Oracle Linux | ✅ official `.rpm` |
| Windows 10/11 (x64 / arm64) | 🟡 native PowerShell port; installer and offline tests pass, real WARP/opencode-on-Windows not yet verified here |
| Arch / openSUSE / Alpine | ❌ no official package — install WARP yourself, then `./setup.sh --skip-warp-package` |
| macOS | ⚠️ wrapper only; `setup.sh` is Linux-only — install WARP + opencode manually |
| Containers (Docker, most sandboxes) | ❌ almost always rejected; needs `/dev/net/tun` and systemd |

On Windows, the OpenCode project still recommends WSL for the smoothest
experience and its native Windows build is less battle-tested. This repo does
not require WSL: `setup.ps1` uses the official standalone Windows CLI (or the
npm `@opencode/cli` package) and the Windows WARP client in local proxy mode.
Native OpenCode-on-Windows issues are upstream's, not the wrapper's.

### Why containers usually fail

WARP needs **both** `/dev/net/tun` and a working **systemd** as PID 1. Most
containers have neither. `setup.sh` detects this up front and tells you,
rather than failing partway through an install. Pass
`--skip-warp-package` if WARP is already running in proxy mode on
`127.0.0.1:40000`.

## opencode is installed automatically

On Linux, if no opencode binary is found on `PATH` or in `~/.opencode/bin`,
`setup.sh` fetches the **OpenCode 2 installer** from
`https://opencode.ai/v2/install` and runs it. It does not use the legacy
`https://opencode.ai/install` endpoint, which only installs OpenCode 1
(`1.x`).

It downloads to a temp file and **verifies the first line is a bash shebang
before executing** — refusing to run anything that looks like an HTML error
page. It does not blindly pipe `curl` into `bash`.

Note: the npm package `opencode-ai` is also OpenCode 1 (`1.x`). The OpenCode 2
package is `@opencode/cli`, which is what the Windows setup uses.

On Windows, `setup.ps1` first tries `npm install -g @opencode/cli@latest`
(OpenCode 2). If npm is unavailable or the install fails, it downloads the
official standalone `opencode-windows-x64.zip` / `opencode-windows-arm64.zip`
and installs `opencode.exe` into `%USERPROFILE%\.opencode\bin`. It never uses
the stale `opencode-ai` package.

Both installers verify the result is **OpenCode 2**. A fresh install that is
still 1.x is an error, because `serve`/`--server` and the v2 API do not exist
there. An existing 1.x install is left alone, but setup warns and suggests
`opencode upgrade --major`.

## Survives opencode upgrades

The wrapper depends on `run --standalone` for `run` and TUI sessions. If a
future opencode removed that flag, the proxy env vars would be **silently
ignored** (the background service is what actually makes inference calls) and
opencode would quietly burn your normal quota — the worst possible failure,
because it looks like success.

So `setup.sh` / `setup.ps1` and both wrappers **feature-detect** `--standalone`
and refuse to run without it, printing the offending version. Loud failure
beats silent fallthrough. `serve` and `--server` are exempt because they never
get the flag: `serve` already owns a foreground server, and `--server`'s
server owns the egress.

---

## Usage

| Command | Behaviour |
|---|---|
| `opencode --stand run -m <model> "msg"` | bash/PowerShell: through WARP, adds `--standalone`, auto-recovers if throttled |
| `opencode --stand` | bash/PowerShell: TUI, through WARP, auto-recovers if throttled |
| `opencode --stand serve --port 4096` | API-only server through WARP (no `--standalone`) |
| `opencode --stand run --server <url> ...` | connect to an existing server; passthrough |
| `opencode run -m <model> "msg"` | unchanged — normal egress |
| `opencode-warp run -m <model> "msg"` | same as `--stand`, works in **any** shell |
| `opencode-stand run -m <model> "msg"` | Windows cmd.exe convenience for `--stand` |

The `run` subcommand is **still required** for one-shot prompts. `--stand`
injects `--standalone`; it does not invent the subcommand. Omitting it gives a
confusing `Did you mean this?` argument error.

Use `opencode-warp` directly from scripts, cron, zsh, fish, or cmd.exe — it is a
plain executable. The `opencode --stand` form is a bash function on Linux/macOS
and a PowerShell profile function on Windows.

If `opencode --stand` reports `Unrecognized flag: --stand`, the shortcut is not
loaded in that shell yet. Run `source ~/.bashrc` (Linux/macOS) or `. $PROFILE`
(PowerShell), open a new terminal, or call `opencode-warp` directly.

---

## Windows layout

`setup.ps1` changes only these per-user locations (plus the WARP install
itself, if needed):

| Path | Purpose |
|---|---|
| `%LOCALAPPDATA%\opencode-warp\bin` | wrapper, probe, rotate and uninstall scripts, plus `.cmd` shims |
| `%LOCALAPPDATA%\opencode-warp\state` | `last-ok` / `last-throttled` state and the rotation lock |
| `%USERPROFILE%\.opencode\bin\opencode.exe` | standalone opencode, when the zip fallback is used |
| `%USERPROFILE%\.config\opencode\plugins` | live 429 plugin (the installer also checks `%APPDATA%\opencode`) |
| User `PATH` | adds `%LOCALAPPDATA%\opencode-warp\bin` |
| PowerShell profiles | marked `opencode --stand` block, with a timestamped backup |

Set `OPENCODE_CONFIG_DIR` (the official OpenCode override) or
`OPENCODE_WARP_CONFIG_DIR` before running setup to install the plugin into a
custom config directory.

WARP uses the standard Windows client. `setup.ps1` tries:

```text
warp-cli --accept-tos registration new
warp-cli --accept-tos mode proxy        # fallback: set-mode proxy
warp-cli --accept-tos proxy port 40000  # fallback: set-proxy-port 40000
warp-cli --accept-tos connect
```

If the installed `warp-cli` does not expose those subcommands, enable
**Settings → Advanced → Configure Proxy** in the Cloudflare WARP app, choose
local proxy mode on port `40000`, then re-run setup with `-SkipWarpInstall`.
Setup refuses to continue if WARP reports a non-proxy mode after connecting,
because that would change the machine's normal routing.

Installer options:

```powershell
.\windows\setup.ps1                          # full install (WARP may need elevation)
.\windows\setup.ps1 -SkipWarpInstall         # WARP already installed / configured by hand
.\windows\setup.ps1 -SkipOpenCodeInstall     # opencode already installed
.\windows\setup.ps1 -NoProfile -NoPath       # files only
.\windows\setup.ps1 -ValidateOnly            # check this checkout, change nothing
```

`-SkipOpenCodeInstall` makes setup fail if no opencode binary exists, rather
than silently continuing without one. `-SkipWarpInstall` does the same for
WARP.

## API-only server

`opencode serve` is the headless V2 API and web server. The server process owns
the inference egress, so it gets the WARP proxy env and **not** `--standalone`
(opencode rejects that flag on `serve`). It also gets both recovery layers:
the launch-time preflight runs before the server starts, and the live 429
plugin is active inside the server process, so a throttle mid-session rotates
WARP and retries just like `--stand`:

```bash
opencode --stand serve --hostname 127.0.0.1 --port 4096
# server listening on http://127.0.0.1:4096
# server password ...
```

Clients connect to it. They do not need WARP themselves; the server does the
inference calls:

```bash
OPENCODE_PASSWORD=<password> opencode --server http://127.0.0.1:4096
OPENCODE_PASSWORD=<password> opencode run --server http://127.0.0.1:4096 -m opencode/deepseek-v4.1-flash-free "hello"
OPENCODE_PASSWORD=<password> opencode api --server http://127.0.0.1:4096 get /api/info
```

`--server` is a per-subcommand flag, so it goes **after** `run`/`api` (or on
the bare TUI command, which has no subcommand). The wrapper recognises it
anywhere in the argument list and stays out of the way.

`opencode --stand run --server <url> ...` is a passthrough: it adds neither
`--standalone` nor the proxy env, because the target server owns its egress.
It exists so the shortcut does not break when you point it at a server.


---

## Why these flags exist

Two failure modes are easy to hit, and both were found the hard way:

1. **`--standalone` is mandatory for `run`/TUI.** opencode's *background
   service* is what actually makes inference calls. Env vars on the CLI never
   reach it, so without `--standalone` the proxy is silently unused. `serve`
   is already a foreground server (and rejects the flag); `--server` connects
   to a server whose egress this process does not own.
2. **`NO_PROXY` is mandatory.** Without `NO_PROXY=127.0.0.1,localhost`, opencode
   proxies its own local service traffic, gets `502`s, and dies with
   `service.ensure` errors.

The wrapper handles both. If you drive opencode another way, you must too.

---

## Automatic recovery when already rate limited

`opencode --stand` (and `opencode-warp`) can recover automatically:

1. It looks at opencode's own log for the most recent rate-limit error.
   It only probes when that error is newer than the last successful check, so
   healthy launches do not pay for an extra request.
2. `probe.sh` (Linux) or `probe.ps1` (Windows) sends one tiny `PONG` request
   through WARP. The rotation helpers run it with `PROBE_MODE=cli`, so the
   verdict comes from the same `opencode run` path the TUI uses. That costs
   one short model request and creates a session. Set `PROBE_MODE=api` to use
   the cheaper raw endpoint instead — but the hosted endpoint can reject a
   bare API request even when the real client succeeds, so API mode is not
   authoritative for free models.
3. If throttled, `warp-rotate.sh` / `warp-rotate.ps1` deletes the anonymous
   WARP registration, creates a new one, reconnects in proxy mode, and probes
   again. On Linux, it also compares the public egress IP before and after; a
   registration that leaves the same IP is treated as a failed rotation,
   because the probe would just hit the same bucket. It retries up to
   `WARP_ROTATE_ATTEMPTS` times (default 1), then warns and lets opencode
   start anyway. Every probe also prints the observed `ip=`, `loc=`, and
   `warp=` egress — including failed attempts — so you can verify which
   ingress the model request actually used. A successful IP change still does
   not guarantee a fresh per-model bucket; if the probe stays 429, switch
   models instead of rotating again.
4. The probe itself never rotates. It sets `OPENCODE_WARP_NO_ROTATE=1`, so the
   wrapper it launches cannot start a recursive preflight.

A connection reset (`ECONNRESET`, `socket connection was closed`, and similar
transport errors) counts as a rotate-worthy verdict (`exit 3`), not as
"no verdict" — a broken WARP ingress is exactly what a fresh registration
usually fixes. The probe stops as soon as the socket error appears instead of
waiting for the full timeout.

OpenCode's own free-tier notices are treated as throttling too: both
`Free usage limit reached` and the TUI wording
`You've used today's free messages` produce `exit 1`, so launch-time recovery
and the live plugin rotate instead of treating them as an unknown error.

If the probe still cannot produce a verdict (auth error, missing binary, a
silent hang), the wrapper starts opencode **only if the local WARP proxy is
reachable**, and prints a warning. It refuses to start when the proxy itself is
down, or when `OPENCODE_WARP_ROTATE_STRICT=1` is set.

Each probe is a real model request (one short `PONG`), so it counts against
your free-tier quota. The rotation helpers use the CLI probe, which creates a
session; API mode does not. Either way, the log hint is used instead of
probing on every launch to keep the cost down.

| Variable | Meaning |
|---|---|
| `OPENCODE_WARP_AUTO_ROTATE=0` | disable all automatic rotation (launch-time and live plugin) |
| `OPENCODE_WARP_USQUE=0` | force official WARP; disable usque auto-detection |
| `USQUE_PROXY_PORT=40001` | usque HTTP proxy port |
| `USQUE_REREGISTER=1` | `usque-setup.sh`: replace the existing registration |
| `OPENCODE_WARP_FORCE_PROBE=1` | probe even if the log has no recent 429 |
| `WARP_ROTATE_ATTEMPTS=3` | registration attempts (default 1) |
| `OPENCODE_WARP_ROTATE_STRICT=1` | exit instead of starting opencode when recovery fails or no verdict is available |
| `OPENCODE_WARP_LOG=/path` | use a specific opencode log |
| `PROBE_MODE=cli` | probe through `opencode run` instead of the raw API |
| `PROBE_API_URL=...` | override the chat-completions endpoint |
| `PROBE_API_KEY=...` | bearer token for the probe (default `public`) |
| `PROBE_MODEL=...` | model id for the probe (default `opencode/deepseek-v4.1-flash-free`) |
| `PROBE_DIRECT=1` | bypass the WARP proxy for the raw API probe (API mode only) |
| `OPENCODE_WARP_HOME=/path` | Windows per-user root (default `%LOCALAPPDATA%\opencode-warp`) |
| `OPENCODE_WARP_STATE_DIR=/path` | override the `last-ok` / `last-throttled` state directory |
| `OPENCODE_WARP_WARP_CLI=/path/warp-cli.exe` | Windows: override the WARP CLI path |
| `OPENCODE_WARP_OPENCODE=/path/opencode.exe` | override the opencode binary |
| `OPENCODE_WARP_POWERSHELL=/path/pwsh.exe` | Windows: PowerShell used for the helper scripts |
| `OPENCODE_WARP_CURL=/path/curl.exe` | override `curl` used for proxy/trace checks |

### Live 429 recovery (plugin)

`setup.sh` and `setup.ps1` also install `opencode-warp-rotate.ts` into
`${XDG_CONFIG_HOME:-~/.config}/opencode/plugins/` on Linux, or the equivalent
`%USERPROFILE%\.config\opencode\plugins` (falling back to
`%APPDATA%\opencode\plugins`) on Windows. OpenCode loads it automatically. It
stays inert unless the session is using the local WARP proxy (`HTTPS_PROXY`
points at `127.0.0.1:40000`) and the model id contains `free`.

When a model request fails with 429 / `Free usage limit reached`, or reports
`You've used today's free messages`, the plugin:

1. records `retry-after` and `cf-ray` in the 429 log,
2. runs `warp-rotate.sh --rotate-only` on Linux or
   `warp-rotate.ps1 --rotate-only` on Windows — no extra probe request, so it
   cannot deadlock the session that is waiting for the rotation,
3. sets OpenCode's retry decision to retry the same request after 1.5 seconds.

If a rotation cannot be applied — the per-session cap is reached, a cooldown is
active, or the helper fails — the plugin vetoes the retry. The request fails
immediately instead of falling back to the provider's `retry-after`, which for
the free tier is often several hours (until the 00:00 UTC reset) and looks like
a hung session.

One rotation is shared by all sessions. A successful rotation is offered to
other sessions for 5 seconds without creating another registration; the
session that used it will not rotate again inside that window. Each session is
capped at **one** physical rotation by default
(`OPENCODE_WARP_PLUGIN_MAX_ROTATIONS`). One rotation is enough to test a new
egress; a second usually lands on the same per-model bucket and only churns
registrations. OpenCode's own hard retry-attempt limit still applies, so a
session that has already exhausted its retries can still fail.

The plugin appends its decisions to
`~/.local/share/opencode/ratelimit-retry.jsonl` (`OPENCODE_RATELIMIT_LOG`
overrides the path). The file records every observed 429 with `retry-after` /
`cf-ray`, plus each rotation attempt and its outcome.

| Variable | Meaning |
|---|---|
| `OPENCODE_WARP_PLUGIN=0` | disable the live plugin |
| `OPENCODE_WARP_PLUGIN_MAX_ROTATIONS=3` | physical rotations per session (default 1) |
| `OPENCODE_WARP_PLUGIN_COOLDOWN_MS=5000` | how long a fresh rotation is reusable |
| `OPENCODE_WARP_PLUGIN_TIMEOUT_MS=90000` | rotation subprocess timeout |
| `OPENCODE_WARP_PLUGIN_DEBUG=1` | log plugin decisions to stderr |
| `OPENCODE_WARP_PLUGIN_FREE_ONLY=0` | rotate for non-free models too |
| `OPENCODE_WARP_ROTATE=/path/warp-rotate.sh` | override the rotation helper (`.ps1` / `.cmd` accepted on Windows) |

The retry path was validated end to end against a fake OpenAI-compatible
provider: the first request returned `429 Free usage limit reached`, the plugin
ran `warp-rotate.sh --rotate-only`, and OpenCode's retry then completed
successfully.

The wrapper skips the preflight when you pass an explicit non-free
`-m`/`--model`, because rotating the free bucket would not help that model.

Manual recovery uses the same code path:

```bash
# Linux
./warp-rotate.sh               # probe, rotate only if throttled
./warp-rotate.sh --force       # always rotate, then probe
./warp-rotate.sh --rotate-only # rotate and verify the proxy, no model probe
./probe.sh                     # one-shot verdict, never rotates
```

```powershell
# Windows (from any PowerShell)
& "$env:LOCALAPPDATA\opencode-warp\bin\probe.ps1"
& "$env:LOCALAPPDATA\opencode-warp\bin\warp-rotate.ps1"
& "$env:LOCALAPPDATA\opencode-warp\bin\warp-rotate.ps1" --force
& "$env:LOCALAPPDATA\opencode-warp\bin\warp-rotate.ps1" --rotate-only
```

The same scripts are on `PATH` as `probe` and `warp-rotate` in cmd.exe and
PowerShell after setup.

Note: there is **no `reconnect` subcommand** — `warp-cli --accept-tos
reconnect` fails with *unrecognized subcommand*. Both helpers do
disconnect → registration delete → registration new → mode proxy → connect.
On Windows the ordering is the same, with an extra `proxy port` step when the
CLI supports it.

### What it still cannot do

- **It does not make you immune to rate limits.** The free tier enforces a
  **per-model** daily quota that resets at **00:00 UTC**. The bucket is also
  tied to the network/egress, and VPN/proxy ranges can be pre-flagged. A new
  WARP registration changes the IP and WARP account, but it does not reset a
  per-model bucket. On 2026-10-26, DeepSeek/GLM/MiMo/Big Pickle were 429
  through WARP while Nemotron/Beam were 200 on the same egress. DeepSeek, GLM,
  Nemotron, and Beam were all 200 direct. If a 429 survives one rotation,
  switch models with `/models` or use direct egress instead of rotating again.
- **The raw endpoint is not a reliable quota probe for free models.** The
  hosted endpoint now gates free models on the real OpenCode client; a bare
  `Authorization: Bearer public` request with a minimal body can return
  `FreeUsageLimitError` even when `opencode run` succeeds on the same egress.
  Use `PROBE_MODE=cli` for a verdict that matches the client. Raw API mode is
  still useful for checking the endpoint and transport, but its 429 is not
  proof that the TUI will fail.
- **It does not guarantee a different IP.** WARP assigns an address from
  Cloudflare's own pool; you cannot choose one. The Linux helper now reads the
  egress IP before and after each rotation and fails if it did not change, so
  a no-op rotation no longer looks successful while hitting the same throttled
  bucket. The Windows helper still only checks that the proxy is reachable.
- **It churns device registrations.** Every attempt creates a new anonymous
  Cloudflare device. Keep `WARP_ROTATE_ATTEMPTS` and
  `OPENCODE_WARP_PLUGIN_MAX_ROTATIONS` small.

### Windows limitations

- The Windows port is checked by offline PowerShell tests and a static
  Windows PowerShell 5.1 compatibility scan. It has **not** been run against a
  live Cloudflare WARP service or a real native opencode build in this repo.
  WARP CLI subcommands can vary between client versions; setup tries the
  documented spellings and tells you to configure the WARP GUI when they fail.
- WARP's Windows client is a system service. Installing it, starting it, or
  changing its registration may require an elevated shell. Setup refuses to
  continue when WARP reports a non-proxy mode, rather than silently switching
  your machine to a full tunnel.
- Windows PowerShell 5.1 is the target; PowerShell 7 is not required. The test
  suite can run under pwsh on Linux, but that is a stubbed environment, not a
  Windows host.
- The `opencode --stand` form is a PowerShell profile function. cmd.exe and
  restricted execution policies must use `opencode-warp` / `opencode-stand`.
- Native opencode on Windows is less battle-tested than WSL; upstream currently
  recommends WSL. That is independent of this wrapper.

### What we actually observed (2026-10-26)

The free-tier policy changed around 2026-10-25. The old model — one daily
bucket per source IP — no longer explains the results. On the same machine,
same minute, with OpenCode 2.1.4 and the real `opencode run` client:

| Egress | Model | Result |
|---|---|---|
| WARP `2a09:bac5:b040:3705::57b:b` (SEA) | `deepseek-v4.1-flash-free` | 429 `FreeUsageLimitError` |
| WARP (same) | `glm-5.3-flash-free` | 429 |
| WARP (same) | `mimo-v2.6-flash-free` | 429 |
| WARP (same) | `big-pickle` | 429 |
| WARP (same) | `nemotron-3.5-lightning-free` | 200 `PONG` |
| WARP (same) | `beam-free` | 200 `PONG` |
| direct `136.66.114.215` (SEA) | `deepseek-v4.1-flash-free` | 200 `PONG` |
| direct (same) | `glm-5.3-flash-free` | 200 `PONG` |
| direct (same) | `nemotron-3.5-lightning-free` | 200 `PONG` |
| direct (same) | `beam-free` | 200 `PONG` |
| Tor exits (US and NL) | `deepseek-v4.1-flash-free` | 429 |

Rotation was verified to create a new WARP registration ID, account ID,
license, and egress IP (`2a09:bac1:76a0:dba8::4ff:21` →
`2a09:bac5:b040:3705::57b:b`). DeepSeek still returned 429 on the new IP. A
fresh OpenCode project and session on a Tor exit also returned 429. So the
quota is not keyed only by IP, project, or session.

The current service appears to enforce a **per-model free bucket tied to the
egress/network**, with VPN/proxy ranges pre-flagged for the popular models.
WARP's range is flagged for DeepSeek/GLM/MiMo/Big Pickle but not for
Nemotron/Beam. Direct egress still has a fresh bucket for the tested models.
`Retry-After` pointed at the 00:00 UTC reset.

**The raw API probe is not a drop-in stand-in for the client.** At the same
time `opencode run` returned `PONG` on direct egress, a minimal `curl` (and a
Bun `fetch`) with `Authorization: Bearer public`, the CLI headers, and a
minimal body returned 429. The real client sends a large OpenCode system
prompt/tool payload; the hosted endpoint appears to gate free models on that
client identity. Use `PROBE_MODE=cli` when the verdict must match the TUI.

---

## Files

| Path | Purpose |
|---|---|
| `setup.sh` | Linux installer (idempotent, safe to re-run) |
| `usque-setup.sh` | optional Linux installer for the usque IPv4 MASQUE proxy (`--uninstall`, `--purge`) |
| `usque-proxy.service.in` | systemd unit template used by `usque-setup.sh` |
| `opencode-warp` | Linux wrapper; installed to `/usr/local/bin` |
| `opencode-usque` | wrapper that forces the usque proxy; installed to `/usr/local/bin` |
| `uninstall.sh` | removes the Linux wrapper, helpers, bashrc block, apt repo |
| `probe.sh` | one-shot verdict: is this ingress throttled? Raw API by default; `0` ok, `1` throttled, `2` no verdict, `3` transport failure |
| `warp-rotate.sh` | probe → rotate device registration → probe (`0` ok, `1` still throttled/failing, `2` no verdict) |
| `opencode-warp-rotate.ts` | live-session 429 plugin: rotate WARP and retry the request (both platforms) |
| `windows/setup.ps1` | Windows installer: files, plugin, PATH, profile, WARP, opencode |
| `windows/opencode-warp.ps1` | Windows wrapper: preflight, proxy env, `--standalone` |
| `windows/probe.ps1` | Windows one-shot verdict (same exit codes) |
| `windows/warp-rotate.ps1` | Windows probe → rotate → probe |
| `windows/common.ps1` | shared Windows helpers and path discovery |
| `windows/uninstall.ps1` | removes the Windows files, plugin, profile block and PATH entry (`-Purge` also WARP) |
| `windows/*.cmd` | cmd.exe shims for the wrapper, probe and rotate |
| `tests/run-tests.sh` | offline Linux regression tests with stubbed probe/rotate/opencode commands |
| `tests/windows/run-tests.ps1` | offline Windows regression tests with generated `.ps1` stubs |

On Linux, `probe.sh` and `warp-rotate.sh` are installed to
`/usr/local/lib/opencode-warp/`. On Windows, the `.ps1` helpers and `.cmd` shims
are installed to `%LOCALAPPDATA%\opencode-warp\bin`. The plugin is installed to
`${XDG_CONFIG_HOME:-~/.config}/opencode/plugins/` on Linux and the equivalent
directory under `%USERPROFILE%` on Windows. Both installers create a timestamped
backup before editing a shell profile.

---

## Tests

Linux:

```bash
./tests/run-tests.sh
```

Windows (works in Windows PowerShell 5.1 or pwsh; pwsh on Linux is also
supported for development):

```powershell
pwsh -NoProfile -File .\tests\windows\run-tests.ps1
# or
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\run-tests.ps1
```

Both suites are offline: they stub `opencode`, `warp-cli`, `curl`, and the
probe, so they never create a WARP registration or spend quota. They cover
every probe verdict in both API and CLI modes (success, throttled, transport
failure, no verdict, timeout), transport rotation and exhaustion, `--force` /
`--rotate-only`, preflight log detection, the wrapper's strict/fallback
startup policy, and the `serve`/`--server` argument routing. The Windows suite
also checks profile install/remove behaviour, the `.cmd` shims, and rejects
PowerShell 7-only syntax.

Expected totals: **129** Linux checks and **187** Windows checks.

---

## Uninstall

Linux:

```bash
sudo ./uninstall.sh            # wrapper + helpers + bashrc block + apt repo
sudo ./uninstall.sh --purge    # also the package and device registration
sudo ./usque-setup.sh --uninstall   # usque service + opencode-usque
sudo ./usque-setup.sh --purge       # also the usque binary + registration
```

Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\uninstall.ps1
# or, from the installed copy:
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\opencode-warp\bin\uninstall.ps1"
# elevated:
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\uninstall.ps1 -Purge
```

The Windows uninstaller removes the per-user files, plugin, marked PowerShell
profile block, `PATH` entry, and state directory. `-Purge` also uninstalls the
WARP package and deletes the anonymous registration; WARP application data
under `C:\ProgramData\Cloudflare` is left in place.

---

## Privacy note

`setup.sh` / `setup.ps1` runs `warp-cli registration new`, which creates an
**anonymous device registration** with Cloudflare — no email, no account login.
The Linux registration state lives in `/var/lib/cloudflare-warp/`; the Windows
client keeps its state under `C:\ProgramData\Cloudflare`. The `--purge` /
`-Purge` option deletes the registration; the Windows uninstaller deliberately
leaves the application-data directory in place.

When auto-recovery triggers — at launch or through the live plugin —
`warp-rotate.sh` / `warp-rotate.ps1` deletes that anonymous registration and
creates a new one. The launch-time path only does so when opencode's log shows
a recent rate-limit error (or when you pass `--force`); the live path only does
so after a 429 from a free model through the WARP proxy.

`usque-setup.sh` creates a **separate** anonymous registration through usque
and stores it in `/etc/usque/config.json` with mode `600`. It is independent of
the official WARP registration, is never written to this repository, and is
removed only by `usque-setup.sh --purge`.

---

## License

MIT.
