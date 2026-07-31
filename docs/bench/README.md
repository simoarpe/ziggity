# Benchmarks

The harness behind the comparison table in [comparison.md](../comparison.md).
It measures; it does not estimate. Every row of that table comes out of one
command, so the numbers are reproducible rather than asserted.

## Running it

Build a release binary first, since that is what people install:

```sh
zig build -Doptimize=ReleaseSafe
python3 docs/bench/bench.py
```

It prints the markdown table ready to paste. Useful flags:

```sh
python3 docs/bench/bench.py --reps 7            # more repetitions, steadier medians
python3 docs/bench/bench.py --repo ~/some/repo  # measure against a different repository
python3 docs/bench/bench.py --json out.json     # full per run detail as well
python3 docs/bench/bench.py --window 30         # hold each tool open longer
```

Needs a C compiler, python3, git, and lazygit on `PATH` for the comparison
column. Works on macOS and Linux.

## How each row is measured

**Binary size** is the file on disk. **Dynamic libraries linked** counts what
`otool -L` reports on macOS, `ldd` on Linux, excluding the binary itself.

**Process startup** is spawn to exit for `--version`, the floor any launch pays
before real work begins. Median of 30 runs after 5 discarded warmups.

The git rows come from `gitshim.c`, a small program that is put on `PATH` under
the name `git`. Every git call the tool makes hits the shim first, which
records a timestamp, runs the real git, and records the child's own CPU from
`wait4`. Exit status and all three streams pass through, so the tool cannot
tell. This is how the counts, the parallelism, and the split between the
tool's CPU and git's CPU are obtained.

**Git subprocesses to load the repo** needs a definition, because both tools
keep talking to git forever. Both make one or two cheap pre-flight calls,
pause, then fan out to load every panel at once. The harness groups calls into
clusters separated by more than 400 ms and counts everything up to and
including the first cluster of three or more calls. Network fetches are
excluded here and reported on their own row.

**Peak git processes running in parallel** sweeps the start and end timestamps
and takes the high water mark.

**Network during load** reports whether a `fetch` or `ls-remote` lands inside
that load phase. Both tools fetch eventually. The row is about whether you
wait for it before the interface is usable.

**Resident memory** is RSS sampled every 100 ms. "Settled" is the last reading
of the window; "peak" is the highest. The two differ sharply for ziggity and
barely at all for lazygit, which is why both are reported.

**CPU** is split in two. "Own" is the tool's process alone, from `ps`. "Total"
adds every git child's CPU, summed from the shim log. Both tools do most of
their real work inside git, so the split is more informative than either half.

The tool is held open for the window (10 s by default) and then killed. Rows
are medians across `--reps` runs.

## What this cannot measure, and what moves

**No time to first paint.** The harness drives each tool through a pseudo
terminal that never answers terminal capability queries, so both stall about a
second before their fan-out while a probe times out. It affects both equally
and does not touch the counts, memory or CPU, but it makes any wall clock
"time until usable" number meaningless. There is deliberately no such row.

**CPU is the noisy row.** Across seven runs on an idle machine, lazygit's own
CPU ranged from 350 ms to 960 ms and ziggity's from 50 ms to 80 ms. The
medians are stable and the gap between the tools is consistent, but treat a
single CPU figure as approximate. Everything else is tight: resident memory
varied by under half a megabyte, and binary size, library count, startup and
peak parallelism were effectively constant.

**Repository state matters, more than you would expect.** The numbers depend
on commits, refs, worktrees, modified files, and on what is sitting untracked
in the working tree. Registering an extra git worktree adds calls and shifts
the load count. Build output matters most of all: measured on a working
checkout with `.zig-cache`, `zig-out` and `zig-pkg` present, ziggity's peak
memory is around 54 MB, and on a pristine clone of the same history it is
around 9 MB. The published table uses a working checkout, since that is what a
repository people actually work in looks like, but it means peak memory is not
comparable against a bare clone. Say which state you measured, as the table's
preamble does.

**Both tools must be comparable.** lazygit is measured as installed. If yours
differs in version from the published table, the columns are not comparable.
