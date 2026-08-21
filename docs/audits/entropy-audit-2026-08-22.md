# Entropy audit — solarmon

Date: 2026-08-22  
Mode: full (entropy + hygiene)  
Auditor: entropy-audit owner (this snapshot only)

## Executive summary

- **Snapshot:** `/Users/marcelo/work/github.com/marcelocantos/solarmon`
  - Branch: `master` (tracks `origin/master`)
  - HEAD: `aa937b02283f54e1c3e98277c08bb0cb2e0f690e` (`Add Apache 2.0 licence`)
  - Initial dirty state: clean tracked tree (`git status --porcelain=v1 -b` showed only `## master...origin/master`). Gitignored runtime files present: `config.json`, `.state.json`.
  - Remote: `https://github.com/marcelocantos/solarmon` (public, default branch `master`, no branch protection)
- **Scope:** the whole repository (four tracked files). Runtime evidence from the shipped hourly cron invocation and `/tmp/solarmon.log`.
- **Exclusions:** `.git/`; gitignored runtime `config.json` and `.state.json` (cited as operational evidence only; secret values not reproduced); user crontab (cited as the undeclared scheduler). No generated, vendored, or fixture trees exist.
- **Headline mechanism:** a 313-line bash glue script is the whole product, but the **shipped scheduler PATH cannot see `ping`**, so the local-unreachable check has never succeeded in 21 days of production logs. That permanent ping failure then poisons global `any_failure`, so SEMS recovery never runs. A second, independent hole parses Python tracebacks as inverter records.
- **Highest-consequence findings:** ENT-001 (cron PATH / ping always-fail), ENT-002 (SEMS stderr parsed as inverters), ENT-003 (SEMS recovery gated on global success).
- **Unverified residue:** Pushover delivery; whether macOS Local Network TCC would still block ping after PATH is fixed; whether ping is still wanted given SEMS covers both inverters.

## Scope and exclusions

Tracked production surface:

| Path | Role |
|---|---|
| `solarmon.sh` | Sole program |
| `config.example.json` | Example config (placeholders) |
| `.gitignore` | Ignores live config/state |
| `LICENSE` | Apache-2.0 |

Not in git, used at runtime:

| Path | Role |
|---|---|
| `config.json` | Live secrets + inverter list (gitignored; never in history) |
| `.state.json` | Alert/heartbeat ledger (gitignored) |
| user crontab | Hourly invoke + `PATH=` (not in repo) |
| `/tmp/solarmon.log` | Cron stdout/stderr |

No `README`, `AGENTS.md`, `CLAUDE.md`, `hygiene.yaml`, tests, Makefile, or `.github/workflows`.

## Commands run

| Command | Version / notes | Exit | Shipped vs auxiliary | Limitations |
|---|---|---|---|---|
| `git rev-parse --abbrev-ref HEAD`; `git rev-parse HEAD`; `git status --porcelain=v1 -b` | git | 0 | provenance | Initial snapshot only |
| `git log --format=fuller`; `git ls-files`; `git log --all -- config.json` | — | 0 | provenance | `config.json` never committed |
| `gh repo view marcelocantos/solarmon --json …`; `gh api …/actions/workflows`; branch protection; secret-scanning; Dependabot | gh | 0 / 404s as noted | auxiliary (GitHub settings) | Secret scanning and vulnerability alerts **disabled**; 0 workflows; branch not protected |
| `/bin/bash -n solarmon.sh` | GNU bash 3.2.57 (`/bin/bash`, Darwin) | 0 | auxiliary syntax; shebang is this binary | Does not catch bash-4+ runtime features or missing `ping` |
| `bash -n solarmon.sh` | GNU bash 5.3.15 (Homebrew) | 0 | auxiliary | Not the shebang runtime |
| `shellcheck -f gcc solarmon.sh` | ShellCheck 0.11.0 | 1 | auxiliary | SC2329 unused `sems_login` (line 97); SC2001 style at line 281. Not CI. |
| `PATH=/opt/homebrew/bin:/usr/bin:/bin command -v ping` | same PATH as user crontab | 1 (`MISSING`) | **shipped-path simulation** | Confirms cron cannot resolve `ping` |
| same PATH: `command -v jq/python3/curl` | jq 1.8.2 Homebrew; Python 3.14.7 Homebrew; curl 8.7.1 `/usr/bin/curl` | 0 | shipped-path simulation | Cron uses Homebrew Python, not interactive `~/.py` 3.13 |
| `/sbin/ping -c 3 -W 5\|20\|100\|1000\|2000 192.168.1.166` | macOS `/sbin/ping` | 0 for all | auxiliary (interactive PATH includes `/sbin`) | Host reachable interactively; `-W` is milliseconds and does **not** fail the command when RTT > waittime |
| `python3` compile of extracted `python3 -c` body | 3.13.0 interactive | compile OK | auxiliary | Credentials substituted with dummies |
| `crontab -l` | macOS cron | 0 | **shipped scheduler** | Outside repo |
| `grep` counts on `/tmp/solarmon.log` | log 2026-08-01 21:17 → 2026-08-22 08:17, 2563 lines | 0 | **shipped-path output** | Log is local; not retained in git |
| `~/.claude/skills/hygiene/hygiene_check.py` | hygiene skill | 1 | hygiene | `FileNotFoundError: hygiene.yaml` — posture not declared |

