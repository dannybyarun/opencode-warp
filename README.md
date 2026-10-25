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

## Supported systems

| Platform | Status |
|---|---|
| Debian / Ubuntu / Raspbian | ✅ official `.deb` |
| RHEL / Rocky / Alma / CentOS / Fedora / Oracle Linux | ✅ official `.rpm` |
| Windows 10/11 (x64 / arm64) | 🟡 native PowerShell port; installer and offline tests pass, real WARP/opencode-on-Windows not yet verified here |
| Arch / openSUSE / Alpine | ❌ no official package — install WARP yourself, then `./setup.sh --skip-warp-package` |
| macOS | ⚠️ partial; different install path, behaviour varies |
| Containers (Docker, most sandboxes) | ❌ almost always rejected |

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
`setup.sh` fetches the **official installer** from `https://opencode.ai/install`
and runs it.

It downloads to a temp file and **verifies the first line is a bash shebang
before executing** — refusing to run anything that looks like an HTML error
page. It does not blindly pipe `curl` into `bash`.

Note: the npm package `opencode-ai` is **not** used. It currently ships
`1.x` while the official installer delivers `2.x` — npm would install
something stale.

On Windows, `setup.ps1` first tries `npm install -g @opencode/cli@latest`
(OpenCode 2). If npm is unavailable or the install fails, it downloads the
official standalone `opencode-windows-x64.zip` / `opencode-windows-arm64.zip`
and installs `opencode.exe` into `%USERPROFILE%\.opencode\bin`. It never uses
the stale `opencode-ai` package.

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
(opencode rejects that flag on `serve`):

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
   through WARP to the same OpenAI-compatible endpoint OpenCode uses
   (`https://opencode.ai/inference/openai/v1/chat/completions`, bearer token
   `public`). It does not start opencode and does not create a session.
3. If throttled, `warp-rotate.sh` / `warp-rotate.ps1` deletes the anonymous
   WARP registration, creates a new one, reconnects in proxy mode, and probes
   again. It retries up to `WARP_ROTATE_ATTEMPTS` times (default 2), then warns
   and lets opencode start anyway.
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
your free-tier quota. It no longer creates a session or starts the CLI, which
is why the log hint is still used instead of probing on every launch.

| Variable | Meaning |
|---|---|
| `OPENCODE_WARP_AUTO_ROTATE=0` | disable all automatic rotation (launch-time and live plugin) |
| `OPENCODE_WARP_FORCE_PROBE=1` | probe even if the log has no recent 429 |
| `WARP_ROTATE_ATTEMPTS=3` | registration attempts (default 2) |
| `OPENCODE_WARP_ROTATE_STRICT=1` | exit instead of starting opencode when recovery fails or no verdict is available |
| `OPENCODE_WARP_LOG=/path` | use a specific opencode log |
| `PROBE_MODE=cli` | probe through `opencode run` instead of the raw API |
| `PROBE_API_URL=...` | override the chat-completions endpoint |
| `PROBE_API_KEY=...` | bearer token for the probe (default `public`) |
| `PROBE_MODEL=...` | model id for the probe (default `opencode/deepseek-v4.1-flash-free`) |
| `PROBE_DIRECT=1` | bypass the WARP proxy for the probe (same as `PROXY=""`) |
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
capped at two physical rotations. OpenCode's own hard retry-attempt limit still
applies, so a session that has already exhausted its retries can still fail.

The plugin appends its decisions to
`~/.local/share/opencode/ratelimit-retry.jsonl` (`OPENCODE_RATELIMIT_LOG`
overrides the path). The file records every observed 429 with `retry-after` /
`cf-ray`, plus each rotation attempt and its outcome.

| Variable | Meaning |
|---|---|
| `OPENCODE_WARP_PLUGIN=0` | disable the live plugin |
| `OPENCODE_WARP_PLUGIN_MAX_ROTATIONS=3` | physical rotations per session (default 2) |
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

- **It does not make you immune to rate limits.** opencode's free tier
  (`opencode.ai/inference`) enforces a daily quota that resets at **00:00 UTC**.
  Switching IP does not remove the cap; it may move you to a different
  bucket, or it may not.
- **The endpoint is not client-locked.** The same `Authorization: Bearer
  public` credential OpenCode uses works from any HTTP client. What limits you
  is the free bucket, not the OpenCode client identity — so an API-only server
  or a direct `curl` hits exactly the same quota.
- **It does not guarantee a different IP.** WARP assigns an address from
  Cloudflare's own pool; you cannot choose one. That is why the helper probes
  after each rotation instead of assuming success.
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

### What we actually observed

Tested with a controlled A/B on the same machine, same minute, same model —
only the egress differed:

| Egress | Result |
|---|---|
| `35.252.208.177` (GCP NAT) | HTTP 429 `FreeUsageLimitError` |
| `104.28.237.252` (WARP) | HTTP 200, normal completion |
| three separate Tor exits | HTTP 429 (all of them) |

So the limit **is** determined by source IP. But WARP succeeded while Tor
failed, which leaves open whether that was because WARP's address was simply
an unthrottled IP, or because Cloudflare privileges its own WARP network on a
Cloudflare-fronted service. **This repo cannot tell you which.**

Also note: the difference is only observable *while your quota is spent*
(i.e. before 00:00 UTC). After the reset both proxied and direct requests
succeed, so the effect looks like nothing.

---

## Files

| Path | Purpose |
|---|---|
| `setup.sh` | Linux installer (idempotent, safe to re-run) |
| `opencode-warp` | Linux wrapper; installed to `/usr/local/bin` |
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

Expected totals: **88** Linux checks and **169** Windows checks.

---

## Uninstall

Linux:

```bash
sudo ./uninstall.sh            # wrapper + helpers + bashrc block + apt repo
sudo ./uninstall.sh --purge    # also the package and device registration
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

---

## License

MIT.
