#!/usr/bin/env bash
###############################################################################
# install.sh
#
# Interactive installer for the hostcheck suite.
# Installs selected modules, the master dispatcher, and cron jobs.
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
declare -A MODULE_CRON_SCHEDULE=(
  [health]="*/5 * * * *"
  [sec]="*/15 * * * *"
  [mail]="*/5 * * * *"
  [oauth-token]="*/30 * * * *"
)

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
echo "── Select modules to install ──────────────────────────"
echo ""
echo "  Modules:"
echo "    1) health      — System & cluster health (NIC, disk, SMART, CPU, memory, Ceph)"
echo "    2) sec         — Security & drift detection (SSH failures, users, certs, ports)"
echo "    3) mail        — Postfix relay health (queue, SASL, TLS, bounces)"
echo "    4) oauth-token — OAuth2 token expiry monitor (M365 / sasl-xoauth2)"
echo ""
echo "  Enter module numbers to install (space-separated), or 'all' for all four."
echo "  Example: 1 2    or    all"
echo ""
read -r -p "  Selection: " selection

declare -A INSTALL_MODULE
for m in "${MODULES[@]}"; do
  INSTALL_MODULE[$m]=0
done

if [[ "${selection,,}" == "all" ]]; then
  for m in "${MODULES[@]}"; do
    INSTALL_MODULE[$m]=1
  done
else
  for token in $selection; do
    case "$token" in
      1) INSTALL_MODULE[health]=1 ;;
      2) INSTALL_MODULE[sec]=1 ;;
      3) INSTALL_MODULE[mail]=1 ;;
      4) INSTALL_MODULE[oauth-token]=1 ;;
      *) echo "  WARNING: Unknown selection '${token}' — ignoring" ;;
    esac
  done
fi

SELECTED=()
for m in "${MODULES[@]}"; do
  [[ "${INSTALL_MODULE[$m]}" -eq 1 ]] && SELECTED+=("$m")
done

if [[ "${#SELECTED[@]}" -eq 0 ]]; then
  echo ""
  echo "  No modules selected. Exiting."
  exit 0
fi

echo ""
echo "  Will install: ${SELECTED[*]}"
echo ""

# ── Step 3: Optional dependency check ─────────────────────────────────────────
if [[ "${INSTALL_MODULE[health]}" -eq 1 ]]; then
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

if [[ "${INSTALL_MODULE[mail]}" -eq 1 ]] || [[ "${INSTALL_MODULE[oauth-token]}" -eq 1 ]]; then
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

# ── Step 5: Install selected modules ─────────────────────────────────────────
echo "── Installing modules ──────────────────────────────────"
echo ""

for module in "${SELECTED[@]}"; do
  src_script="${SCRIPT_DIR}/hostcheck-${module}/hostcheck-${module}.sh"
  dst_script="${INSTALL_BIN_DIR}/hostcheck-${module}.sh"
  state_dir="${STATE_BASE}/${module}"
  cron_file="/etc/cron.d/hostcheck-${module}"
  log_file="${LOG_DIR}/hostcheck-${module}.log"
  schedule="${MODULE_CRON_SCHEDULE[$module]}"

  echo "  [${module}]"

  if [[ ! -f "$src_script" ]]; then
    echo "    ERROR: Source script not found: ${src_script}"
    echo "    Skipping ${module}."
    echo ""
    continue
  fi

  # Script
  cp "$src_script" "$dst_script"
  chmod 755 "$dst_script"
  echo "    Script:    ${dst_script}"

  # State dir
  mkdir -p "$state_dir"
  echo "    State dir: ${state_dir}/"

  # Log file (touch to create)
  touch "$log_file"
  echo "    Log:       ${log_file}"

  # Cron job
  cat > "$cron_file" <<EOF
# hostcheck-${module} — installed by install.sh
${schedule} root ${dst_script} >> /dev/null 2>&1
EOF
  chmod 644 "$cron_file"
  echo "    Cron:      ${cron_file}  (${schedule})"

  echo ""
done

# ── Step 6: Update MODULE_*_ENABLED flags in config ──────────────────────────
echo "── Updating module flags in config ────────────────────"
echo ""

for module in "${MODULES[@]}"; do
  flag_name="MODULE_${module//-/_}_ENABLED"
  flag_name="${flag_name^^}"
  if [[ "${INSTALL_MODULE[$module]}" -eq 1 ]]; then
    value="true"
  else
    value="false"
  fi
  # Only update if the flag exists in the config
  if grep -q "^${flag_name}=" "$CONF_FILE"; then
    sed -i "s|^${flag_name}=.*|${flag_name}=\"${value}\"|" "$CONF_FILE"
    echo "  ${flag_name}=\"${value}\""
  fi
done

echo ""

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
echo "  3. Test installed modules:"
for module in "${SELECTED[@]}"; do
  echo "       hostcheck ${module} --dry-run"
done
echo ""
echo "  4. View logs:"
echo "       hostcheck log"
echo ""
echo "  5. Check cron schedule:"
echo "       hostcheck cron"
echo ""
