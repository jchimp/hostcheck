## Overview
We are working in this local project called 'hostcheck' which has 4 sub-folders of inidivial tools, that we need to make into a single repo.

We are changing the naming convention of all the scripts from host-healthcheck to hostcheck-health, and host-seccheck to hostcheck-sec, and so forth. We need to update the name of all paths, config files, comments and code to reflect this change. I will have an outline of most, but not all the exact file name, paths and locations. I think you can figure it out from what i have.
All of these scripts were individial host health checking scripts, but i want to turn it into a cohesive repo that i can copy onto a host, install, config and have these checks running every X minutes with cron sending me alerts. 

We will also be combing some of the settings in the .conf files from each tool into a general .conf file. Each tool will still have the bulk of their config in their respective file, but things like telegram bot and email settings can be in the general conf file.

## New Install locations for Each Script:

### Health check:
INSTALL_BIN="/usr/local/bin/hostcheck-health.sh"
CONF_DIR="/etc/hostcheck"
CONF_FILE="${CONF_DIR}/hostcheck-health.conf"
STATE_DIR="/var/lib/hostcheck-health"
CRON_FILE="/etc/cron.d/hostcheck-health"

### Security check:
INSTALL_BIN="/usr/local/bin/hostcheck-sec.sh"
CONF_DIR="/etc/hostcheck"
CONF_FILE="${CONF_DIR}/hostcheck-sec.conf"
STATE_DIR="/var/lib/hostcheck-sec"
CRON_FILE="/etc/cron.d/hostcheck-sec"

### Mail (Postfix) check:
INSTALL_BIN="/usr/local/bin/hostcheck-mail.sh"
CONF_DIR="/etc/hostcheck"
CONF_FILE="${CONF_DIR}/hostcheck-mail.conf"
STATE_DIR="/var/lib/hostcheck-mail"
CRON_FILE="/etc/cron.d/hostcheck-mail"

### OAuth Token Monitor:
INSTALL_BIN="/usr/local/bin/hostcheck-oauth-token.sh"
CONF_DIR="/etc/hostcheck"
CONF_FILE="${CONF_DIR}/hostcheck-oauth-token.conf"
STATE_DIR="/var/lib/hostcheck-oauth-token"
CRON_FILE="/etc/cron.d/hostcheck-oauth-token"

## Installation Scripts
We will need install scripts in the root of the project. One to install all the tools, and then one for each tool if you want to install one by one or only 2 of 4, for example.
- install-all.sh
- install-health.sh
- install-sec.sh
- install-mail.sh

## Config files:
The new 'General Configuration' file mentioned below will have the following common settings that are in each of the seperate tools .conf file:
```
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
EMAIL_TO="admin@example.com"
EMAIL_FROM="mailcheck@$(hostname -f 2>/dev/null || hostname)"
```

Config file paths:
/etc/hostcheck/hostcheck.conf               # General configuration, alerts, logging
/etc/hostcheck/hostcheck-health.conf        # Health script configuration
/etc/hostcheck/hostcheck-sec.conf           # Security script configuration
/etc/hostcheck/hostcheck-mail.conf          # Mail (Postfix) script configuration
/etc/hostcheck/hostcheck-oauthtoken.conf    # OAuth2 Token monitor script configuration

## Readme files
I would like to keep each original README in each sub-folder of each script.
I will need a new README for the project that explains the install and overall function of each script. 
It can be more of an overview with installation instructions and reference the sub-READMEs for details.