No clone detector, coverage tool, or architecture test is configured. None were installed.

## Observed architecture

Single deployable: `solarmon.sh`, invoked hourly by user crontab (`17 * * * *`), logging to `/tmp/solarmon.log`.

```
user crontab
  PATH=/opt/homebrew/bin:/usr/bin:/bin   # no /sbin
  17 * * * * solarmon.sh >> /tmp/solarmon.log
        |
        v
  /bin/bash solarmon.sh                  # shebang; macOS 3.2.57
        |-- jq  read config.json
        |-- jq  read/write .state.json (tmp + mv)
        |-- ping -c/-W  inverter IPs     # NOT ON SHIPPED PATH
        |-- python3 -c  urllib SEMS API  # Homebrew 3.14 under cron
        +-- curl        Pushover API
```

**Declared intent** (script header, lines 5–6; initial commit message): monitor GoodWe inverters via local ping and SEMS cloud; Pushover on offline; recovery; daily 08:xx heartbeat.

**Observed rules that agree**

- Config path `SOLARMON_CONFIG` / default `config.json`; state `SOLARMON_STATE` / `.state.json`.
- Missing config exits 1 with copy-the-example hint (`solarmon.sh:18-22`).
- Null/empty inverter IP skips ping (`solarmon.sh:80-82`).
- Alert dedup via `.state.json` keys `ping_<name>` and `sems_<sn>`.
- Heartbeat once per calendar day when the 08 hour slot runs (`solarmon.sh:288-302`); `.state.json` `last_heartbeat` is `2026-08-22`.

**Observed, inferred from code (not documented)**

- SEMS is the only check that covers Inverter-2 (no IP in live config).
- SEMS recovery is not per-inverter; it is a bulk clear after a fully green run (`solarmon.sh:275-286`).
- Ping recovery *is* per-inverter (`solarmon.sh:261-268`).
- Identity spaces differ: config `Inverter-1` vs SEMS `Inverter 1` plus serials.

**Contradictions**

- Comment at `solarmon.sh:132-134` says bash/jq cannot handle the SEMS password; unused `sems_login` at `solarmon.sh:97-124` already uses `jq --arg`, which does.
- `sems_login` is dead (`shellcheck` SC2329); live path is interpolated `python3 -c`.

**Unknown intent (owner residue)**

- Is ping still a required signal, or is SEMS enough?
- Should the scheduler live in-repo (launchd plist / documented crontab)?

No architecture tests enforce any of the above.

## Dimension vector

First audit; no prior baseline.

