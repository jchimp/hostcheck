#!/usr/bin/env bash
###############################################################################
# install-oauth-token.sh
#
# Installs the oauth-token-monitor script, config, and cron job.
# Idempotent — safe to re-run.
#
# Usage:
#   chmod +x install-oauth-token.sh
#   sudo ./install-oauth-token.sh
###############################################################################

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_BIN="/usr/local/bin/hostcheck-oauth-token.sh"
CONF_DIR="/etc/hostcheck"
CONF_FILE="${CONF_DIR}/hostcheck-oauth-token.conf"
STATE_DIR="/var/lib/hostcheck-oauth-token"
CRON_FILE="/etc/cron.d/hostcheck-oauth-token"

echo "==> Installing hostcheck-oauth-token"

# ── Copy script ──────────────────────────────────────────────────────────────
cp "${SCRIPT_DIR}/hostcheck-oauth-token.sh" "$INSTALL_BIN"
chmod 755 "$INSTALL_BIN"
echo "    Script installed: $INSTALL_BIN"

# ── Copy config (preserve existing) ─────────────────────────────────────────
mkdir -p "$CONF_DIR"
if [[ -f "$CONF_FILE" ]]; then
  echo "    Config already exists (not overwritten): $CONF_FILE"
  echo "    New template saved as: ${CONF_FILE}.new"
  cp "${SCRIPT_DIR}/hostcheck-oauth-token.conf" "${CONF_FILE}.new"
else
  cp "${SCRIPT_DIR}/hostcheck-oauth-token.conf" "$CONF_FILE"
  chmod 600 "$CONF_FILE"
  echo "    Config installed: $CONF_FILE"
fi

# ── Create state directory ───────────────────────────────────────────────────
mkdir -p "$STATE_DIR"
echo "    State directory: $STATE_DIR"

# ── Install cron job ─────────────────────────────────────────────────────────
cat > "$CRON_FILE" <<EOF
# OAuth token monitor — every 30 minutes
*/30 * * * * root ${INSTALL_BIN} >> /dev/null 2>&1
EOF

chmod 644 "$CRON_FILE"
echo "    Cron job installed: $CRON_FILE (every 30 min)"

# ── Run once ─────────────────────────────────────────────────────────────────
echo "    Running token check once (dry-run)..."
"$INSTALL_BIN" --dry-run || echo "    WARN: dry-run returned non-zero"

echo ""
echo "==> Installation complete"
echo ""
echo "Next steps:"
echo "  1. Edit config:     vi $CONF_FILE"
echo "  2. Set TOKEN_FILES: TOKEN_FILES=\"/path/to/token/file.json\""
echo "  3. Set Telegram:    TELEGRAM_ENABLED, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID"
echo "  4. (Optional) Set TENANT_ID for refresh test"
echo "  5. Test:            $INSTALL_BIN --dry-run"
echo "  6. Monitor log:     tail -f /var/log/hostcheck-oauth-token.log"
echo ""
echo "To find your token file path:"
echo "  grep -oE '/[^ ]+' /etc/postfix/sasl_passwd"
echo "  ls /var/spool/postfix/sasl2/tokens/"
