# Shell Script Projects

Bash scripts for Linux and Azure operations work. Each project is small enough to read in a few
minutes, uses `set -euo pipefail`, has `--help` and clear exit codes, passes `shellcheck`, and has a
README with sample output and an honest "Tested" section.

## Projects

| Folder | What it shows | Main tools | Status |
| --- | --- | --- | --- |
| [project1](project1/README.md) | System resource report (CPU, memory, disk, top processes, uptime) to a log file, cron-ready | Bash, `/proc`, `df`, `ps`, cron | Validated locally |
| [project2](project2/README.md) | Colorized system information summary for a Linux host | Bash, `/proc`, `/etc/os-release` | Validated locally |
| [project4-backup-with-verification](project4-backup-with-verification/README.md) | Backup with checksum, restore test, safe rotation, locking and a cron example | Bash, tar, sha256sum, flock, cron | Validated locally |

## Prerequisites

- Linux with Bash 4+ (the scripts read `/proc` and use GNU or BusyBox tools).
- [ShellCheck](https://www.shellcheck.net/) for linting.
- project4: GNU `tar`, `sha256sum`, `flock` (util-linux).

## How to use

```bash
git clone https://github.com/SivaKumarMahan/shell-script.git
cd shell-script

# Lint everything (uses .shellcheckrc so 'source lib.sh' is followed)
git ls-files '*.sh' | xargs shellcheck -x

# Run the test suites
project4-backup-with-verification/tests/run-tests.sh

# Try the scripts
./project1/system_monitor.sh -l ./system_monitor.log -s
./project2/system_info.sh
```

Each project README has the full usage, verification and clean-up steps.

## Repo layout

```text
.
├── .github/workflows/ci.yml          # shellcheck and tests
├── .shellcheckrc                     # follow sourced files relative to each script
├── project1/                         # system_monitor.sh
├── project2/                         # system_info.sh
└── project4-backup-with-verification/  # backup.sh, restore.sh, cron.example, tests/
```

## CI

`.github/workflows/ci.yml` runs on push and pull request:

1. `shellcheck` on every script.
2. Smoke runs of project1/project2 and the project4 tests.

The workflow was checked with `actionlint`, but it has not run on GitHub yet (nothing was pushed).
No secrets are needed.

## Skills demonstrated

- Defensive Bash: `set -euo pipefail`, quoting, `getopts` and long-option parsing, input
  validation, exit codes, traps for clean-up, `pipefail`/SIGPIPE pitfalls.
- Portable Linux scripting: `/proc` instead of scraping `top`, fallbacks for BusyBox and minimal images.
- Safe automation: dry run by default, plans before changes, confirmations that refuse to run
  without a terminal, secrets never on the command line or in logs.
- Testing shell code: a plain-bash test runner, time pinned for repeatable results.
- Backup engineering: checksums, restore tests, atomic publish, rotation only after success, `flock`.
- CI for scripts: ShellCheck and tests in GitHub Actions.
