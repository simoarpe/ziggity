// A stand-in for `git` that records every invocation, then runs the real one.
//
// bench.py puts a directory containing this binary (named `git`) first on the
// PATH of the tool being measured. Every git call the tool makes lands here
// first, gets a line in the log, and is forwarded unchanged. Exit status and
// all three standard streams pass straight through, so the tool cannot tell
// the difference.
//
// One tab separated line per call:
//   start  end  utime  stime  maxrss  argv...
//
// Times are CLOCK_MONOTONIC seconds. utime and stime are that git process's
// own CPU, taken from wait4, which is why the CPU rows can separate the tool's
// own work from the work it hands to git.
//
// Environment:
//   SHIM_REAL_GIT  absolute path to the real git (required in practice)
//   SHIM_LOG       file to append to; no logging if unset
//
// Portable POSIX; builds on macOS and Linux with `cc -O2 -o git gitshim.c`.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/time.h>
#include <sys/resource.h>
#include <time.h>

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    const char *real = getenv("SHIM_REAL_GIT");
    const char *logp = getenv("SHIM_LOG");
    if (!real) real = "/usr/bin/git";

    double t0 = now();
    pid_t pid = fork();
    if (pid < 0) {
        perror("gitshim: fork");
        return 127;
    }
    if (pid == 0) {
        argv[0] = (char *)real;
        execv(real, argv);
        perror("gitshim: execv");
        _exit(127);
    }

    int status = 0;
    struct rusage ru;
    memset(&ru, 0, sizeof ru);
    if (wait4(pid, &status, 0, &ru) < 0) {
        perror("gitshim: wait4");
        return 127;
    }
    double t1 = now();

    if (logp) {
        FILE *f = fopen(logp, "a");
        if (f) {
            double u = ru.ru_utime.tv_sec + ru.ru_utime.tv_usec / 1e6;
            double s = ru.ru_stime.tv_sec + ru.ru_stime.tv_usec / 1e6;
            fprintf(f, "%.6f\t%.6f\t%.6f\t%.6f\t%ld\t", t0, t1, u, s, ru.ru_maxrss);
            for (int i = 1; i < argc; i++)
                fprintf(f, "%s%s", argv[i], i + 1 < argc ? " " : "");
            fputc('\n', f);
            fclose(f);
        }
    }

    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 0;
}