| Dimension | State | Evidence summary | Change from baseline |
|---|---|---|---|
| Architecture topology | concern | One script, clear left-to-right flow, but SEMS client is an inlined Python program with a dead jq twin | n/a (first audit) |
| Redundancy / sources of truth | concern | Two SEMS login implementations; config names vs SEMS serials; crontab PATH vs script's bare `ping` | n/a |
| Change amplification | healthy | Almost every behaviour change is one file; scheduler PATH is the extra edit that was missed | n/a |
| Local code quality | concern | `2>&1) \|\| true` plus pipe-parse; unused function; credential interpolation; otherwise linear and readable | n/a |
| Correctness / verification | critical | Shipped ping check 330/330 FAILED, 0 OK; SEMS tracebacks parsed as faults; no tests | n/a |
| Security / dependencies | concern | Live secrets gitignored and never committed; public repo with secret scanning / push protection / Dependabot off; secrets appear on `python3 -c` and `curl` argv | n/a |
| Build / release / operations | concern | No CI, no release, no in-repo scheduler; cron PATH is load-bearing and wrong for `ping` | n/a |
| Documentation / governance | concern | No README, empty GitHub description, no AGENTS.md, hygiene undeclared; LICENSE present | n/a |

## Findings

### ENT-001: Cron PATH omits `/sbin`, so the ping check never succeeds on the shipped path

- **Priority:** P0
- **Dimensions:** Correctness / verification; Build / release / operations; Architecture topology
- **Status:** observed fact
- **Evidence:**
  - `solarmon.sh:84` invokes bare `ping` (stderr discarded).
  - User crontab (shipped scheduler): `PATH=/opt/homebrew/bin:/usr/bin:/bin` then `17 * * * * …/solarmon.sh >> /tmp/solarmon.log 2>&1`.
  - `ping` binary is `/sbin/ping` only; `PATH=/opt/homebrew/bin:/usr/bin:/bin command -v ping` → missing (exit 1).
  - `/tmp/solarmon.log`: 330 `PING Inverter-1 (192.168.1.166): FAILED`, **0** `PING … OK`, **0** `Result: All OK`, 328 `Result: ISSUES DETECTED`, span 2026-08-01 21:17 through 2026-08-22 08:17.
  - Same host, interactive `/sbin/ping -c 1 192.168.1.166` exits 0. SEMS lines in the same failed-ping hours show inverters generating (e.g. 2026-08-22 08:17: `status=1, 618.12W` / `406.2W`).
  - `.state.json` holds `"ping_Inverter-1": "alert"` with no recovery possible while ping stays red.
- **Mechanism:** macOS cron does not include `/sbin`. `if ping …; then` treats command-not-found as failure; `2>&1` hides `command not found`. Dedup sends at most one “Inverter Unreachable” Pushover, then the local-Wi-Fi check is a permanent false alarm. That also forces `any_failure=true` every hour (feeds ENT-003).
- **Blast radius:** the local-unreachable feature advertised in the header (`solarmon.sh:5-6`) and in the ping notify copy (`solarmon.sh:257-258`) is inert on the only production invocation. Heartbeat copy always reports “issues detected”. SEMS recovery cannot fire.
- **Counterevidence checked:** interactive ping works, so the inverter is not generally ICMP-dead. `ping_timeout`/`-W` (ENT-005) does not explain cron failures: macOS `-W` is print-wait, and `-W 5` still exited 0 interactively. jq/python3/curl resolve on the cron PATH, which is why the script logs a full check rather than dying at config read. No in-repo PATH export or `/sbin/ping` absolute path.
- **Smallest coherent remediation:** in `check_ping`, call `/sbin/ping` if present else `ping`, **or** set `PATH` inside the script to include `/sbin:/usr/sbin`. Keep crontab PATH for Homebrew `python3`/`jq`.
- **Verification:** a job (or documented cron smoke) that runs with crontab’s PATH and asserts `command -v ping` and a mocked-or-loopback ping OK. Regression: restore PATH without `/sbin` and the check must fail.
- **Ratchet candidate:** script-level `PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"` plus a CI/macOS job `PATH=/opt/homebrew/bin:/usr/bin:/bin /bin/bash solarmon.sh` against a fixture config (ping target `127.0.0.1`).

### ENT-002: SEMS Python failures are merged into stdout and parsed as inverter records

- **Priority:** P1
- **Dimensions:** Correctness / verification; Local code quality
- **Status:** observed fact
- **Evidence:**
  - `solarmon.sh:136-192`: `result=$(python3 -c "…" 2>&1) || true`
  - `solarmon.sh:211-226`: `while IFS='|' read …` treats every line as `name|sn|status|…`; any status other than `1` or `0` is OFFLINE/FAULT and may `notify`.
  - `/tmp/solarmon.log:678+` (2026-08-09 07:17): `SEMS Traceback (most recent call last): (): status= (OFFLINE/FAULT)` through `urllib.error.URLError: <urlopen error [Errno 8] nodename nor servname provided, or not known>`.
  - Grep: 951 `OFFLINE/FAULT` lines vs 6 genuine `status=-1` lines.
  - `.state.json` contains `"sems_": "alert"` — empty serial from traceback lines that have no `|` (entire line → `inv_name`, `inv_sn` empty → `state_key=sems_`).
