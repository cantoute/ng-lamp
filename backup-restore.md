# Restaure Backups examples

## list of snapshots

```bash
borg list ssh://backups@host/./backup-name/

borg extract --dry-run --list ssh://backups@host/./backup-name/::backup-name-2023-04-23T04:15:53 2>&1 | less

borg extract ssh://backups@host/./backup-name/::backup-name-2023-04-23T04:15:53 path-to-restore
```
