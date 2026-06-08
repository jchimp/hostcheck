#!/usr/bin/env bash
###############################################################################
# uninstall.sh
#
# Master uninstaller for the hostcheck suite.
# Removes all files from both the current and legacy path layouts.
# Safe to run on systems with either or both layouts installed.
#
# Usage: sudo ./uninstall.sh
###############################################################################

set -Euo pipefail

# ── Root check ────────────────────────────────────────────────────────────────
[[ "$EUID" -eq 0 ]] || { echo "ERROR: Run as root (sudo ./uninstall.sh)" >&2; exit 1; }

echo ""
echo "══════════════════════════════════════════════════════"
echo "  hostcheck — Uninstaller"
echo "══════════════════════════════════════════════════════"
echo ""

# ── Current paths ──────────────────────────────────────────────────────────────
# Note: /usr/local/bin/hostcheck is the dispatcher file; the module scripts
# live in /usr/local/bin/hostcheck/ (same name, as a directory). Both are
# handled below by scanning for both file and directory forms.
CURRENT_PATHS=(
  /etc/hostcheck
  /var/lib/hostcheck
  /var/log/hostcheck
  /etc/cron.d/hostcheck-health
  /etc/cron.d/hostcheck-sec
  /etc/cron.d/hostcheck-mail
  /etc/cron.d/hostcheck-oauth-token
)

# ── Legacy paths (old layout, pre-refactor) ───────────────────────────────────
LEGACY_PATHS=(
  /usr/local/bin/hostcheck-health.sh
  /usr/local/bin/hostcheck-sec.sh
  /usr/local/bin/hostcheck-mail.sh
  /usr/local/bin/hostcheck-oauth-token.sh
  /var/lib/hostcheck-health
  /var/lib/hostcheck-sec
  /var/lib/hostcheck-mail
  /var/lib/hostcheck-oauth-token
  /var/log/hostcheck-health.log
  /var/log/hostcheck-sec.log
  /var/log/hostcheck-mail.log
  /var/log/hostcheck-oauth-token.log
)

# ── Scan what's present ───────────────────────────────────────────────────────
ALL_FOUND=()

# Handle the /usr/local/bin/hostcheck path — could be file (dispatcher) or dir (scripts)
for p in /usr/local/bin/hostcheck /usr/local/bin/hostcheck/; do
  [[ -e "$p" ]] && ALL_FOUND+=("$p")
done

for p in "${CURRENT_PATHS[@]}" "${LEGACY_PATHS[@]}"; do
  [[ -e "$p" ]] && ALL_FOUND+=("$p")
done

# Deduplicate
mapfile -t ALL_FOUND < <(printf '%s\n' "${ALL_FOUND[@]}" | sort -u)

if [[ "${#ALL_FOUND[@]}" -eq 0 ]]; then
  echo "  Nothing to remove — no hostcheck files found."
  exit 0
fi

echo "  The following hostcheck files and directories will be removed:"
echo ""
for p in "${ALL_FOUND[@]}"; do
  echo "    $p"
done
echo ""
echo "  This includes scripts, configs, cron jobs, state files, and logs."
echo "  This action cannot be undone."
echo ""

read -r -p "  Proceed with uninstall? [y/N] " confirm
if [[ "${confirm,,}" != "y" ]]; then
  echo ""
  echo "  Uninstall cancelled."
  exit 0
fi

echo ""
echo "── Removing files ──────────────────────────────────────"
echo ""

for p in "${ALL_FOUND[@]}"; do
  if [[ -d "$p" ]]; then
    rm -rf "$p" && echo "  Removed dir:  $p"
  elif [[ -f "$p" ]]; then
    rm -f "$p"  && echo "  Removed file: $p"
  fi
done

echo ""
echo "══════════════════════════════════════════════════════"
echo "  Uninstall complete."
echo "══════════════════════════════════════════════════════"
echo ""
