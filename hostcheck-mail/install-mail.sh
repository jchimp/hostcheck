#!/usr/bin/env bash
###############################################################################
# install-mail.sh
#
# Installs the host-mailcheck script, config, and cron job.
# Idempotent — safe to re-run.
#
# Usage:
#   chmod +x install-mail.sh
#   sudo ./install-mail.sh
###############################################################################

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_BIN="/usr/local/bin/hostcheck-mail.sh"
CONF_DIR="/etc/hostcheck"
CONF_FILE="${CONF_DIR}/hostcheck-mail.conf"
STATE_DIR="/var/lib/hostcheck-mail"
CRON_FILE="/etc/cron.d/hostcheck-mail"

echo "==> Installing hostcheck-mail"

# ── Copy script ──────────────────────────────────────────────────────────────
cp "${SCRIPT_DIR}/hostcheck-mail.sh" "$INSTALL_BIN"
chmod 755 "$INSTALL_BIN"
echo "    Script installed: $INSTALL_BIN"

# ── Copy config (preserve existing) ─────────────────────────────────────────
mkdir -p "$CONF_DIR"
if [[ -f "$CONF_FILE" ]]; then
  echo "    Config already exists (not overwritten): $CONF_FILE"
  echo "    New template saved as: ${CONF_FILE}.new"
  cp "${SCRIPT_DIR}/hostcheck-mail.conf" "${CONF_FILE}.new"
else
  cp "${SCRIPT_DIR}/hostcheck-mail.conf" "$CONF_FILE"
  chmod 600 "$CONF_FILE"
  echo "    Config installed: $CONF_FILE"
fi

# ── Create state directory ───────────────────────────────────────────────────
mkdir -p "$STATE_DIR"
echo "    State directory: $STATE_DIR"

# ── Install cron job ─────────────────────────────────────────────────────────
cat > "$CRON_FILE" <<EOF
# Host mail check — every 5 minutes
*/5 * * * * root ${INSTALL_BIN} >> /dev/null 2>&1
EOF

chmod 644 "$CRON_FILE"
echo "    Cron job installed: $CRON_FILE (every 5 min)"

# ── Run once ─────────────────────────────────────────────────────────────────
echo "    Running mail check once (dry-run)..."
"$INSTALL_BIN" --dry-run || echo "    WARN: dry-run returned non-zero"

# ── Set initial baselines ────────────────────────────────────────────────────
echo "    Setting initial baselines..."
"$INSTALL_BIN" --reset-baseline || echo "    WARN: baseline reset returned non-zero"

echo ""
echo "==> Installation complete"
echo ""
echo "Next steps:"
echo "  1. Edit config:     vi $CONF_FILE"
echo "  2. Set RELAY_HOSTS: RELAY_HOSTS=\"smtp.gmail.com:587 smtp.office365.com:587\""
echo "  3. Set Telegram:    TELEGRAM_ENABLED, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID"
echo "  4. Set email:       EMAIL_ENABLED, EMAIL_TO"
echo "  5. Test:            $INSTALL_BIN --dry-run"
echo "  6. Monitor log:     tail -f /var/log/hostcheck-mail.log"