- **Mechanism:** exceptions print to stderr, `2>&1` folds them into the record stream, `|| true` prevents a non-zero Python exit from skipping the parser. Each traceback line becomes a fake inverter. Shared empty SN dedups to one sticky `sems_` alert.
- **Blast radius:** DNS/network blips (already seen) generate garbage Pushover text and poison SEMS state keys. Log file becomes unreadable for those hours. Combined with ENT-003, those keys never clear.
- **Counterevidence checked:** happy-path SEMS lines parse (`SEMS Inverter 1 (95000EHR204W0198): status=1, … (ok)`). `LOGIN_FAILED` / `NO_STATIONS` exact-match branches (`solarmon.sh:194-202`) do not cover tracebacks. No tests.
- **Smallest coherent remediation:** do not merge stderr; drop `|| true`; on non-zero or non-record output, log one API-error line and return 1 without calling `notify` per line. Validate each record against `^[^|]+\|[^|]+\|-?[0-9]+\|`.
- **Verification:** fixture that makes `urllib` raise; assert no `OFFLINE/FAULT` per traceback line and no `sems_` key. Replay of the 2026-08-09 log shape must fail the test if parsing regresses.
- **Ratchet candidate:** unit test around an extracted SEMS client (see ENT-004); or a bash test feeding a canned traceback through the parse loop.

### ENT-003: SEMS recovery is gated on global `any_failure`, which ping keeps true

- **Priority:** P1
- **Dimensions:** Correctness / verification; Change amplification
- **Status:** observed fact
- **Evidence:**
  - Ping failure sets `any_failure=true` (`solarmon.sh:252-253`).
  - `check_sems || any_failure=true` (`solarmon.sh:273`).
  - SEMS alert clear runs only `if ! $any_failure` (`solarmon.sh:277-285`), i.e. ping **and** SEMS all green.
  - Online SEMS inverters in `check_sems` do **not** clear their own keys (`solarmon.sh:213-214` only log “ok”).
  - Production: 2026-08-22 08:17 SEMS both `status=1` generating, ping FAILED; `.state.json` still `"sems_95000EHR204W0198": "alert"` and `"sems_95000EHR218W0071": "alert"`.
- **Mechanism:** ping and SEMS share one boolean. A permanently red ping (ENT-001) makes SEMS recovery dead code. Even after ping is fixed, one down inverter blocks recovery notify for the other.
- **Blast radius:** recovery Pushovers for SEMS never fire in current production; stale `sems_*` alerts hide a later real outage (dedup: `get_state != alert` skips notify).
- **Counterevidence checked:** ping recovery *is* per-device (`solarmon.sh:261-268`). Comment at 277-278 admits bulk clear. No test of mixed ping-fail / SEMS-ok.
- **Smallest coherent remediation:** clear or set `sems_<sn>` inside the per-inverter loop, symmetric with ping. Do not couple SEMS recovery to ping.
- **Verification:** state fixture with `sems_<sn>=alert` + canned SEMS status=1 + ping fail → key becomes `ok` and a recovery notify path is taken.
- **Ratchet candidate:** the same per-inverter state test; once green, a hygiene `command:` or CI step.

### ENT-004: SEMS client is an interpolated `python3 -c` blob (dead jq twin, secrets on argv)

- **Priority:** P2
- **Dimensions:** Architecture topology; Redundancy / sources of truth; Security / dependencies; Local code quality
- **Status:** observed fact (architecture / argv); inference (injection if password contains `'''`)
- **Evidence:**
  - Live client: `solarmon.sh:136-192`, credentials at line 152: `creds = {'account': '''$SEMS_ACCOUNT''', 'pwd': '''$SEMS_PASSWORD'''}`.
  - Dead twin: `sems_login` `solarmon.sh:97-124` uses `jq -nc --arg` (correct escaping) and is never called (ShellCheck SC2329).
  - Comment 132-134 claims jq cannot handle special characters — contradicted by `sems_login`.
  - Process argv: the whole Python program including secrets is one `python3 -c` argument; `notify` puts Pushover token/user on `curl --form-string` argv (`solarmon.sh:64-70`).
