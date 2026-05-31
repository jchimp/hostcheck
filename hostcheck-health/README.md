# Host Health-Check Script for Proxmox / Ceph Nodes

A standalone Bash script that runs on each Proxmox host via cron, checks system health, and fires alerts via Telegram and/or email when problems are found.

No infrastructure dependencies. No Prometheus. No Docker. Just one script, one config file, and cron.

---

## What it checks

| Check | What it looks at | Severity |
|---|---|---|
| **NIC errors** | RX/TX errors, RX drops, interface operstate (delta-based) | warning / critical |
| **Disk space** | Filesystem usage percentage | warning (85%) / critical (95%) |
| **SMART** | Overall health, reallocated sectors, pending sectors, temperature, NVMe media errors | warning / critical |
| **Ceph** | Cluster health status, OSD down count, PG states (degraded/undersized/stale) | warning / critical |
| **Corosync** | Quorum status, ring faults, vote count mismatch | warning / critical |
| **Peer nodes** | Ping each cluster peer — auto-detected via `pvecm nodes` or manual IP list | critical |
| **CPU** | Usage percentage (sustained across two runs) | warning (90%) |
| **Memory** | Usage percentage | warning (90%) / critical (95%) |
| **Load average** | 15-min load vs CPU count × multiplier | warning |
| **Systemd** | Failed units | warning |
| **Filesystem** | Read-only mounts | critical |

---

## File layout

```
host-healthcheck/
├── host-healthcheck.sh          # Main health-check script
├── host-healthcheck.conf        # Configuration file (thresholds, notifications)
├── install-healthcheck.sh       # Installer (copies files, sets up cron)
└── README.md                    # This file
```

After installation:

```
/usr/local/bin/host-healthcheck.sh          # Executable
/etc/host-healthcheck/host-healthcheck.conf # Config (chmod 600)
/etc/cron.d/host-healthcheck                # Cron job (every 5 min)
/var/lib/host-healthcheck/                  # State files (cooldowns, deltas)
/var/log/host-healthcheck.log               # Local log
```

---

## Installation

### On each Proxmox node

```bash
# Copy files to the node
scp -r host-healthcheck/ root@<node>:/tmp/

# SSH in and run the installer
ssh root@<node>
cd /tmp/host-healthcheck
chmod +x install-healthcheck.sh
./install-healthcheck.sh
```

### Configure

```bash
vi /etc/host-healthcheck/host-healthcheck.conf
```

At minimum, set:

```conf
TELEGRAM_ENABLED="true"
TELEGRAM_BOT_TOKEN="123456:ABC-DEF..."
TELEGRAM_CHAT_ID="987654321"
```

### Test

```bash
# Dry run (no notifications sent)
host-healthcheck.sh --dry-run

# Live run
host-healthcheck.sh

# Watch the log
tail -f /var/log/host-healthcheck.log
```

---

## Peer reachability check

The script can detect **unreachable cluster nodes** by pinging every peer from every host.

### Auto-detect mode (default, recommended)

When `PEER_HOSTS` is empty (the default), the script:

1. Runs `pvecm nodes` to get the current cluster member list
2. Parses the node names from the output
3. Skips itself (matches against local hostname)
4. Pings each remaining peer

This works because Proxmox clusters always maintain `/etc/hosts` entries for all cluster members, so hostnames resolve without DNS. [Certain]

Example `pvecm nodes` output:

```
    Nodeid      Votes Name
         1          1 pve01
         2          1 pve02
         3          1 pve03
```

If you are on `pve01`, the script will ping `pve02` and `pve03`.

### Manual mode

If you prefer explicit control, or want to ping hosts that are not cluster members:

```conf
PEER_HOSTS="pve01 pve02 pve03"
```

or

```conf
PEER_HOSTS="10.0.0.11 10.0.0.12 10.0.0.13"
```

The script will still skip itself by hostname comparison.

### How it catches dead nodes

In a 3-node cluster:

- If `pve02` dies, the scripts on `pve01` and `pve03` will both alert:
  ```
  [CRITICAL] PEER
    Node pve02 is UNREACHABLE (ping failed)
  ```

- This fires within the next 5-minute cron cycle [Certain]
- The alert on `pve02` itself won't fire (it's dead), but **two other nodes report it** [Certain]

---

## Configuration reference

