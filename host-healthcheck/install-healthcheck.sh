#!/usr/bin/env bash
###############################################################################
# install-healthcheck.sh
#
# Installs the host-healthcheck script, config, and cron job.
# Idempotent — safe to re-run.
#
# Usage:
#   chmod +x install-healthcheck.sh
#   sudo ./install-healthcheck.sh
###############################################################################

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_BIN="/usr/local/bin/host-healthcheck.sh"
CONF_DIR="/etc/host-healthcheck"
CONF_FILE="${CONF_DIR}/host-healthcheck.conf"
STATE_DIR="/var/lib/host-healthcheck"
CRON_FILE="/etc/cron.d/host-healthcheck"

echo "==> Installing host-healthcheck"

# ── Install smartmontools if needed ──────────────────────────────────────────
if ! command -v smartctl &>/dev/null; then
  echo "    Installing smartmontools..."
  apt-get update -qq && apt-get install -y -qq smartmontools
fi

# ── Copy script ──────────────────────────────────────────────────────────────
cp "${SCRIPT_DIR}/host-healthcheck.sh" "$INSTALL_BIN"
chmod 755 "$INSTALL_BIN"
echo "    Script installed: $INSTALL_BIN"

# ── Copy config (preserve existing) ─────────────────────────────────────────
mkdir -p "$CONF_DIR"
if [[ -f "$CONF_FILE" ]]; then
  echo "    Config already exists (not overwritten): $CONF_FILE"
  echo "    New template saved as: ${CONF_FILE}.new"
  cp "${SCRIPT_DIR}/host-healthcheck.conf" "${CONF_FILE}.new"
else
  cp "${SCRIPT_DIR}/host-healthcheck.conf" "$CONF_FILE"
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
echo "  5. Monitor log:   tail -f /var/log/host-healthcheck.log"