- **Mechanism:** bash.md’s “shells out to python3 for correctness” tell. Two login implementations can drift; only the unsafe one is live. Any local `ps` during the hourly run can read SEMS and Pushover secrets. A password containing `'''` would break or inject into the Python source.
- **Blast radius:** personal Mac, hourly window — not internet-facing, but the machine runs other software. Dual implementations mean a SEMS API change is easy to fix in the unused function and miss production.
- **Counterevidence checked:** `set_state` already uses `jq --arg` (`solarmon.sh:54-55`). Station-id string-vs-list handling is a real reason to use Python (`solarmon.sh:169-178`); that does not require inlining or interpolating secrets. No other consumers of `sems_login`.
- **Smallest coherent remediation:** move the Python to `sems_check.py`, pass credentials on stdin or via env, delete `sems_login`. Keep bash as ping/state/notify glue.
- **Verification:** `ps`-style assertion that worker argv does not contain the password; Python unit tests for station-id shapes.
- **Ratchet candidate:** `shellcheck` in CI plus a test that `sems_login` is absent / Python module exists; optional `pgrep` secret-argv check is too flaky — prefer “no `python3 -c`” file rule.

### ENT-005: `ping -W` units are milliseconds on macOS and seconds on Linux

- **Priority:** P2
- **Dimensions:** Correctness / verification
- **Status:** observed fact (units); inference (would matter on Linux or after ENT-001 if macOS `-W` semantics change)
- **Evidence:**
  - `config.example.json:17` `"ping_timeout": 5`; `solarmon.sh:30,84`.
  - macOS `man ping`: `-W waittime` — “Time in **milliseconds** to wait for a reply”. Also: late replies are still counted as received (so `-W` does not drive exit status the way GNU ping does).
  - GNU ping `-W` is seconds. Interactive `-W 5` to the inverter still exited 0 with avg RTT 355 ms.
- **Mechanism:** after PATH is fixed, timeout=5 does not mean “5 seconds” on this host. A Linux port or a reader trusting the config name will get a 5-second vs 5-millisecond mismatch.
- **Blast radius:** latent false ping failures or ignored timeouts; config key name `ping_timeout` is misleading on Darwin.
- **Counterevidence checked:** current cron failures are PATH (ENT-001), not `-W`. macOS late-reply behaviour prevented `-W 5` from failing my interactive probes.
- **Smallest coherent remediation:** document units; use a Darwin-safe wait (e.g. `-W 2000` milliseconds, or detect GNU vs BSD).
- **Verification:** test matrix: `/bin/ping` Darwin and a Linux job, assert the configured value is interpreted as intended.
- **Ratchet candidate:** comment + example JSON units; optional CI on Ubuntu and macOS.

### ENT-006: `notify` discards all curl outcomes

- **Priority:** P2
- **Dimensions:** Correctness / verification; Build / release / operations
- **Status:** observed fact (swallow); needs verification (whether Pushover actually received anything)
- **Evidence:** `solarmon.sh:62-70` — `curl -s` without `-f`/`-S`, all output to `/dev/null`. Heartbeat has no log line; only `.state.json` `last_heartbeat=2026-08-22` proves the 08:17 path *called* `notify`.
- **Mechanism:** HTTP 4xx/5xx, DNS failure, or a bad token still look like a successful alert. The monitor cannot report that monitoring failed.
- **Blast radius:** silent loss of the only user-visible channel.
- **Counterevidence checked:** no retries, no response JSON check (`status`/`request` from Pushover). Did not send a live test message (would page the owner).
- **Smallest coherent remediation:** `curl -fsS`, check HTTP JSON `status`, log failures to stderr (cron already captures stderr).
- **Verification:** mock Pushover 400; assert non-zero or a logged error and no state advance for heartbeat if notify failed (policy choice).
- **Ratchet candidate:** contract test with a local HTTP fixture.

