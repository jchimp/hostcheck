#!/usr/bin/env bash
###############################################################################
# install-seccheck.sh
#
# Installs the host-seccheck script, config, and cron job.
# Idempotent — safe to re-run.
#
# Usage:
#   chmod +x install-seccheck.sh
#   sudo ./install-seccheck.sh
###############################################################################

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_BIN="/usr/local/bin/host-seccheck.sh"
CONF_DIR="/etc/host-seccheck"
CONF_FILE="${CONF_DIR}/host-seccheck.conf"
STATE_DIR="/var/lib/host-seccheck"
CRON_FILE="/etc/cron.d/host-seccheck"

echo "==> Installing host-seccheck"

# ── Copy script ──────────────────────────────────────────────────────────────
cp "${SCRIPT_DIR}/host-seccheck.sh" "$INSTALL_BIN"
chmod 755 "$INSTALL_BIN"
echo "    Script installed: $INSTALL_BIN"

# ── Copy config (preserve existing) ─────────────────────────────────────────
mkdir -p "$CONF_DIR"
if [[ -f "$CONF_FILE" ]]; then
  echo "    Config already exists (not overwritten): $CONF_FILE"
  echo "    New template saved as: ${CONF_FILE}.new"
  cp "${SCRIPT_DIR}/host-seccheck.conf" "${CONF_FILE}.new"
else
  cp "${SCRIPT_DIR}/host-seccheck.conf" "$CONF_FILE"
  chmod 600 "$CONF_FILE"
  echo "    Config installed: $CONF_FILE"
fi

# ── Create state directory ───────────────────────────────────────────────────
mkdir -p "$STATE_DIR"
echo "    State directory: $STATE_DIR"

# ── Install cron job ─────────────────────────────────────────────────────────
cat > "$CRON_FILE" <<EOF
# Host security check — every 15 minutes
*/15 * * * * root ${INSTALL_BIN} >> /dev/null 2>&1
EOF

chmod 644 "$CRON_FILE"
echo "    Cron job installed: $CRON_FILE (every 15 min)"

# ── Run once ─────────────────────────────────────────────────────────────────
echo "    Running security check once (dry-run)..."
"$INSTALL_BIN" --dry-run || echo "    WARN: dry-run returned non-zero"

# ── Set initial baselines ────────────────────────────────────────────────────
echo "    Setting initial baselines..."
"$INSTALL_BIN" --reset-baseline || echo "    WARN: baseline reset returned non-zero"

echo ""
echo "==> Installation complete"
echo ""
echo "Next steps:"
echo "  1. Edit config:   vi $CONF_FILE"
echo "  2. Set Telegram:  TELEGRAM_ENABLED, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID"
echo "  3. Set email:     EMAIL_ENABLED, EMAIL_TO"
echo "  4. Test:          $INSTALL_BIN --dry-run"
echo "  5. Monitor log:   tail -f /var/log/host-seccheck.log"
echo "  6. Reset baselines after expected changes: $INSTALL_BIN --reset-baseline"
