#!/usr/bin/env python3
"""Measure ziggity against lazygit and print the comparison table.

Produces every row of the table in docs/comparison.md. It measures; it does
not estimate. See README.md in this directory for what each row means.

    python3 docs/bench/bench.py

Needs: a C compiler, python3, git, and lazygit on PATH for the comparison
column. Works on macOS and Linux.
"""
import argparse
import fcntl
import json
import os
import re
import shutil
import signal
import statistics
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import pty

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))

# Seconds of the run treated as the load phase, where memory is sampled finely.
# Both tools have finished their fan-out and settled well inside this.
LOAD_WINDOW = 3.0


# --------------------------------------------------------------------------
# environment
# --------------------------------------------------------------------------

def find(name, extra=None):
    if extra and os.path.isfile(extra) and os.access(extra, os.X_OK):
        return os.path.abspath(extra)
    return shutil.which(name)


def build_shim(workdir, cc="cc"):
    """Compile gitshim.c into <workdir>/shimbin/git."""
    shimbin = os.path.join(workdir, "shimbin")
    os.makedirs(shimbin, exist_ok=True)
    out = os.path.join(shimbin, "git")
    src = os.path.join(HERE, "gitshim.c")
    r = subprocess.run([cc, "-O2", "-o", out, src],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"failed to build the git shim:\n{r.stderr}")
    return shimbin


def base_env():
    """A clean environment for a measured child."""
    e = dict(os.environ)
    e["TERM"] = "xterm-256color"
    for k in ("SHIM_LOG", "SHIM_REAL_GIT"):
        e.pop(k, None)
    return e


# --------------------------------------------------------------------------
# static rows: binary size, linked libraries
# --------------------------------------------------------------------------