### ENT-007: Public repo with no tests, CI, README, or secret-scanning — hygiene undeclared

- **Priority:** P2
- **Dimensions:** Documentation / governance; Security / dependencies; Correctness / verification
- **Status:** observed fact
- **Evidence:**
  - GitHub: public, description empty, 0 Actions workflows, branch `master` unprotected, secret scanning / push protection / Dependabot disabled (`gh api` 404s).
  - No `README*`, no tests, no Makefile, no `.github/`.
  - `.gitignore` correctly lists `config.json` and `.state.json`; `git log --all -- config.json` empty.
  - `hygiene.yaml` absent; validator FileNotFoundError.
- **Mechanism:** accidental `git add config.json` on a public repo has no push protection. New contributors (including future agents) have no stated run/test/schedule contract. ENT-001’s PATH bug had no CI to catch it.
- **Blast radius:** secret leak on first mistake; no automated regression net for ENT-001–003.
- **Counterevidence checked:** LICENSE Apache-2.0 present; example config uses placeholders (`your-pushover-user-key`, `your-sems-password`). Private-IP example `192.168.1.166` is in git (low sensitivity).
- **Smallest coherent remediation:** README (run, cron PATH including `/sbin`, config copy); GitHub secret scanning + push protection; a single macOS/bash smoke job. Declare `hygiene.yaml` only when the owner wants a ratchet — do not invent it in this audit.
- **Verification:** `gh` settings; CI green on `bash -n` + PATH smoke + SEMS parse fixture.
- **Ratchet candidate:** `hygiene.yaml` items `docs.readme`, `security.secret-scan`, `correctness.ci-smoke` once those files/jobs exist.

### ENT-008: Load-bearing scheduler lives only in the user crontab

- **Priority:** P3
- **Dimensions:** Build / release / operations; Documentation / governance; Redundancy / sources of truth
- **Status:** observed fact
- **Evidence:** crontab PATH + hourly line are the production entrypoint; nothing in the repo mentions cron, PATH, or `/tmp/solarmon.log`.
- **Mechanism:** cloning the public repo does not yield a working monitor. Reimaging the Mac loses the schedule unless the owner remembers PATH `/sbin`.
- **Blast radius:** this host only; low until ENT-001’s PATH line is edited again.
- **Counterevidence checked:** env vars `SOLARMON_CONFIG` / `SOLARMON_STATE` exist for relocation; no launchd plist.
- **Smallest coherent remediation:** document the crontab in README, including `PATH` with `/sbin`. Optional: commit a `launchd` plist.
- **Verification:** README or plist mentioned in a file-existence hygiene item.
- **Ratchet candidate:** `file:` evidence for README section or `com.marcelocantos.solarmon.plist`.

## Redundancy and competing-source-of-truth inventory

| Concept | Instances | Drift already? | Action |
|---|---|---|---|
| SEMS login | unused `sems_login` (jq/curl) vs live `python3 -c` | Yes: only Python is executed | Delete unused; extract Python (ENT-004) |
| Inverter identity | `config.json` `name`/`ip` vs SEMS `name`/`sn` | Different strings (`Inverter-1` vs `Inverter 1`) | Deliberate if ping and SEMS stay independent; document |
| Ping success | script assumes `ping` on PATH vs crontab PATH without `/sbin` | Yes — production always-fail (ENT-001) | Fix PATH in script |
| Python runtime | shebang n/a; cron Homebrew 3.14.7 vs interactive `~/.py` 3.13.0 | Dual interpreters, same script | Pin `python3` or document |
| Alert state | `.state.json` vs live SEMS/ping | Yes — SEMS keys stuck `alert` while API says ok (ENT-003) | Per-inverter recovery |
| Scheduler | user crontab vs repo | Cron not in repo (ENT-008) | Document |

Deliberate duplication: ping (LAN/Wi-Fi) vs SEMS (cloud) is two sensors for one physical plant — keep both, but do not share `any_failure` for recovery.

## Healthy structure worth retaining

