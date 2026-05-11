# pihole_sync.sh

A bash script to keep two Pi-hole v6 instances in sync by replicating `gravity.db` (adlists, allow/blocklists, group and client assignments) from a primary node to a secondary node via a shared NFS mount.

## Requirements

- Pi-hole v6
- `sqlite3` installed on the primary node (`apt install sqlite3`)
- A shared NFS mount accessible on both nodes at the same path
- Both nodes NTP-synced (recommended)

## How it works

### Primary node

1. Captures a consistent snapshot of `gravity.db` using SQLite's online backup API, which safely reads the live database without risk of copying a mid-write or corrupt file
2. Computes a SHA256 checksum of the snapshot and compares it against a sidecar file (`gravity.db.sha256`) on the NAS — avoiding a full 400MB+ NFS read on every run
3. If checksums differ (or `-f` force flag is passed), copies the snapshot to the NAS share and updates the sidecar checksum file
4. Writes a sentinel file to the NAS share to signal completion to the secondary

### Secondary node

1. Polls for the sentinel file written by primary, waiting up to 60 seconds in 5-second intervals
2. Once detected, removes the sentinel file and computes a SHA256 checksum of its local `gravity.db`
3. Compares the local checksum against the sidecar file on the NAS — again avoiding a full NFS read of `gravity.db` when nothing has changed
4. If checksums differ (or `-f` force flag is passed), copies `gravity.db` from the NAS to `/etc/pihole/` and runs `pihole reloadlists` to apply the updated database

### Both nodes

- Append syslog entries for the current run to a dated log file (`pihole_sync-<NODE_NAME>-YYYY-MM-DD.log`) on the NAS share for centralized review
- Prune any previous log files for their node, retaining only the current day's log

## Deployment

Both nodes run the same script, differentiated by the `NODE_TYPE` configuration variable. The script is intended to run via cron. The primary should be scheduled to run first, with the secondary offset by at least 1 minute to account for the sqlite backup time on large databases:

```
# Primary
*/15 * * * * sudo bash /home/<user>/scripts/pihole_sync.sh

# Secondary (1 minute offset)
1-59/15 * * * * sudo bash /home/<user>/scripts/pihole_sync.sh
```

## Configuration

Edit the configuration block at the top of the script on each node:

| Variable | Description |
|---|---|
| `NODE_NAME` | Unique name for this node, used in log entries and log filename |
| `NODE_TYPE` | `primary` or `secondary` |
| `LOCAL_DIR` | Path to Pi-hole config directory, default `/etc/pihole` |
| `REMOTE_DIR` | Path to the shared NFS directory used for sync |

## Force sync

Pass `-f` to force a sync regardless of checksum comparison:

```bash
sudo bash pihole_sync.sh -f
```

## Logs

Each run appends syslog entries to a dated log file (`pihole_sync-<NODE_NAME>-YYYY-MM-DD.log`) in `REMOTE_DIR`. Only the current day's log is retained per node — previous days are pruned automatically on each run. Entries are also written to the local syslog via `logger`.

## First run

After deploying to both nodes, run a forced sync on the primary to generate the initial `gravity.db.sha256` sidecar file:

```bash
sudo bash pihole_sync.sh -f
```
