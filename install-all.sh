#!/usr/bin/env bash
###############################################################################
# install-all.sh
#
# Master installer for the hostcheck suite.
# Installs all four monitoring scripts: health, security, mail, and OAuth token.
# Idempotent — safe to re-run.
#
# Usage:
#   chmod +x install-all.sh
#   sudo ./install-all.sh
###############################################################################

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_COUNT=0
INSTALL_FAILED=0

echo "=========================================="
echo "  hostcheck Installation"
echo "=========================================="
echo ""

# Helper function to run installer
install_module() {
  local module_name="$1"
  local installer_path="$2"
  
  if [[ ! -f "$installer_path" ]]; then
    echo "❌ $module_name installer not found: $installer_path"
    INSTALL_FAILED=$(( INSTALL_FAILED + 1 ))
    return 1
  fi
  
  echo ""
  echo "→ Installing $module_name..."
  if bash "$installer_path"; then
    INSTALL_COUNT=$(( INSTALL_COUNT + 1 ))
    return 0
  else
    INSTALL_FAILED=$(( INSTALL_FAILED + 1 ))
    return 1
  fi
}

# Install each module
install_module "hostcheck-health" "${SCRIPT_DIR}/hostcheck-health/install-health.sh"
install_module "hostcheck-sec" "${SCRIPT_DIR}/hostcheck-sec/install-sec.sh"
install_module "hostcheck-mail" "${SCRIPT_DIR}/hostcheck-mail/install-mail.sh"
install_module "hostcheck-oauth-token" "${SCRIPT_DIR}/hostcheck-oauth-token/install-oauth-token.sh"

# Install general config template if it doesn't exist
echo ""
echo "→ Creating general configuration file..."
GENERAL_CONF="/etc/hostcheck/hostcheck.conf"
if [[ -f "$GENERAL_CONF" ]]; then
  echo "    General config already exists: $GENERAL_CONF"
else
  mkdir -p /etc/hostcheck
  cat > "$GENERAL_CONF" <<'EOF'
###############################################################################
# hostcheck.conf
#
# General configuration file for the hostcheck suite.
# Shared settings used by all monitoring scripts.
#
# Individual scripts will load their own config files (hostcheck-*.conf)
# which can override these settings.
###############################################################################

# ── Telegram notifications (shared) ──────────────────────────────────────────
# Set these once to use across all scripts. Individual configs can override.
# To set up:
#   1. Message @BotFather on Telegram → /newbot → get the bot token
#   2. Start a chat with the bot, send a message
#   3. GET https://api.telegram.org/bot<TOKEN>/getUpdates → find chat_id
TELEGRAM_ENABLED="false"
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

# ── Email notifications (shared) ─────────────────────────────────────────────
# Set these once to use across all scripts. Individual configs can override.
# Requires sendmail, msmtp, or mail command on the host.
EMAIL_ENABLED="false"
EMAIL_TO="admin@example.com"
EMAIL_FROM="hostcheck@$(hostname -f 2>/dev/null || hostname)"
EOF
  chmod 600 "$GENERAL_CONF"
  echo "    General config created: $GENERAL_CONF"
fi

# Summary
echo ""
echo "=========================================="
if [[ "$INSTALL_FAILED" -eq 0 ]]; then
  echo "  ✅ Installation Complete!"
  echo "  Installed: $INSTALL_COUNT modules"
  echo ""
  echo "Next steps:"
  echo "  1. Review general settings:     vi /etc/hostcheck/hostcheck.conf"
  echo "  2. Configure each tool:"
  echo "     - vi /etc/hostcheck/hostcheck-health.conf"
  echo "     - vi /etc/hostcheck/hostcheck-sec.conf"
  echo "     - vi /etc/hostcheck/hostcheck-mail.conf"
  echo "     - vi /etc/hostcheck/hostcheck-oauth-token.conf"
  echo "  3. Monitor logs:"
  echo "     - tail -f /var/log/hostcheck-*.log"
  echo ""
  echo "View individual README files for module-specific setup:"
  echo "  - hostcheck-health/README.md"
  echo "  - hostcheck-sec/README.md"
  echo "  - hostcheck-mail/README.md"
  echo "  - hostcheck-oauth-token/README.md"
else
  echo "  ⚠️  Installation completed with errors"
  echo "  Installed: $INSTALL_COUNT modules"
  echo "  Failed: $INSTALL_FAILED modules"
  echo ""
  echo "Review the output above for details."
fi
echo "=========================================="