#!/usr/bin/env bash
###############################################################################
# install.sh
#
# Interactive installer for the hostcheck suite.
# Installs all module scripts and the master dispatcher.
# Prompts which modules to enable (creates cron jobs via hostcheck enable).
# Detects and removes old-path artifacts from previous installs.
#
# Usage: sudo ./install.sh
###############################################################################

set -Euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

INSTALL_BIN_DIR="/usr/local/bin"
DISPATCHER="/usr/local/bin/hostcheck"
CONF_DIR="/etc/hostcheck"
CONF_FILE="${CONF_DIR}/hostcheck.conf"
LOG_DIR="/var/log/hostcheck"
STATE_BASE="/var/lib/hostcheck"

MODULES=(health sec mail oauth-token)

# ── Old paths to clean up ──────────────────────────────────────────────────────
OLD_SCRIPTS=(
  /usr/local/bin/hostcheck/hostcheck-health.sh
  /usr/local/bin/hostcheck/hostcheck-sec.sh
  /usr/local/bin/hostcheck/hostcheck-mail.sh
  /usr/local/bin/hostcheck/hostcheck-oauth-token.sh
)
OLD_STATE_DIRS=(
  /var/lib/hostcheck-health
  /var/lib/hostcheck-sec
  /var/lib/hostcheck-mail
  /var/lib/hostcheck-oauth-token
)
OLD_LOGS=(
  /var/log/hostcheck-health.log
  /var/log/hostcheck-sec.log
  /var/log/hostcheck-mail.log
  /var/log/hostcheck-oauth-token.log
)
OLD_CONFS=(
  /etc/hostcheck/hostcheck-health.conf
  /etc/hostcheck/hostcheck-sec.conf
  /etc/hostcheck/hostcheck-mail.conf
  /etc/hostcheck/hostcheck-oauth-token.conf
)

# ── Helpers ───────────────────────────────────────────────────────────────────
die() { echo "ERROR: $*" >&2; exit 1; }

confirm() {
  local prompt="$1"
  local default="${2:-n}"
  local yn
  if [[ "$default" == "y" ]]; then
    read -r -p "${prompt} [Y/n] " yn
    [[ -z "$yn" || "${yn,,}" == "y" ]]
  else
    read -r -p "${prompt} [y/N] " yn
    [[ "${yn,,}" == "y" ]]
  fi
}

print_header() {
  echo ""
  echo "══════════════════════════════════════════════════════"
  echo "  hostcheck — Installer"
  echo "══════════════════════════════════════════════════════"
  echo ""
}

# ── Root check ────────────────────────────────────────────────────────────────
[[ "$EUID" -eq 0 ]] || die "This script must be run as root (sudo ./install.sh)"

print_header

# ── Step 1: Detect old-path artifacts ─────────────────────────────────────────
echo "── Checking for old installation artifacts ────────────"
echo ""

OLD_FOUND=()
for f in "${OLD_SCRIPTS[@]}" "${OLD_STATE_DIRS[@]}" "${OLD_LOGS[@]}" "${OLD_CONFS[@]}"; do
  [[ -e "$f" ]] && OLD_FOUND+=("$f")
done

if [[ "${#OLD_FOUND[@]}" -gt 0 ]]; then
  echo "  Found artifacts from a previous install:"
  for f in "${OLD_FOUND[@]}"; do
    echo "    $f"
  done
  echo ""
  echo "  These use the old path layout and should be removed."
  echo "  You will need to reconfigure /etc/hostcheck/hostcheck.conf after install."
  echo ""
  if confirm "  Remove all old artifacts now?"; then
    for f in "${OLD_FOUND[@]}"; do
      if [[ -d "$f" ]]; then
        rm -rf "$f" && echo "    Removed dir:  $f"
      else
        rm -f "$f"  && echo "    Removed file: $f"
      fi
    done
    echo ""
    echo "  Old artifacts removed."
  else
    echo ""
    echo "  Skipping cleanup. Old artifacts left in place."
    echo "  NOTE: old and new scripts may conflict — clean up manually if issues arise."
  fi
  echo ""
fi

# ── Step 2: Module selection ───────────────────────────────────────────────────
echo "── Select modules to enable ───────────────────────────"
echo ""
echo "  All module scripts will be installed. Select which to activate (create cron jobs)."
echo ""
echo "  Modules:"
echo "    1) health      — System & cluster health (NIC, disk, SMART, CPU, memory, Ceph)"
echo "    2) sec         — Security & drift detection (SSH failures, users, certs, ports)"
echo "    3) mail        — Postfix relay health (queue, SASL, TLS, bounces)"
echo "    4) oauth-token — OAuth2 token expiry monitor (sasl-xoauth2)"
echo ""
echo "  Enter module numbers to enable (space-separated), or 'all' for all four."
echo "  Example: 1 2    or    all"
echo ""
read -r -p "  Selection: " selection

declare -A ENABLE_MODULE
for m in "${MODULES[@]}"; do
  ENABLE_MODULE[$m]=0
done

if [[ "${selection,,}" == "all" ]]; then
  for m in "${MODULES[@]}"; do
    ENABLE_MODULE[$m]=1
  done
