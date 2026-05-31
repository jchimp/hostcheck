#!/usr/bin/env bash
###############################################################################
# install-health.sh
#
# Installs the host-healthcheck script, config, and cron job.
#
###############################################################################

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_BIN="/usr/local/bin/hostcheck-health.sh"
CONF_DIR="/etc/hostcheck"
CONF_FILE="${CONF_DIR}/hostcheck-health.conf"
STATE_DIR="/var/lib/hostcheck-health"
CRON_FILE="/etc/cron.d/hostcheck-health"

echo "==> Installing hostcheck-health"

# ── Install smartmontools if needed ──────────────────────────────────────────
#if ! command -v smartctl &>/dev/null; then
#  echo "    Installing smartmontools..."
#  apt-get update -qq && apt-get install -y -qq smartmontools
#fi

# ── Check for optional dependencies ─────────────────────────────────────────
echo ""
echo "==> Checking optional dependencies"

if command -v smartctl &>/dev/null; then
  echo "    ✓ smartctl found"
else
  echo "    ⚠ smartctl NOT found — SMART checks will be skipped at runtime"
  echo "      Install: apt install smartmontools"
fi

if command -v corosync-quorumtool &>/dev/null; then
  echo "    ✓ corosync-quorumtool found"
else
  echo "    ⚠ corosync-quorumtool NOT found — Corosync checks will be skipped at runtime"
  echo "      Expected on Proxmox nodes. Not needed on standalone Linux hosts."
fi

if command -v pvecm &>/dev/null; then
  echo "    ✓ pvecm found"
else
  echo "    ⚠ pvecm NOT found — Peer auto-detect will require PEER_HOSTS in config"
  echo "      Expected on Proxmox nodes. Set PEER_HOSTS manually on non-Proxmox hosts."
fi

# ── Copy script ──────────────────────────────────────────────────────────────
cp "${SCRIPT_DIR}/hostcheck-health.sh" "$INSTALL_BIN"
chmod 755 "$INSTALL_BIN"
echo "    Script installed: $INSTALL_BIN"

# ── Copy config (preserve existing) ─────────────────────────────────────────
mkdir -p "$CONF_DIR"
if [[ -f "$CONF_FILE" ]]; then
  echo "    Config already exists (not overwritten): $CONF_FILE"
  echo "    New template saved as: ${CONF_FILE}.new"
  cp "${SCRIPT_DIR}/hostcheck-health.conf" "${CONF_FILE}.new"
else
  cp "${SCRIPT_DIR}/hostcheck-health.conf" "$CONF_FILE"
  chmod 600 "$CONF_FILE"
  echo "    Config installed: $CONF_FILE"
fi

# ── Create state directory ───────────────────────────────────────────────────
mkdir -p "$STATE_DIR"
echo "    State directory: $STATE_DIR"

# ── Install cron job ─────────────────────────────────────────────────────────
cat > "$CRON_FILE" <<EOF
# Host health check — every 5 minutes
*/5 * * * * root ${INSTALL_BIN} >> /dev/null 2>&1
EOF

chmod 644 "$CRON_FILE"
echo "    Cron job installed: $CRON_FILE"

# ── Run once ─────────────────────────────────────────────────────────────────
echo "    Running health check once..."
"$INSTALL_BIN" --dry-run || echo "    WARN: dry-run returned non-zero"

echo ""
echo "==> Installation complete"
echo ""
echo "Next steps:"
echo "  1. Edit config:   vi $CONF_FILE"
echo "  2. Set Telegram:  TELEGRAM_ENABLED, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID"
echo "  3. Set email:     EMAIL_ENABLED, EMAIL_TO"
echo "  4. Test:          $INSTALL_BIN --dry-run"
echo "  5. Monitor log:   tail -f /var/log/hostcheck-health.log"
