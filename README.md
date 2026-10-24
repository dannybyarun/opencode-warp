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
| `opencode --stand run -m <model> "msg"` | through WARP, adds `--standalone` |
| `opencode --stand` | TUI, through WARP |
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

## What this does **not** do

Being explicit, because it matters:

- **It does not make you immune to rate limits.** opencode's free tier
  (`opencode.ai/inference`) enforces a daily quota that resets at **00:00 UTC**.
  Switching IP does not remove the cap; it may move you to a different
  bucket, or it may not.
- **It does not rotate IPs.** There is no loop here that cycles WARP addresses
  to avoid being throttled. Deliberately so.
- **It does not guarantee a different IP every run.** WARP assigns you an
  address from Cloudflare's own pool; you cannot choose one. To try for a
  different one:

  ```bash
  warp-cli --accept-tos disconnect && warp-cli --accept-tos connect   # often the same address
  warp-cli --accept-tos registration delete && warp-cli --accept-tos registration new \
    && warp-cli --accept-tos mode proxy && warp-cli --accept-tos connect   # new device identity
  ```

  Note: there is **no `reconnect` subcommand** — `warp-cli --accept-tos
  reconnect` fails with *unrecognized subcommand*. Use the two above.

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
| `uninstall.sh` | removes the wrapper, bashrc block, apt repo |
| `probe.sh` | one-shot verdict: is this ingress throttled? (`0` ok, `1` throttled, `2` no verdict) |

`setup.sh` creates a timestamped backup of `~/.bashrc` before editing it.

---

## Uninstall

```bash
sudo ./uninstall.sh            # wrapper + bashrc block + apt repo
sudo ./uninstall.sh --purge    # also the package and device registration
```

---

## Privacy note

`setup.sh` runs `warp-cli registration new`, which creates an **anonymous
device registration** with Cloudflare — no email, no account login. The
registration state lives in `/var/lib/cloudflare-warp/`. `--purge` deletes it.

---

## License

MIT.