| Key | Default | Description |
|---|---|---|
| `TELEGRAM_ENABLED` | `false` | Enable Telegram notifications |
| `TELEGRAM_BOT_TOKEN` | *(empty)* | Telegram bot API token |
| `TELEGRAM_CHAT_ID` | *(empty)* | Telegram chat ID (numeric) |
| `EMAIL_ENABLED` | `false` | Enable email notifications |
| `EMAIL_TO` | `admin@example.com` | Email recipient |
| `EMAIL_FROM` | `healthcheck@hostname` | Email sender |
| `SYSLOG_ENABLED` | `true` | Log to syslog via `logger` |
| `SYSLOG_TAG` | `healthcheck` | Syslog tag |
| `ALERT_COOLDOWN_SEC` | `3600` | Seconds before repeating same alert |
| `CHECK_NIC` | `true` | Enable NIC error check |
| `CHECK_DISK` | `true` | Enable disk space check |
| `CHECK_SMART` | `true` | Enable SMART check |
| `CHECK_CEPH` | `true` | Enable Ceph health check |
| `CHECK_COROSYNC` | `true` | Enable Corosync check |
| `CHECK_PEERS` | `true` | Enable peer reachability check |
| `CHECK_CPU` | `true` | Enable CPU usage check |
| `CHECK_MEMORY` | `true` | Enable memory usage check |
| `CHECK_LOAD` | `true` | Enable load average check |
| `CHECK_SYSTEMD` | `true` | Enable systemd failed units check |
| `CHECK_FILESYSTEM` | `true` | Enable read-only filesystem check |
| `DISK_WARN_PCT` | `85` | Disk space warning threshold (%) |
| `DISK_CRIT_PCT` | `95` | Disk space critical threshold (%) |
| `CPU_WARN_PCT` | `90` | CPU usage warning threshold (%) |
| `MEM_WARN_PCT` | `90` | Memory usage warning threshold (%) |
| `MEM_CRIT_PCT` | `95` | Memory usage critical threshold (%) |
| `LOAD_WARN_MULTIPLIER` | `2` | Load avg alert = CPUs × this value |
| `SMART_TEMP_WARN` | `55` | SMART temperature warning (°C) |
| `PEER_HOSTS` | *(empty)* | Space-separated peer list (empty = auto-detect) |
| `PEER_PING_COUNT` | `3` | Number of ping attempts per peer |
| `PEER_PING_TIMEOUT` | `5` | Ping timeout in seconds |
| `STATE_DIR` | `/var/lib/host-healthcheck` | State file directory |
| `LOG_FILE` | `/var/log/host-healthcheck.log` | Local log file path |
| `NIC_EXCLUDE` | `lo\|veth.*\|fwbr.*\|...` | Regex for interfaces to skip |

---

## Alert cooldown

The script tracks each unique alert using an MD5 hash of the alert key (check name + message). When an alert fires, it writes a timestamp to a state file in `STATE_DIR`.

On subsequent runs, the script checks whether the cooldown period has elapsed before re-sending the same alert. This prevents notification spam when a problem persists.

**Default cooldown: 1 hour** (`ALERT_COOLDOWN_SEC=3600`)

State files older than 7 days are automatically cleaned up.

---

## NIC error detection (delta-based)

NIC error counters are cumulative since boot. The script stores the previous counter value and only alerts on **new errors since the last check**. This avoids false positives from historical counters.

---

## CPU sustained check

A single CPU spike is not necessarily a problem. The script checks if CPU was also high on the **previous run** before alerting. This means a CPU alert only fires if usage has been above the threshold for at least **two consecutive 5-minute intervals** (10+ minutes sustained).

---

## Telegram bot setup

1. Open Telegram and message `@BotFather`
2. Send `/newbot` and follow prompts → you'll get a **bot token**
3. Start a chat with your new bot and send any message
4. Get your **chat ID**:

```bash
curl -s "https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates" | python3 -m json.tool
```

Look for `"chat": {"id": 123456789, ...}`

5. Edit the config:

```conf
TELEGRAM_ENABLED="true"
TELEGRAM_BOT_TOKEN="123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11"
TELEGRAM_CHAT_ID="987654321"
```

---

## Email setup (optional)

The script tries these mail commands in order:

1. `msmtp` (recommended for homelab)
2. `sendmail`
3. `mail`

### msmtp quick setup

```bash
apt install msmtp msmtp-mta

cat > /etc/msmtprc <<EOF
account default
host smtp.gmail.com
port 587
from youraddress@gmail.com
auth on
user youraddress@gmail.com
password your-app-password
tls on
tls_starttls on
logfile /var/log/msmtp.log
EOF

chmod 600 /etc/msmtprc
```

Then in the config:

```conf
EMAIL_ENABLED="true"
EMAIL_TO="admin@example.com"
```

