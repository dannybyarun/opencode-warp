# opencode-warp

Run [opencode](https://opencode.ai) through a **local Cloudflare WARP proxy**,
so it egresses from a different IP than the machine's normal address.

```bash
opencode --stand run -m opencode/deepseek-v4.1-flash-free "hello"
```

WARP runs in **proxy mode** on `127.0.0.1:40000`. Your machine's normal routing
and default egress IP are untouched — only the traffic you explicitly send
through the wrapper changes.

---

## Quick start

```bash
git clone <this-repo>
cd opencode-warp
sudo ./setup.sh

source ~/.bashrc        # or open a new shell
opencode --stand run -m opencode/deepseek-v4.1-flash-free "hello"
```

`setup.sh` checks every requirement **before** it changes anything, and fails
with an explanation instead of dying halfway through.

If the free tier is already throttled, `opencode --stand` probes the WARP
ingress and rotates the anonymous registration before starting. A plugin also
handles a 429 that happens mid-session. See
[Automatic recovery](#automatic-recovery-when-already-rate-limited).

## Supported systems

| Platform | Status |
|---|---|
| Debian / Ubuntu / Raspbian | ✅ official `.deb` |
| RHEL / Rocky / Alma / CentOS / Fedora / Oracle Linux | ✅ official `.rpm` |
| Arch / openSUSE / Alpine | ❌ no official package — install WARP yourself, then `./setup.sh --skip-warp-package` |
| macOS / Windows | ⚠️ partial; different install path, behaviour varies |
| Containers (Docker, most sandboxes) | ❌ almost always rejected |

### Why containers usually fail

WARP needs **both** `/dev/net/tun` and a working **systemd** as PID 1. Most
containers have neither. `setup.sh` detects this up front and tells you,
rather than failing partway through an install. Pass
`--skip-warp-package` if WARP is already running in proxy mode on
`127.0.0.1:40000`.

## opencode is installed automatically

If no opencode binary is found on `PATH` or in `~/.opencode/bin`,
`setup.sh` fetches the **official installer** from `https://opencode.ai/install`
and runs it.

It downloads to a temp file and **verifies the first line is a bash shebang
before executing** — refusing to run anything that looks like an HTML error
page. It does not blindly pipe `curl` into `bash`.

Note: the npm package `opencode-ai` is **not** used. It currently ships
`1.19.3` while the official installer delivers `2.0.31` — npm would install
something stale.

## Survives opencode upgrades

The wrapper depends on `run --standalone`. If a future opencode removed that
flag, the proxy env vars would be **silently ignored** (the background service
is what actually makes inference calls) and opencode would quietly burn your
normal quota — the worst possible failure, because it looks like success.

So both `setup.sh` and the wrapper **feature-detect** `--standalone` and refuse
to run without it, printing the offending version. Loud failure beats silent
fallthrough.

---

## Usage

| Command | Behaviour |
|---|---|
| `opencode --stand run -m <model> "msg"` | through WARP, adds `--standalone`, auto-recovers if throttled |
| `opencode --stand` | TUI, through WARP, auto-recovers if throttled |
| `opencode run -m <model> "msg"` | unchanged — normal egress |
| `opencode-warp run -m <model> "msg"` | same as `--stand`, works in **any** shell |

The `run` subcommand is **still required**. `--stand` injects `--standalone`;
it does not invent the subcommand. Omitting it gives a confusing
`Did you mean this?` argument error.

Use `opencode-warp` directly from scripts, cron, zsh, or fish — it is a plain
executable. The `opencode --stand` form is a bash convenience function defined
in `~/.bashrc`.

---

## Why these flags exist

Two failure modes are easy to hit, and both were found the hard way:

1. **`--standalone` is mandatory.** opencode's *background service* is what
   actually makes inference calls. Env vars on the CLI never reach it, so
   without `--standalone` the proxy is silently unused.
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
2. `probe.sh` sends one tiny `PONG` request through WARP.
3. If throttled, `warp-rotate.sh` deletes the anonymous WARP registration,
   creates a new one, reconnects in proxy mode, and probes again. It retries
   up to `WARP_ROTATE_ATTEMPTS` times (default 2), then warns and lets
   opencode start anyway.
4. `probe.sh` itself never rotates. It exports `OPENCODE_WARP_NO_ROTATE=1`,
   so the wrapper it launches cannot start a recursive preflight.

Each probe is a real `opencode run` (one short `PONG` request), so it creates
a small session and counts against your quota. That is why the log hint is
used instead of probing on every launch.

| Variable | Meaning |
|---|---|
| `OPENCODE_WARP_AUTO_ROTATE=0` | disable all automatic rotation (launch-time and live plugin) |
| `OPENCODE_WARP_FORCE_PROBE=1` | probe even if the log has no recent 429 |
| `WARP_ROTATE_ATTEMPTS=3` | registration attempts (default 2) |
| `OPENCODE_WARP_ROTATE_STRICT=1` | exit instead of starting opencode when recovery fails |
| `OPENCODE_WARP_LOG=/path` | use a specific opencode log |

### Live 429 recovery (plugin)

`setup.sh` also installs `opencode-warp-rotate.ts` into
`${XDG_CONFIG_HOME:-~/.config}/opencode/plugins/`. OpenCode loads it
automatically. It stays inert unless the session is using the local WARP
proxy (`HTTPS_PROXY` points at `127.0.0.1:40000`) and the model id contains
`free`.

When a model request fails with 429 / `Free usage limit reached`, the plugin:

1. records `retry-after` and `cf-ray` in the 429 log,
2. runs `warp-rotate.sh --rotate-only` — no nested `opencode run`, so it cannot
   deadlock the session that is waiting for the rotation,
3. sets OpenCode's retry decision to retry the same request after 1.5 seconds.

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
| `OPENCODE_WARP_ROTATE=/path/warp-rotate.sh` | override the rotation helper |

The retry path was validated end to end against a fake OpenAI-compatible
provider: the first request returned `429 Free usage limit reached`, the plugin
ran `warp-rotate.sh --rotate-only`, and OpenCode's retry then completed
successfully.

The wrapper skips the preflight when you pass an explicit non-free
`-m`/`--model`, because rotating the free bucket would not help that model.

Manual recovery uses the same code path:

```bash
./warp-rotate.sh               # probe, rotate only if throttled
./warp-rotate.sh --force       # always rotate, then probe
./warp-rotate.sh --rotate-only # rotate and verify the proxy, no opencode probe
./probe.sh                     # one-shot verdict, never rotates
```

Note: there is **no `reconnect` subcommand** — `warp-cli --accept-tos
reconnect` fails with *unrecognized subcommand*. The helper does
disconnect → registration delete → registration new → mode proxy → connect.

### What it still cannot do

- **It does not make you immune to rate limits.** opencode's free tier
  (`opencode.ai/inference`) enforces a daily quota that resets at **00:00 UTC**.
  Switching IP does not remove the cap; it may move you to a different
  bucket, or it may not.
- **It does not guarantee a different IP.** WARP assigns an address from
  Cloudflare's own pool; you cannot choose one. That is why the helper probes
  after each rotation instead of assuming success.
- **It churns device registrations.** Every attempt creates a new anonymous
  Cloudflare device. Keep `WARP_ROTATE_ATTEMPTS` and
  `OPENCODE_WARP_PLUGIN_MAX_ROTATIONS` small.

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
| `setup.sh` | installer (idempotent, safe to re-run) |
| `opencode-warp` | the wrapper; installed to `/usr/local/bin` |
| `uninstall.sh` | removes the wrapper, helpers, bashrc block, apt repo |
| `probe.sh` | one-shot verdict: is this ingress throttled? (`0` ok, `1` throttled, `2` no verdict) |
| `warp-rotate.sh` | probe → rotate device registration → probe (`0` ok, `1` throttled, `2` no verdict) |
| `opencode-warp-rotate.ts` | live-session 429 plugin: rotate WARP and retry the request |

`probe.sh` and `warp-rotate.sh` are installed to
`/usr/local/lib/opencode-warp/`. The plugin is installed to
`${XDG_CONFIG_HOME:-~/.config}/opencode/plugins/`. `setup.sh` creates a
timestamped backup of `~/.bashrc` before editing it.

---

## Uninstall

```bash
sudo ./uninstall.sh            # wrapper + helpers + bashrc block + apt repo
sudo ./uninstall.sh --purge    # also the package and device registration
```

---

## Privacy note

`setup.sh` runs `warp-cli registration new`, which creates an **anonymous
device registration** with Cloudflare — no email, no account login. The
registration state lives in `/var/lib/cloudflare-warp/`. `--purge` deletes it.

When auto-recovery triggers — at launch or through the live plugin —
`warp-rotate.sh` deletes that anonymous registration and creates a new one.
The launch-time path only does so when opencode's log shows a recent
rate-limit error (or when you pass `--force`); the live path only does so after
a 429 from a free model through the WARP proxy.

---

## License

MIT.
