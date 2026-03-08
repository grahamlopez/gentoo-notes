#!/bin/bash
# sysperms.sh - check and fix file ownership/permissions for system configs
# Keep this in your sysfiles bare repo. Edit the list below.
# Optionally add 'sysperms.sh --fix' to '.git/hooks/post-checkout'
# Usage: sysperms [--check | --fix]

set -euo pipefail

# FORMAT: "path:owner:group:mode"
FILES=(
    "/etc/shadow:root:root:0640"
    "/etc/shadow-:root:root:0600"
    "/etc/gshadow:root:root:0640"
    "/etc/gshadow-:root:root:0600"
    "/etc/ssh/sshd_config:root:root:0600"
    "/etc/sudoers:root:root:0440"
    "/etc/fstab:root:root:0644"
    "/etc/portage/make.conf:root:root:0644"
    "/etc/hostname:root:root:0644"
    # Add more entries as needed
)

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

MODE="${1:---check}"
ERRORS=0

for entry in "${FILES[@]}"; do
    IFS=':' read -r path owner group mode <<< "$entry"

    if [[ ! -e "$path" ]]; then
        printf "${RED}MISSING${NC}  %s\n" "$path"
        ((ERRORS++))
        continue
    fi

    cur_owner=$(stat -c '%U' "$path")
    cur_group=$(stat -c '%G' "$path")
    cur_mode=$(stat -c '%04a' "$path")

    ok=true
    detail=""

    if [[ "$cur_owner" != "$owner" ]]; then
        ok=false
        detail+=" owner=${cur_owner}→${owner}"
    fi
    if [[ "$cur_group" != "$group" ]]; then
        ok=false
        detail+=" group=${cur_group}→${group}"
    fi
    if [[ "$cur_mode" != "$mode" ]]; then
        ok=false
        detail+=" mode=${cur_mode}→${mode}"
    fi

    if $ok; then
        printf "${GREEN}OK${NC}       %s\n" "$path"
    else
        printf "${RED}MISMATCH${NC} %s%s\n" "$path" "$detail"
        ((ERRORS++))

        if [[ "$MODE" == "--fix" ]]; then
            chown "${owner}:${group}" "$path"
            chmod "$mode" "$path"
            printf "         ${GREEN}FIXED${NC}\n"
        fi
    fi
done

if [[ $ERRORS -gt 0 && "$MODE" == "--check" ]]; then
    printf "\n%d issue(s) found. Run with --fix to correct.\n" "$ERRORS"
    exit 1
elif [[ $ERRORS -eq 0 ]]; then
    printf "\nAll files OK.\n"
fi
