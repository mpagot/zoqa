# Running Fuzz Campaigns on the Remote SUSE VM

Operational notes for driving AFL++ campaigns on the dedicated dev VM.
The VM has more cores than a laptop and stays online across reboots, so
campaigns can run for days without blocking local work.

## Connection

```sh
ssh -i ~/draft/my_suse_machine/.secret/id_rsa_jumphost devenv@10.128.98.29
```

| | |
|---|---|
| Host | `10.128.98.29` (`mpagot-dev`) |
| User | `devenv` |
| Key  | `~/draft/my_suse_machine/.secret/id_rsa_jumphost` |
| Repo | `~/p_repo/zoqa` |
| AFL++ | `~/p_repo/zoqa/vendor/aflplusplus/` (built in tree) |
| Zig  | asdf-managed at `~/.asdf/shims/zig` (0.15.2) |

## Shell PATH gotcha

asdf isn't initialised in non-interactive `ssh ... '<cmd>'` sessions —
`zig` won't be on `PATH`. Always prepend the asdf shim dir for build
commands:

```sh
export PATH=$HOME/.asdf/shims:$PATH
```

Interactive shells (`tmux attach`) get asdf via `~/.zshrc`, so this is
only needed for one-shot SSH commands and `tmux send-keys` invocations.

## tmux layout

A long-lived tmux session is used so campaigns survive SSH disconnects.

| Session | Purpose |
|---|---|
| `2` | Active fuzz campaigns (default) |
| `3` | Other dev work |

Inside session 2, one window per running campaign keeps each AFL UI
visible side-by-side. Conventional names: `schedule`, `execute`,
`request`, `config` — matching the four fuzz targets defined in
`tests/fuzz/run.sh`.

```sh
tmux ls                       # list sessions
tmux list-windows -t 2        # list windows in session 2
tmux attach -t 2              # attach to session 2
tmux capture-pane -t 2:schedule -p | tail -30   # peek without attaching
```

## Standard workflow

Run from the local machine via SSH. The VM is the only place these
build/run commands should execute.

```sh
# 1. Verify the remote has the latest code (push first if needed).
ssh -i KEY devenv@10.128.98.29 'cd ~/p_repo/zoqa && git log --oneline -3'

# 2. Build all fuzz binaries with current source.
ssh -i KEY devenv@10.128.98.29 \
  'export PATH=$HOME/.asdf/shims:$PATH && cd ~/p_repo/zoqa && make fuzz-build'

# 3. Minimise corpora against the new binary's coverage map.
#    First run only, or when seeds have changed:
ssh -i KEY devenv@10.128.98.29 \
  'export PATH=$HOME/.asdf/shims:$PATH && cd ~/p_repo/zoqa && ./tests/fuzz/cmin.sh schedule'

# 4. Launch the campaign in a new tmux window.
ssh -i KEY devenv@10.128.98.29 '
  tmux new-window -t 2 -n schedule -c ~/p_repo/zoqa
  tmux send-keys -t 2:schedule "export PATH=\$HOME/.asdf/shims:\$PATH" Enter
  tmux send-keys -t 2:schedule "AFL_SKIP_CPUFREQ=1 AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 ./tests/fuzz/run.sh schedule" Enter
'
```

## Stopping a campaign

```sh
# Gracefully (preserves out_<target>/ on disk):
ssh -i KEY devenv@10.128.98.29 'tmux send-keys -t 2:schedule C-c'

# Or by PID:
ssh -i KEY devenv@10.128.98.29 'pkill -INT -f zoqa-fuzz-schedule'
```

`out_<target>/` (queue, crashes, hangs, plot_data) survives. The
accumulated queue is **only meaningful against the binary that
produced it** — after rebuilding, restart fresh rather than
`--continue`, or use `cmin.sh` to reproject the queue onto the new
edge map.

## Rebuilding after source changes

The coverage map is keyed on instruction pointers, so any rebuild
invalidates the running campaign's bitmap. Standard sequence after
pushing new code:

