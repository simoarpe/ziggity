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

**Resident memory** is RSS, sampled every 5 ms for the first three seconds and
every 100 ms after that. "Settled" is the last reading of the window; "peak" is
the highest. Both are reported because a tool can settle low and still spike
while it loads. The fine sampling is there to catch exactly that: a transient
narrower than 100 ms is invisible to a flat 100 ms sampler, which then reports
a peak that never happened. Sampling that fast for the whole window would cost
enough CPU to disturb the CPU rows, which is why the rate drops once both tools
have settled.

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
CPU ranged from 240 ms to 280 ms and ziggity's from 30 ms to 40 ms. On a
machine doing anything else both spread several times wider than that, so
treat a single CPU figure as approximate; the medians are stable and the gap
between the tools is consistent either way. Resident memory moves by a
megabyte or two between runs. Binary size, library count, startup and peak
parallelism are effectively constant.

**Repository state matters.** The numbers depend on commits, refs, worktrees
and modified files. Registering an extra git worktree adds calls and shifts the
load count, and a repository with real uncommitted work in it behaves
differently from a clean one. The published table says which state it was
measured in, and yours should too.

Untracked build output is the one thing that costs nothing. `.zig-cache`,
`zig-out` and `zig-pkg` are gitignored, and git prunes an ignored directory
rather than descending into it, so `status` returns in about 20 ms however
large they grow. A working checkout and a pristine clone of the same history
measure the same, which means you can benchmark in the tree you actually work
in.

**Both tools must be comparable.** lazygit is measured as installed. If yours
differs in version from the published table, the columns are not comparable.
