# zypper-auto-remove

A small Bash wrapper that removes orphaned packages on openSUSE and other
zypper-based systems. It fills the gap left by zypper having no single
`autoremove` command the way `apt` does.

It asks zypper for the list of unneeded packages, shows you that list, and
passes it to `zypper remove`. zypper still prints its own transaction summary
and still asks for confirmation unless you tell it not to.

## What "unneeded" actually means

`zypper packages --unneeded` reports installed packages that no other
installed package requires. That is close to `apt autoremove`, but not the
same thing, and the difference matters:

- zypper's list is based on the current dependency graph, not on a separate
  "manually installed" flag like apt and dpkg maintain. Results are usually
  sensible but occasionally include things you installed on purpose.
- Anything you installed directly that has no reverse dependencies can show
  up here. Standalone tools are the usual example.
- Removing orphans can orphan further packages, so one run does not always
  drain the list. Use `--repeat`, or just run it again.

Read the list before confirming. This script does not decide what is safe to
delete; it only surfaces what zypper already believes is unused.

## Requirements

- openSUSE or another zypper-based distribution
- Bash 4.4 or newer
- root for the actual removal (`--dry-run` works as a normal user)

## Install

```bash
curl -O https://raw.githubusercontent.com/NullAngst/zypper-auto-remove/main/zypper-auto-remove.sh
chmod +x zypper-auto-remove.sh
```

Optionally put it on your `PATH`:

```bash
sudo install -m 755 zypper-auto-remove.sh /usr/local/bin/zypper-auto-remove
```

## Usage

See what would go, without touching anything:

```bash
./zypper-auto-remove.sh --dry-run
```

Remove, with zypper's normal confirmation prompt:

```bash
sudo ./zypper-auto-remove.sh
```

Remove without any prompt:

```bash
sudo ./zypper-auto-remove.sh --yes
```

Keep going until the orphan list is empty:

```bash
sudo ./zypper-auto-remove.sh --repeat
```

### Options

| Option | Effect |
| --- | --- |
| `-n`, `--dry-run` | List candidates and exit. No root required. |
| `-y`, `--yes` | Pass `--non-interactive` to zypper, so nothing prompts. |
| `-k`, `--keep-deps` | Drop `--clean-deps`, so zypper removes only the listed packages. |
| `-r`, `--repeat` | Re-scan and remove again until the list is empty (5 passes max). |
| `-h`, `--help` | Usage summary. |
| `-V`, `--version` | Version string. |

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success, or nothing to remove |
| 1 | Usage error, zypper missing, or zypper failed |
| 2 | Removal succeeded, reboot required (zypper's 102) |
| 3 | Removal succeeded, zypper must be restarted (zypper's 103) |

## About `--clean-deps`

By default the script passes `--clean-deps`, which tells zypper to also drop
dependencies that become unneeded as a result of the removal. That makes a
single pass more thorough, but it means zypper can remove more than the list
the script printed. zypper's own summary is authoritative; the script's list
is a preview.

Use `--keep-deps` if you want the removal confined to exactly what was shown.

## Warnings

- The script flags kernel, KMP, `dracut`, `grub2`, `systemd` and `glibc`
  entries if they appear, but it does not block them. If you see a kernel
  package in the list, stop and figure out why before continuing.
- `--yes` skips your last chance to review the transaction. It is meant for
  cases where you already ran `--dry-run` and know what is going to happen,
  not for cron.
- Old kernels are better handled by `purge-kernels` and the
  `multiversion.kernels` setting in `/etc/zypp/zypp.conf`.
- Nothing here is reversible in-place. Reinstalling is the only undo.

## How the parsing works, and where it can break

`zypper packages --unneeded` has no machine-readable output mode, so the
script parses the human-readable table:

```
S  | Repository | Name    | Version | Arch
---+------------+---------+---------+-------
i  | Main Repo  | libfoo1 | 1.2-3   | x86_64
```

Specifics:

- `LC_ALL=C` is forced so translated output does not shift anything.
- Rows are accepted only if the status column is exactly `i` or `i+`.
- The name is read as the third field from the right, not the third from the
  left, so a repository alias containing a `|` cannot shift the column.
- Names are checked against `^[A-Za-z0-9][A-Za-z0-9._+-]*$`. Anything that
  fails is skipped with a warning on stderr rather than handed to `zypper
  remove`.
- Duplicates (the same package listed for several architectures or repos) are
  collapsed.

This is still table scraping. If a future zypper release changes the column
layout, the script will either find nothing or warn about unparseable
entries; it should not silently remove the wrong thing, but check a
`--dry-run` after a major zypper upgrade.

If zypper itself fails while listing, the script exits non-zero instead of
treating the empty output as "nothing to do".
