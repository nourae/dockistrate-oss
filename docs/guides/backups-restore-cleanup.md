# Backups, Restore, and Cleanup

Dockistrate stores runtime state under `state/`. Use backup, restore, cleanup,
uninstall, and permission commands to manage that state safely.

## Common Commands

```text
create-backup [desc]
list-backups
restore-backup <backup_name|backup_path>

clean-all <domain>
uninstall-all [--scope backend|config|all]
fix-permissions [--certbot-darwin-user]
```

## Backups

Create and list backups:

```bash
./dockistrate.sh create-backup before-change
./dockistrate.sh list-backups
```

Backups snapshot managed config/state and can be compressed depending on
settings. If compression fails, Dockistrate keeps the usable backup directory
instead of leaving only a failed archive.

## Restore

Restore by exact backup name from `list-backups`, or by safe archive path:

```bash
./dockistrate.sh restore-backup 20260516_153000_before-change.tar.gz
```

Restore rejects unsafe archive paths, requires one top-level directory, restores
`state/config` in place, refreshes permissions, regenerates Nginx config, and
checks config when Docker validation is available. If validation fails
mid-restore, rollback clears restored content before replaying the pre-change
backup.

## Compression Regression Check

The detailed compression-failure check is useful for maintainers rather than
README readers. It can be run from the repo root:

```bash
previous_compression="$(awk -F, '$1=="ENABLE_BACKUP_COMPRESSION"{print $2}' state/config/global_settings.csv 2>/dev/null || true)"
./dockistrate.sh set-backup-compression true
./dockistrate.sh create-backup precheck
tmp_bin="$(mktemp -d)"
printf '%s\n' '#!/usr/bin/env bash' 'echo "tar failed intentionally" >&2' 'exit 2' > "${tmp_bin}/tar"
chmod +x "${tmp_bin}/tar"
PATH="${tmp_bin}:$PATH" ./dockistrate.sh create-backup compression-failure-test
find state/backups -maxdepth 2 -mindepth 1
rm -rf "$tmp_bin"
./dockistrate.sh create-backup compression-restored
./dockistrate.sh set-backup-compression "${previous_compression:-true}"
```

This avoids nested heredoc Markdown in documentation while preserving the
reproduction steps.

## Cleanup and Uninstall

Remove all references for one domain:

```bash
./dockistrate.sh clean-all example.com
```

Uninstall by scope:

```bash
./dockistrate.sh -i uninstall-all --scope backend
./dockistrate.sh -i uninstall-all --scope config
./dockistrate.sh -i uninstall-all --scope all
```

`uninstall-all` requires an interactive confirmation with exact `YES`.
Container removals use Docker volume cleanup for anonymous volumes attached to
Dockistrate-managed containers.

## Permissions

Normalize repository and runtime permissions:

```bash
./dockistrate.sh fix-permissions
```

On macOS, prepare Certbot mounts for the invoking sudo user:

```bash
sudo ./dockistrate.sh fix-permissions --certbot-darwin-user
```

The Darwin Certbot path rejects symlinked Certbot mount roots before ownership
or mode changes and keeps TLS private keys restricted.
