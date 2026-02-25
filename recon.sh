#!/bin/bash
# ==========================================
# ELITE RECON ENGINE v5 - CHAOS FULL ASM
# UPGRADED: THC.ORG WITH PAGINATION & RL
# ==========================================

set -euo pipefail
IFS=$'\n\t'

export CHAOS_KEY="${CHAOS_KEY:-}"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p db logs
touch db/subdomains.txt db/domain_health.txt db/endpoints.txt

ALERT_FILE="slack_alert.txt"
> "$ALERT_FILE"

if [ ! -f targets.txt ]; then
  echo "ERROR: targets.txt not found!" >&2
  exit 1
fi

echo "Recon Started: $(date -u)"

# ==========================================
# FUNCTION: THC.ORG ELITE SCRAPER
# ==========================================
fetch_thc_elite() {
  local TYPE=$1
  local TARGET=$2
  local URL="https://ip.thc.org/${TYPE}/${TARGET}?l=100"

  while [ -n "$URL" ]; do
    echo "[*] Fetching THC ${TYPE^^}: $URL"
    
    # Fetch response with retry logic
    RESPONSE=$(curl -sf --retry 2 --connect-timeout 10 --max-time 30 "$URL") || break

    # Extract subdomains
    echo "$RESPONSE" | grep -Eo "([a-zA-Z0-9._-]+\.)+${TARGET}" >> "$TMP_DIR/thc_all.txt" || true

    # Extract Next Page link
    NEXT=$(echo "$RESPONSE" | grep ";;Next Page:" | sed 's/;;Next Page:[[:space:]]*//' | xargs)

    # Extract Rate Limit and sleep accordingly
    RL=$(echo "$RESPONSE" | grep ";;Rate Limit:" | grep -Eo '[0-9]+' | head -n1 || echo "10")
    if [ -n "$RL" ] && [ "$RL" -lt 5 ]; then
      echo "[!] THC Rate Limit Low ($RL). Sleeping 7s..."
      sleep 7
    else
      sleep 1.5
    fi

    URL="$NEXT"
  done
}

# ==========================================
# 1. SUBDOMAIN ENUMERATION
# ==========================================

echo "[*] Running subfinder..."
subfinder -dL targets.txt -silent -all -o "$TMP_DIR/sf.txt" || true

echo "[*] Running chaos..."
if [ -n "$CHAOS_KEY" ]; then
  chaos -dL targets.txt -key "$CHAOS_KEY" -silent -o "$TMP_DIR/chaos.txt" || true
else
  touch "$TMP_DIR/chaos.txt"
fi

echo "[*] Querying crt.sh..."
> "$TMP_DIR/crt.txt"
while read -r domain; do
  [ -z "$domain" ] && continue
  curl -s --max-time 40 "https://crt.sh/?q=%25.${domain}&output=json" \
    | jq -r '.[].name_value' 2>/dev/null \
    | sed 's/\*\.//g' >> "$TMP_DIR/crt.txt" || true
done < targets.txt

echo "[*] Querying THC (Elite Mode)..."
> "$TMP_DIR/thc_all.txt"
while read -r domain; do
  [ -z "$domain" ] && continue
  fetch_thc_elite "sb" "$domain"
  fetch_thc_elite "cn" "$domain"
done < targets.txt

# Merge & normalize
cat "$TMP_DIR"/sf.txt \
    "$TMP_DIR"/chaos.txt \
    "$TMP_DIR"/crt.txt \
    "$TMP_DIR"/thc_all.txt 2>/dev/null \
  | tr '[:upper:]' '[:lower:]' \
  | sed 's/\.$//' \
  | grep -Eo '^([a-zA-Z0-9._-]+\.)+[a-zA-Z]{2,}$' \
  | sort -u > "$TMP_DIR/subs_raw.txt"

echo "Raw subdomains: $(wc -l < "$TMP_DIR/subs_raw.txt")"

# ==========================================
# 2. DNS RESOLUTION
# ==========================================

echo "[*] Resolving with dnsx..."
dnsx -l "$TMP_DIR/subs_raw.txt" -silent -o "$TMP_DIR/subs_resolved.txt" || true
touch "$TMP_DIR/subs_resolved.txt"

echo "Resolved: $(wc -l < "$TMP_DIR/subs_resolved.txt")"

# ==========================================
# 3. STATE MANAGEMENT
# ==========================================

echo "[*] Detecting new subdomains..."
# anew tracks everything in db/subdomains.txt and outputs ONLY the new ones
anew db/subdomains.txt < "$TMP_DIR/subs_resolved.txt" > "$TMP_DIR/new_subs.txt"

if [ -s "$TMP_DIR/new_subs.txt" ]; then
  NEW_COUNT=$(wc -l < "$TMP_DIR/new_subs.txt" | xargs)
  echo "🚀 *NEW SUBDOMAINS ($NEW_COUNT)*" >> "$ALERT_FILE"
  head -n 15 "$TMP_DIR/new_subs.txt" >> "$ALERT_FILE"
  echo "" >> "$ALERT_FILE"
fi

# ==========================================
# 4. HEALTH MONITORING
# ==========================================

echo "[*] Probing with httpx..."
# -fr follows redirects to get the real final status code
httpx -l "$TMP_DIR/subs_resolved.txt" -sc -fr -silent -no-color \
  > "$TMP_DIR/health.txt" 2>/dev/null || true

# Format as domain|status_code
awk '{print $1"|"$2}' "$TMP_DIR/health.txt" \
  | tr -d '[]' \
  | sort -u > "$TMP_DIR/current_health.txt"

# anew detects if a domain|status combination is new
anew db/domain_health.txt < "$TMP_DIR/current_health.txt" > "$TMP_DIR/health_changes.txt"

if [ -s "$TMP_DIR/health_changes.txt" ]; then
  HEALTH_COUNT=$(wc -l < "$TMP_DIR/health_changes.txt" | xargs)
  echo "🔄 *STATUS CHANGES ($HEALTH_COUNT)*" >> "$ALERT_FILE"
  head -n 15 "$TMP_DIR/health_changes.txt" >> "$ALERT_FILE"
  echo "" >> "$ALERT_FILE"
fi

# ==========================================
# 5. FINAL LOGGING
# ==========================================

if [ -s "$ALERT_FILE" ]; then
  cat "$ALERT_FILE"
else
  echo "No changes detected."
fi

echo "Recon Completed: $(date -u)"
