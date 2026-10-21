#!/usr/bin/env bash
# Writes Config/Signing.local.xcconfig with the team of this Mac's Apple Development certificate
# (ADR-0013). The file is gitignored: the team ID stays on this Mac.
set -euo pipefail
cd "$(dirname "$0")/.."
team=$(security find-certificate -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
    | awk -F' = ' '/organizationalUnitName/ {print $2; exit}')
if [ -z "$team" ]; then
    echo "No Apple Development certificate: Xcode › Settings › Accounts › Manage Certificates › + › Apple Development." >&2
    exit 1
fi
printf '// Written by scripts/signing-config.sh. Not committed.\nDEVELOPMENT_TEAM = %s\nCODE_SIGN_STYLE = Automatic\n' "$team" \
    > Config/Signing.local.xcconfig
echo "Wrote Config/Signing.local.xcconfig"