def linked_libraries(binary):
    """Count dynamically linked libraries. macOS otool, Linux ldd."""
    if sys.platform == "darwin":
        r = subprocess.run(["otool", "-L", binary], capture_output=True, text=True)
        if r.returncode != 0:
            return None
        # first line is the binary's own name
        return len([l for l in r.stdout.splitlines()[1:] if l.strip()])
    r = subprocess.run(["ldd", binary], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    lines = [l for l in r.stdout.splitlines() if "=>" in l or ".so" in l]
    return len(lines) or None


# --------------------------------------------------------------------------
# startup row: median of N runs of --version
# --------------------------------------------------------------------------

def startup_ms(binary, n=30, warmup=5):
    ts = []
    env = base_env()
    for i in range(n + warmup):
        t0 = time.perf_counter()
        subprocess.run([binary, "--version"], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, env=env)
        dt = (time.perf_counter() - t0) * 1000
        if i >= warmup:
            ts.append(dt)
    return {"median_ms": statistics.median(ts), "min_ms": min(ts),
            "p90_ms": sorted(ts)[int(len(ts) * 0.9)], "n": len(ts)}


# --------------------------------------------------------------------------
# runtime rows: run the TUI under a pty and watch it
# --------------------------------------------------------------------------

def ps_field(pid, fmt):
    """A single ps field. fmt ends with '=' so ps prints no header."""
    r = subprocess.run(["ps", "-o", fmt, "-p", str(pid)],
                       capture_output=True, text=True)
    lines = [l.strip() for l in r.stdout.splitlines() if l.strip()]
    if lines and not fmt.endswith("="):
        lines = lines[1:]
    return lines[0] if lines else None


def cpu_seconds(pid):
    """Cumulative CPU of a process. Handles [[dd-]hh:]mm:ss[.ss]."""
    v = ps_field(pid, "time=")
    if not v:
        return None
    days = 0
    if "-" in v:
        d, v = v.split("-", 1)
        days = int(d)
    sec = 0.0
    for part in v.split(":"):
        sec = sec * 60 + float(part)
    return sec + days * 86400


def run_tui(binary, repo, seconds, shimbin, real_git, workdir, label):
    """Launch the TUI under a pty, sample it, and collect its git calls."""
    log = os.path.join(workdir, f"gitlog-{label}.tsv")
    open(log, "w").close()

    env = base_env()
    env["PATH"] = shimbin + os.pathsep + env.get("PATH", "")
    env["SHIM_REAL_GIT"] = real_git
    env["SHIM_LOG"] = log

    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 200, 0, 0))

    def child_setup():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)   # claim the pty as controlling tty

    t_start = time.perf_counter()
    p = subprocess.Popen([binary], cwd=repo, stdin=slave, stdout=slave,
                         stderr=slave, env=env, preexec_fn=child_setup)
    os.close(slave)

    stop = threading.Event()

    def drain():
        # the pty buffer must keep moving or the tool blocks on write
        while not stop.is_set():
            try:
                if not os.read(master, 65536):
                    break
            except OSError:
                break
    threading.Thread(target=drain, daemon=True).start()

    # RSS is sampled finely while the repository loads and coarsely afterwards.
    # A transient during the load can be narrower than 100 ms, so a flat 100 ms
    # sampler steps straight over it and reports a peak that never happened.
    # Sampling that fast for the whole window would cost enough CPU to disturb
    # the rows below it, hence the two rates.
    rss = []
    while True:
        elapsed = time.perf_counter() - t_start
        if elapsed >= seconds or p.poll() is not None:
            break
        v = ps_field(p.pid, "rss=")
        if v:
            rss.append(int(v) / 1024.0)          # KiB -> MiB
        time.sleep(0.005 if elapsed < LOAD_WINDOW else 0.1)

    alive = p.poll() is None
    cpu_self = cpu_seconds(p.pid) if alive else None

    try:
        os.killpg(os.getpgid(p.pid), signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    stop.set()
    try:
        p.wait(timeout=10)
    except subprocess.TimeoutExpired:
        pass
    os.close(master)
    time.sleep(0.3)                              # let the last shim line land

    procs = []
    for line in open(log):
        f = line.rstrip("\n").split("\t")
        if len(f) < 6:
            continue
        procs.append({"start": float(f[0]), "end": float(f[1]),
                      "utime": float(f[2]), "stime": float(f[3]),
                      "argv": f[5]})
    procs.sort(key=lambda x: x["start"])

    # peak concurrency, by sweeping the start/end events
    events = [(x["start"], 1) for x in procs] + [(x["end"], -1) for x in procs]
    events.sort()
    cur = peak = 0
    for _, delta in events:
        cur += delta
        peak = max(peak, cur)

    t0 = procs[0]["start"] if procs else None
    timeline = [{"t_ms": round((x["start"] - t0) * 1000, 1),
                 "dur_ms": round((x["end"] - x["start"]) * 1000, 1),
                 "cmd": x["argv"]} for x in procs] if t0 is not None else []

    return {
        "ran_full_window": alive,
        "rss_settled_mib": rss[-1] if rss else None,
        "rss_peak_mib": max(rss) if rss else None,
        "cpu_self_sec": cpu_self,
        "cpu_git_sec": sum(x["utime"] + x["stime"] for x in procs),
        "git_procs_window": len(procs),
        "peak_parallel_git": peak,
        "timeline": timeline,
    }


def load_phase(timeline, gap_ms=400):
    """git calls up to the first quiet gap after the parallel fan-out.

    Both tools make one or two cheap pre-flight calls, pause, then fan out to
    load every panel. Clusters separated by more than gap_ms are different
    phases; loading ends with the first cluster of 3 or more calls.
    """
    if not timeline:
        return [], []
    clusters, cur, prev = [], [], None
    for e in timeline:
        if prev is not None and e["t_ms"] - prev > gap_ms:
            clusters.append(cur)
            cur = []
        cur.append(e)
        prev = e["t_ms"]
    if cur:
        clusters.append(cur)

    load = []
    for c in clusters:
        load += c
        if len(c) >= 3:                          # the fan-out
            break
    net = [e for e in load if re.search(r"\b(fetch|ls-remote)\b", e["cmd"])]
    return [e for e in load if e not in net], net


# --------------------------------------------------------------------------
# reporting
# --------------------------------------------------------------------------

def mib(n):
    return f"{n / (1024 * 1024):.1f} MB"


def summarize(runs):
    def med(key):
        vals = [r[key] for r in runs if r.get(key) is not None]
        return statistics.median(vals) if vals else None

    loads = [load_phase(r["timeline"]) for r in runs]
    fetch_offsets = [
        next((e["t_ms"] for e in r["timeline"]
              if re.search(r"\bfetch\b", e["cmd"])), None) for r in runs]
    return {
        "rss_settled_mib": med("rss_settled_mib"),
        "rss_peak_mib": med("rss_peak_mib"),
        "cpu_self_sec": med("cpu_self_sec"),
        "cpu_git_sec": med("cpu_git_sec"),
        "cpu_total_sec": statistics.median(
            [(r["cpu_self_sec"] or 0) + r["cpu_git_sec"] for r in runs]),
        "git_procs_window": med("git_procs_window"),
        "peak_parallel_git": med("peak_parallel_git"),
        "git_procs_to_load": statistics.median([len(l) for l, _ in loads]),
        "fetch_during_load": statistics.median([len(n) for _, n in loads]),
        "fetch_offset_ms": fetch_offsets,
    }


def markdown_table(res, window):
    a, b = res["ziggity"], res["lazygit"]
    aa, ba = a["agg"], b["agg"]

    def net(agg):
        return "`git fetch --all`" if agg["fetch_during_load"] >= 1 else "none"

    rows = [
        ("Binary size", mib(a["size_bytes"]), mib(b["size_bytes"])),
        ("Dynamic libraries linked", a["libs"], b["libs"]),
        ("Process startup, median of 30 runs",
         f"{a['startup']['median_ms']:.1f} ms", f"{b['startup']['median_ms']:.1f} ms"),
        ("Git subprocesses to load the repo",
         f"{aa['git_procs_to_load']:.0f}", f"{ba['git_procs_to_load']:.0f}"),
        ("Peak git processes running in parallel",
         f"{aa['peak_parallel_git']:.0f}", f"{ba['peak_parallel_git']:.0f}"),
        ("Network during load", net(aa), net(ba)),
        ("Resident memory once settled",
         f"{aa['rss_settled_mib']:.0f} MB", f"{ba['rss_settled_mib']:.0f} MB"),
        ("Peak resident memory while loading",
         f"{aa['rss_peak_mib']:.0f} MB", f"{ba['rss_peak_mib']:.0f} MB"),
        (f"Git subprocesses over {window:.0f} s idle",
         f"{aa['git_procs_window']:.0f}", f"{ba['git_procs_window']:.0f}"),
        (f"Own CPU time over {window:.0f} s",
         f"{aa['cpu_self_sec'] * 1000:.0f} ms", f"{ba['cpu_self_sec'] * 1000:.0f} ms"),
        ("Total CPU including git children",
         f"{aa['cpu_total_sec'] * 1000:.0f} ms", f"{ba['cpu_total_sec'] * 1000:.0f} ms"),
    ]
    out = [f"| | ziggity {res['ziggity_version']} | lazygit {res['lazygit_version']} |",
           "|---|---|---|"]
    out += [f"| {k} | {v1} | {v2} |" for k, v1, v2 in rows]
    return "\n".join(out)


def version_of(binary):
    r = subprocess.run([binary, "--version"], capture_output=True, text=True)
    m = re.search(r"\d+\.\d+\.\d+", r.stdout + r.stderr)
    return m.group(0) if m else "?"


# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=REPO_ROOT,
                    help="repository both tools open (default: this repo)")
    ap.add_argument("--ziggity", default=os.path.join(REPO_ROOT, "zig-out/bin/ziggity"),
                    help="ziggity binary (default: ./zig-out/bin/ziggity)")
    ap.add_argument("--lazygit", default=None, help="lazygit binary (default: from PATH)")
    ap.add_argument("--window", type=float, default=10.0,
                    help="seconds to hold each tool open (default: 10)")
    ap.add_argument("--reps", type=int, default=3,
                    help="repetitions per tool; rows are medians (default: 3)")
    ap.add_argument("--json", default=None, help="also write full results here")
    args = ap.parse_args()

    ziggity = find("ziggity", args.ziggity)
    lazygit = find("lazygit", args.lazygit)
    real_git = shutil.which("git")
    if not ziggity:
        sys.exit("ziggity not found. Build it first: zig build -Doptimize=ReleaseSafe")
    if not lazygit:
        sys.exit("lazygit not found on PATH; it is needed for the comparison column.")
    if not real_git:
        sys.exit("git not found on PATH.")

    repo = os.path.abspath(args.repo)
    res = {
        "repo": repo,
        "window_seconds": args.window,
        "reps": args.reps,
        "ziggity_version": version_of(ziggity),
        "lazygit_version": version_of(lazygit),
    }

    with tempfile.TemporaryDirectory(prefix="ziggity-bench-") as workdir:
        shimbin = build_shim(workdir)

        for name, binary in (("ziggity", ziggity), ("lazygit", lazygit)):
            print(f"[{name}] binary + startup...", file=sys.stderr)
            res[name] = {
                "path": binary,
                "size_bytes": os.path.getsize(binary),
                "libs": linked_libraries(binary),
                "startup": startup_ms(binary),
                "runs": [],
            }

        for rep in range(args.reps):
            for name, binary in (("ziggity", ziggity), ("lazygit", lazygit)):
                print(f"[{name}] run {rep + 1}/{args.reps} "
                      f"({args.window:.0f}s)...", file=sys.stderr)
                res[name]["runs"].append(
                    run_tui(binary, repo, args.window, shimbin, real_git, workdir, name))
                time.sleep(1)

    for name in ("ziggity", "lazygit"):
        res[name]["agg"] = summarize(res[name]["runs"])

    if args.json:
        with open(args.json, "w") as f:
            json.dump(res, f, indent=2)
        print(f"full results: {args.json}", file=sys.stderr)

    print()
    print(markdown_table(res, args.window))
    print()
    for name in ("ziggity", "lazygit"):
        off = [o for o in res[name]["agg"]["fetch_offset_ms"] if o is not None]
        when = f"{statistics.median(off):.0f} ms after the first git call" if off else "never"
        print(f"# {name}: first fetch {when}", file=sys.stderr)


if __name__ == "__main__":
    main()