1. Stop the campaigns (above).
2. `make fuzz-build` (remote).
3. `cmin.sh <target>` (remote) — rebuilds `corpus_<target>_min/`.
4. Relaunch in tmux.

Skipping cmin after a substantive source change leaves the seed pool
mapped to stale edges; AFL still runs but mutation guidance is poorly
aimed.

## Triage

When AFL finds crashes:

```sh
ssh -i KEY devenv@10.128.98.29 \
  'ls ~/p_repo/zoqa/tests/fuzz/out_schedule/main-node/crashes/'

# Pull a crash file locally:
scp -i KEY devenv@10.128.98.29:~/p_repo/zoqa/tests/fuzz/out_schedule/main-node/crashes/id:000000* /tmp/

# Reproduce locally (faster turnaround than minimising on remote):
./zig-out/zoqa-fuzz-schedule < /tmp/id:000000...
```

After fixing, **promote a representative crash input to
`tests/fuzz/corpus_<target>/`** as a regression seed before deleting
the rest. See `ideas/HARNESS_AUDIT.md` for the full distillation
workflow.

## Known stale state on the VM

- `zig-out/zoqa-fuzz-{auth,cli,gzip,http,ini}` — leftover binaries from
  the gen-1 cleanup. Not rebuilt; safe to `rm`.
- Older `out_*/` dirs may exist from pre-restructure campaigns. Their
  queues and crashes were valid at the time but their coverage maps no
  longer match the current code. Either re-cmin them as input seeds
  for the new binaries or `rm -rf` to start clean.

---

## Currently running on the VM (as of 2026-04-30)

All four gen-2 campaigns relaunched in tmux session 2 against fresh
binaries built at commit `a58828d` (Gap 12 fix included). Pre-restructure
output dirs preserved as `out_<target>_archived_20260430_000851_pre_restructure/`
in case future seed-migration is wanted.

| Window | Target | Corpus seeds (post-cmin) | Output dir |
|---|---|---|---|
| `2:schedule` | `runSchedule` + `extractJobIds` | 1 | `out_schedule/` |
| `2:execute` | full HTTP pipeline (auth + retry + gzip) | 274 | `out_execute/` |
| `2:request` | CLI args + `buildRequest` + JSON | 440 | `out_request/` |
| `2:config` | INI parser + `resolveHost` | 57 | `out_config/` |

Quick health check across all four:

```sh
for w in schedule execute request config; do
  echo "--- $w ---"
  ssh -i KEY devenv@10.128.98.29 "tmux capture-pane -t 2:$w -p | tail -10"
done
```

---

## Currently running on the VM (as of 2026-05-04)

All four gen-2 campaigns rebuilt at commit `c7a6bc1` ("Fuzzy test generic
improvements"). Key changes vs the previous launch:

- `fuzz_execute`: ctrl_byte expanded to 7 bits; Section 5 (Link header) added;
  four new seeds bootstrap Gaps 7, 9, 10, 11.
- `fuzz_request`: corpus expanded from 22 to 440+ seeds (absolute URLs, CLI
  flags, JSON variety, malformed flags — Gaps 1–3, 5, 6).
- `fuzz_schedule`: null `output_writer` passed; eliminates the pipe-buffer
  non-determinism that caused 83.91% stability. Corpus still 1 seed.
- `fuzz_config`: corpus distilled; `.tmin_timeouts` file removed.

Standard restart sequence executed: `make fuzz-build` → `cmin.sh` → relaunch.

| Window | Target | Corpus seeds (post-cmin) | Notes |
|---|---|---|---|
| `2:schedule` | `runSchedule` + `extractJobIds` (sync stub) | 1 | Stability fix applied; async path still TODO |
| `2:execute` | full HTTP pipeline (auth + retry + gzip + Gaps 7/9/10/11) | machine-discovered | 4 new gap seeds in corpus |
| `2:request` | CLI args + `buildRequest` + JSON | machine-discovered | 440+ seeds; Gaps 1–3, 5, 6 covered |
| `2:config` | INI parser + `resolveHost` | machine-discovered | corpus distilled |