- **`.gitignore` lists `config.json` and `.state.json`**; git history never contained live secrets. Example file uses obvious placeholders.
- **`set -euo pipefail`**, quoted expansions, bash 3.2-safe syntax (`/bin/bash -n` exit 0). No `mapfile` / `declare -A`.
- **Atomic state write** (`tmp` + `mv`, `solarmon.sh:53-55`).
- **Alert dedup** prevents hourly Pushover spam (the reason ENT-001 was quiet after the first ping alert).
- **Null IP skip** for inverters still on guest Wi-Fi (`solarmon.sh:80-82`; example comment on Inverter-2).
- **`jq --arg`** already used for state updates — the safe pattern to copy for SEMS creds.
- **Apache-2.0 LICENSE** with copyright 2026.
- **Env overrides** for config/state paths — testable without touching live files.
- Linear `main` is scannable; no premature abstraction beyond the dead `sems_login`.

## Hygiene posture

**Hygiene posture not declared.** `hygiene.yaml` is absent. Validator:

```
FileNotFoundError: [Errno 2] No such file or directory:
'/Users/marcelo/work/github.com/marcelocantos/solarmon/hygiene.yaml'
exit=1
```

No per-dimension floors, no drift vector, no planned/skipped items. This audit did not initialize `hygiene.yaml`.

Overlap: ENT-007 is the governance/CI gap hygiene would encode; ENT-001–003 are structural correctness and should become `command:` / `ci_job` items only after those oracles exist.

Entropy findings suitable as future hygiene items (do not add until the owner adopts them): PATH smoke (ENT-001), SEMS parse fixture (ENT-002), per-inverter recovery test (ENT-003), `file: README`, GitHub `secret_scanning` setting, `bash -n` under `/bin/bash` 3.2.

## Oracle coverage and residue

| Property | Decided by |
|---|---|
| Script parses under macOS `/bin/bash` 3.2 | Auxiliary: `/bin/bash -n` (not CI) |
| `ping` exists on shipped PATH | **Nothing in repo.** Production logs decide: it does not. PATH simulation reproduces. |
| Ping reflects inverter LAN reachability | Shipped path currently false (ENT-001). Interactive ping is a manual check only. |
| SEMS status 0/1 vs other | Live API in cron (happy path observed). No fixture for string-vs-list station id. |
| SEMS errors are not inverter faults | **Nothing** — production log shows the opposite (ENT-002). |
| SEMS recovery when ping is red | **Nothing** — production state shows alerts stuck (ENT-003). |
| Pushover delivery | **Nothing** (ENT-006). Heartbeat state write ≠ delivery. |
| Secrets not in git | `git log` + `.gitignore` (auxiliary). No secret scanning. |
| Bash 4+ features absent | `bash -n` does not catch them; visual read found none. No macOS CI job asserting `/bin/bash` is 3.x. |
| Hygiene floors | Undeclared |

Failed/skipped checks: `hygiene_check.py` (no yaml); GitHub secret-scanning / Dependabot / code-scanning APIs (disabled / no analysis); no test suite to run.

**Owner residue (intent only):**

1. Keep ping at all, given SEMS already sees both inverters and Inverter-2 has no IP?
2. After PATH is fixed, grant cron **Local Network** permission if macOS TCC still blocks ICMP (not testable without changing the scheduler).
3. Extract SEMS to Python vs leave glue (taste/size; ENT-004 is the mechanism).
4. Public vs private GitHub.

## Remediation sequence

1. **Repair the shipped ping oracle (ENT-001).** Put `/sbin` on PATH inside `solarmon.sh` (or exec `/sbin/ping`). Confirm the next cron line logs `PING … OK` while SEMS is generating. Optionally reset `ping_Inverter-1` in `.state.json` after verifying, or let the existing recovery path send “Back Online”.
2. **Decouple SEMS recovery from ping (ENT-003)** and **stop parsing stderr as inverters (ENT-002)** in the same change — otherwise leftover `sems_` keys and the next DNS blip re-poison state. Clear the sticky `sems_*` / `sems_` keys once as a one-time state repair.
3. **Make notify failures visible (ENT-006)** so the next outage of Pushover is not silent.
4. **Extract the SEMS client (ENT-004)** only after the parse contract is tested; delete `sems_login`. Pass secrets via env/stdin.
5. **Document units and cron (ENT-005, ENT-008)** in a README; add a macOS smoke job + secret scanning (ENT-007). Then, if requested, declare `hygiene.yaml` against those real oracles and re-run this audit on the same finding IDs.
