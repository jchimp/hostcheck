#!/usr/bin/env bash
###############################################################################
# uninstall-all.sh
#
# Master uninstaller for the hostcheck suite.
# Removes all four monitoring scripts: health, security, mail, and OAuth token.
#
###############################################################################

echo "=========================================="
echo "  hostcheck Uninstall"
echo "=========================================="
echo ""

echo "→ Uninstalling hostcheck scripts, configs, and cron jobs..."

# Uninstall all hostcheck scripts, configs, and cron jobs.
sudo rm -f /usr/local/bin/hostcheck-*.sh
sudo rm -f /etc/cron.d/hostcheck-*
sudo rm -rf /var/lib/hostcheck-*
sudo rm -f /var/log/hostcheck-*.log
sudo rm -rf /etc/hostcheck

echo "Uninstallation complete. All hostcheck scripts, configs, and cron jobs have been removed."