---

## Example alert output (Telegram)

```
🔥 4 alert(s) on pve01

[CRITICAL] PEER
  Node pve02 is UNREACHABLE (ping failed)

[CRITICAL] NIC
  Interface enp2s0 is DOWN

[WARNING] CEPH
  Ceph cluster is in HEALTH_WARN

[WARNING] SMART
  Disk sda has 24 reallocated sectors

Time: 2026-05-30 14:35:02
```

---

## Example log output

```
[2026-05-30 14:35:02] [pve01] ========== Health check starting ==========
[2026-05-30 14:35:02] [pve01] Checking NIC health
[2026-05-30 14:35:02] [pve01] Checking disk space
[2026-05-30 14:35:02] [pve01] Checking SMART health
[2026-05-30 14:35:02] [pve01] Checking Ceph health
[2026-05-30 14:35:02] [pve01] Checking Corosync
[2026-05-30 14:35:02] [pve01] Checking peer reachability
[2026-05-30 14:35:02] [pve01] Peer list source: pvecm nodes (3 entries)
[2026-05-30 14:35:02] [pve01] Skipping self: pve01
[2026-05-30 14:35:03] [pve01] Peer reachable: pve03
[2026-05-30 14:35:08] [pve01] ALERT [CRITICAL] PEER: Node pve02 is UNREACHABLE (ping failed)
[2026-05-30 14:35:08] [pve01] Checking CPU usage
[2026-05-30 14:35:10] [pve01] Checking memory usage
[2026-05-30 14:35:10] [pve01] Checking load average
[2026-05-30 14:35:10] [pve01] Checking systemd failed units
[2026-05-30 14:35:10] [pve01] Checking for read-only filesystems
[2026-05-30 14:35:10] [pve01] Sent 1 alert(s)
[2026-05-30 14:35:10] [pve01] ========== Health check complete (1 alert(s)) ==========
```

---

## Troubleshooting

### No alerts are being sent

- Run manually: `sudo host-healthcheck.sh`
- Check the log: `tail -50 /var/log/host-healthcheck.log`
- Look for `COOLDOWN` entries — the alert may have already been sent within the cooldown window
- Verify Telegram credentials: `curl "https://api.telegram.org/bot<TOKEN>/getMe"`
- Verify curl is installed: `which curl`

### Peer check says "pvecm not found"

- Set `PEER_HOSTS` manually in the config as a fallback
- Or verify you're running on a Proxmox node with `pvecm` available

### SMART checks are skipped

- Verify smartmontools: `which smartctl`
- Install if missing: `apt install smartmontools`
- Try manually: `smartctl --scan`

### Ceph checks are skipped

- The script only runs Ceph checks if the `ceph` command is available
- On non-Ceph nodes, set `CHECK_CEPH="false"` in the config

### Alert keeps repeating

- The cooldown is per unique alert message
- If the message changes slightly (e.g., different error count), it counts as a new alert
- Increase `ALERT_COOLDOWN_SEC` if needed

---

## Limitations

- This is a **point-in-time check**, not continuous monitoring. It runs every 5 minutes and checks the current state. Short-lived spikes between runs will not be caught.
- **CPU check** takes 2 seconds (samples /proc/stat twice). This adds a small delay to each run.
- **SMART attribute parsing** handles standard ATA and NVMe drives. Drives with non-standard attribute names may not be fully parsed.
- **Ceph health parsing** uses the JSON output from `ceph status`. It should work with all modern Ceph versions (Luminous+).
- **Peer check** depends on ICMP being allowed between nodes. If you have firewall rules blocking ping, the check will false-positive.
- There is **no dashboard or history**. For that, use the Prometheus + Grafana stack.

---

## Uninstall

```bash
rm -f /usr/local/bin/host-healthcheck.sh
rm -f /etc/cron.d/host-healthcheck
rm -rf /etc/host-healthcheck
rm -rf /var/lib/host-healthcheck
rm -f /var/log/host-healthcheck.log
```

---

## Quick reference

| Action | Command |
|---|---|
| Run manually | `sudo host-healthcheck.sh` |
| Dry run | `sudo host-healthcheck.sh --dry-run` |
| Custom config | `sudo host-healthcheck.sh --config /path/to/conf` |
| Edit config | `vi /etc/host-healthcheck/host-healthcheck.conf` |
| View log | `tail -f /var/log/host-healthcheck.log` |
| Check cron | `cat /etc/cron.d/host-healthcheck` |
| Clear cooldowns | `rm /var/lib/host-healthcheck/*` |
