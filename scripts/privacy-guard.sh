#!/usr/bin/env bash
# Privacy guard for Aegis (ADR-0005). Blocks:
#   1. secrets and signing material
#   2. Apple-only framework imports inside Packages/AegisKit (must stay Linux-buildable)
#   3. real personal-data paths in code, unless the line carries "privacy-guard: allow-real-path"
#   4. database/mail files
#   5. network use in Swift and Prototype Python/JS, unless the line carries "privacy-guard: allow-network"
#
# Usage:
#   scripts/privacy-guard.sh            changed + untracked files (local default)
#   scripts/privacy-guard.sh --staged   staged files (pre-commit hook)
#   scripts/privacy-guard.sh --all      every tracked file
#   BASE_REF=main scripts/privacy-guard.sh   files changed vs origin/main (CI on PRs)
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

list_files() {
  if [[ -n "${BASE_REF:-}" ]]; then
    git diff --name-only --diff-filter=ACMR "origin/${BASE_REF}...HEAD"
  elif [[ "${1:-}" == "--staged" ]]; then
    git diff --cached --name-only --diff-filter=ACMR
  elif [[ "${1:-}" == "--all" ]] || ! git rev-parse --verify -q HEAD >/dev/null; then
    { git ls-files; git ls-files --others --exclude-standard; } | sort -u
  else
    { git diff --name-only --diff-filter=ACMR HEAD; git ls-files --others --exclude-standard; } | sort -u
  fi
}

fail=0
report() { echo "✖ $1"; fail=1; }

SELF="scripts/privacy-guard.sh"
SECRET_RE='-----BEGIN ([A-Z]+ )?PRIVATE KEY-----|sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[baprs]-[A-Za-z0-9-]{10,}'
APPLE_ONLY_RE='^[[:space:]]*(@_exported[[:space:]]+)?import[[:space:]]+(AppKit|Cocoa|SwiftUI|UIKit|EventKit|Contacts|HomeKit|Metal|MetalKit|CoreML|MLX[A-Za-z]*|WidgetKit|AVFoundation|Speech|NaturalLanguage|Vision|Combine|ServiceManagement|ApplicationServices|IOKit|FoundationModels)\b'
REAL_PATH_RE='Library/Messages|group\.com\.apple\.usernoted|group\.net\.whatsapp|AddressBook-v22|Library/Mail/V[0-9]|Library/Calendars|Photos Library\.photoslibrary'
NETWORK_RE='URLSession|URLRequest\(|NWConnection|https?://'
PY_MODULE_RE='(requests|urllib|http\.client|httpx|socket|aiohttp)(\.[[:alnum:]_]+)*'
PY_NETWORK_RE="(^|;)[[:space:]]*(from[[:space:]]+${PY_MODULE_RE}[[:space:]]+import|import[[:space:]]+([^#;]*,[[:space:]]*)?${PY_MODULE_RE}([[:space:],;#]|$)|from[[:space:]]+http[[:space:]]+import[[:space:]]+\(?[[:space:]]*([^#;]*,[[:space:]]*)?client([[:space:],;)#]|$))"
JS_NETWORK_RE="\\bfetch[[:space:]]*\\(|\\bXMLHttpRequest\\b|\\brequire[[:space:]]*\\([[:space:]]*['\"](http|https|net)['\"][[:space:]]*\\)|\\baxios\\b"

while IFS= read -r f; do
  [[ -z "$f" || ! -f "$f" || "$f" == "$SELF" ]] && continue

  case "$f" in
    *.db|*.sqlite|*.sqlite3|*.emlx|*-wal|*-shm)
      report "$f: database/mail file must never be committed" ; continue ;;
    *.p12|*.cer|*.mobileprovision|*.provisionprofile|*.pem|*.key|.env|*/.env)
      report "$f: signing/secret file must never be committed" ; continue ;;
  esac

  if grep -nEI -e "$SECRET_RE" "$f" >/dev/null 2>&1; then
    report "$f: looks like a secret or private key:"; grep -nEI -e "$SECRET_RE" "$f" | head -3 | sed 's/^/    /'
  fi

  case "$f" in
    Packages/AegisKit/Sources/*.swift)
      if grep -nE "$APPLE_ONLY_RE" "$f" >/dev/null; then
        report "$f: Apple-only import in AegisKit (must stay Linux-buildable, ADR-0004):"
        grep -nE "$APPLE_ONLY_RE" "$f" | sed 's/^/    /'
      fi ;;
  esac

  case "$f" in
    docs/*|*.md|Prototype/*|Fixtures/*|.claude/*|.github/*) ;;   # docs and the human-run prototype may name paths/URLs
    *.swift|*.py|*.js|*.ts|*.sh)
      hits=$(grep -nE "$REAL_PATH_RE" "$f" | grep -v 'privacy-guard: allow-real-path' || true)
      if [[ -n "$hits" ]]; then
        report "$f: references a real personal-data path (add 'privacy-guard: allow-real-path <reason>' on the line if this is a reviewed collector):"
        echo "$hits" | sed 's/^/    /'
      fi
      ;;
  esac

  # Network checks are separate so Prototype's real-path exemption stays intact.
  network_re=''
  case "$f" in
    Prototype/*.py) network_re="$PY_NETWORK_RE" ;;
    Prototype/*.js) network_re="$JS_NETWORK_RE" ;;
    docs/*|*.md|Fixtures/*|.claude/*|.github/*|*/Tests/*) ;;
    *.swift) network_re="$NETWORK_RE" ;;
  esac
  if [[ -n "$network_re" ]]; then
    hits=$(grep -nE "$network_re" "$f" | grep -v 'privacy-guard: allow-network' || true)
    if [[ -n "$hits" ]]; then
      report "$f: network use (needs an issue allowing it + 'privacy-guard: allow-network <reason>' on the line):"
      echo "$hits" | sed 's/^/    /'
    fi
  fi
done < <(list_files "${1:-}")

if [[ $fail -ne 0 ]]; then
  echo; echo "Privacy guard failed. See AGENTS.md › Development rules."; exit 1
fi
echo "✔ privacy guard passed"