else
  for token in $selection; do
    case "$token" in
      1) ENABLE_MODULE[health]=1 ;;
      2) ENABLE_MODULE[sec]=1 ;;
      3) ENABLE_MODULE[mail]=1 ;;
      4) ENABLE_MODULE[oauth-token]=1 ;;
      *) echo "  WARNING: Unknown selection '${token}' — ignoring" ;;
    esac
  done
fi

SELECTED=()
for m in "${MODULES[@]}"; do
  [[ "${ENABLE_MODULE[$m]}" -eq 1 ]] && SELECTED+=("$m")
done

echo ""
if [[ "${#SELECTED[@]}" -gt 0 ]]; then
  echo "  Will enable: ${SELECTED[*]}"
else
  echo "  No modules selected for activation (scripts will still be installed)."
fi
echo ""

# ── Step 3: Optional dependency check ─────────────────────────────────────────
if [[ "${ENABLE_MODULE[health]}" -eq 1 ]]; then
  echo "── Health module dependencies ─────────────────────────"
  for cmd in smartctl corosync-quorumtool pvecm; do
    if command -v "$cmd" &>/dev/null; then
      echo "  ✓ ${cmd}"
    else
      echo "  ⚠ ${cmd} not found — related checks will be skipped at runtime"
    fi
  done
  echo ""
fi

if [[ "${ENABLE_MODULE[mail]}" -eq 1 ]] || [[ "${ENABLE_MODULE[oauth-token]}" -eq 1 ]]; then
  echo "── Mail/OAuth module dependencies ─────────────────────"
  for cmd in postfix nc python3 curl; do
    if command -v "$cmd" &>/dev/null; then
      echo "  ✓ ${cmd}"
    else
      echo "  ⚠ ${cmd} not found — may affect runtime checks"
    fi
  done
  echo ""
fi

# ── Step 4: Install shared infrastructure ────────────────────────────────────
echo "── Installing shared infrastructure ───────────────────"
echo ""

# Remove old hostcheck subdirectory if it exists as a directory (layout change)
if [[ -d "/usr/local/bin/hostcheck" ]]; then
  rm -rf "/usr/local/bin/hostcheck"
  echo "  Removed old subdir: /usr/local/bin/hostcheck/"
fi

# Log directory
mkdir -p "$LOG_DIR"
echo "  Created: ${LOG_DIR}/"

# State base directory
mkdir -p "$STATE_BASE"

# Config directory
mkdir -p "$CONF_DIR"

# Master config (preserve existing)
if [[ -f "$CONF_FILE" ]]; then
  echo "  Config already exists (not overwritten): ${CONF_FILE}"
  cp "${SCRIPT_DIR}/hostcheck.conf" "${CONF_FILE}.new"
  echo "  New template saved as: ${CONF_FILE}.new"
else
  cp "${SCRIPT_DIR}/hostcheck.conf" "$CONF_FILE"
  chmod 600 "$CONF_FILE"
  echo "  Config installed: ${CONF_FILE}"
fi

# Dispatcher
cp "${SCRIPT_DIR}/hostcheck" "$DISPATCHER"
chmod 755 "$DISPATCHER"
echo "  Dispatcher installed: ${DISPATCHER}"

echo ""

# ── Step 5: Install all module scripts ───────────────────────────────────────
echo "── Installing module scripts ───────────────────────────"
echo ""

for module in "${MODULES[@]}"; do
  src_script="${SCRIPT_DIR}/hostcheck-${module}/hostcheck-${module}.sh"
  dst_script="${INSTALL_BIN_DIR}/hostcheck-${module}.sh"
  state_dir="${STATE_BASE}/${module}"

  if [[ ! -f "$src_script" ]]; then
    echo "  [${module}]  ERROR: source not found: ${src_script} — skipping"
    echo ""
    continue
  fi

  cp "$src_script" "$dst_script"
  chmod 755 "$dst_script"
  mkdir -p "$state_dir"
  echo "  [${module}]  ${dst_script}"
done

echo ""

# ── Step 6: Enable selected modules ──────────────────────────────────────────
if [[ "${#SELECTED[@]}" -gt 0 ]]; then
  echo "── Enabling selected modules ───────────────────────────"
  echo ""
  for module in "${SELECTED[@]}"; do
    "$DISPATCHER" enable "$module"
  done
  echo ""
fi

# ── Step 7: Summary ───────────────────────────────────────────────────────────
echo "══════════════════════════════════════════════════════"
echo "  Installation complete"
echo "══════════════════════════════════════════════════════"
echo ""
echo "  Next steps:"
echo ""
echo "  1. Edit config:"
echo "       sudo vi ${CONF_FILE}"
echo ""
echo "  2. Set Telegram (recommended):"
echo "       TELEGRAM_ENABLED=\"true\""
echo "       TELEGRAM_BOT_TOKEN=\"<your-token>\""
echo "       TELEGRAM_CHAT_ID=\"<your-chat-id>\""
echo ""
if [[ "${#SELECTED[@]}" -gt 0 ]]; then
  echo "  3. Test enabled modules:"
  for module in "${SELECTED[@]}"; do
    echo "       hostcheck ${module} --dry-run"
  done
  echo ""
fi
echo "  4. Enable/disable modules at any time:"
echo "       sudo hostcheck enable <module|all>"
echo "       sudo hostcheck disable <module|all>"
echo ""
echo "  5. View logs:"
echo "       hostcheck log"
echo ""
echo "  6. Check status:"
echo "       hostcheck status"
echo ""
