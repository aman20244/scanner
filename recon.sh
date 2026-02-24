#!/bin/bash
# ==========================================
# ELITE RECON ENGINE v5 - CHAOS FULL ASM
# JS SCANNING REMOVED
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

# ==========================================
# GUARD: targets.txt must exist
# ==========================================
if [ ! -f targets.txt ]; then
  echo "ERROR: targets.txt not found!" >&2
  exit 1
fi

echo "Recon Started: $(date -u)"

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

echo "[*] Querying THC..."
> "$TMP_DIR/thc_sb.txt"
> "$TMP_DIR/thc_cn.txt"
while read -r domain; do
  [ -z "$domain" ] && continue
  curl -s --max-time 30 "https://ip.thc.org/sb/${domain}" \
    | grep -Eo "([a-zA-Z0-9._-]+\.)+${domain}" >> "$TMP_DIR/thc_sb.txt" || true
  curl -s --max-time 30 "https://ip.thc.org/cn/${domain}" \
    | grep -Eo "([a-zA-Z0-9._-]+\.)+${domain}" >> "$TMP_DIR/thc_cn.txt" || true
done < targets.txt

# Merge & normalize
cat "$TMP_DIR"/sf.txt \
    "$TMP_DIR"/chaos.txt \
    "$TMP_DIR"/crt.txt \
    "$TMP_DIR"/thc_sb.txt \
    "$TMP_DIR"/thc_cn.txt 2>/dev/null \
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
anew db/subdomains.txt < "$TMP_DIR/subs_resolved.txt" > "$TMP_DIR/new_subs.txt"

if [ -s "$TMP_DIR/new_subs.txt" ]; then
  NEW_COUNT=$(wc -l < "$TMP_DIR/new_subs.txt" | xargs)
  echo "🚀 *NEW SUBDOMAINS ($NEW_COUNT)*" >> "$ALERT_FILE"
  head -n 15 "$TMP_DIR/new_subs.txt" >> "$ALERT_FILE"
  echo "" >> "$ALERT_FILE"
fi

echo "Total tracked: $(wc -l < db/subdomains.txt)"

# ==========================================
# 4. HEALTH MONITORING
# ==========================================

echo "[*] Probing with httpx..."
httpx -l "$TMP_DIR/subs_resolved.txt" -sc -silent -no-color \
  > "$TMP_DIR/health.txt" 2>/dev/null || true

awk '{print $1"|"$2}' "$TMP_DIR/health.txt" \
  | tr -d '[]' \
  | sort -u > "$TMP_DIR/current_health.txt"

anew db/domain_health.txt < "$TMP_DIR/current_health.txt" > "$TMP_DIR/health_changes.txt"

if [ -s "$TMP_DIR/health_changes.txt" ]; then
  HEALTH_COUNT=$(wc -l < "$TMP_DIR/health_changes.txt" | xargs)
  echo "🔄 *STATUS CHANGES ($HEALTH_COUNT)*" >> "$ALERT_FILE"
  head -n 15 "$TMP_DIR/health_changes.txt" >> "$ALERT_FILE"
  echo "" >> "$ALERT_FILE"
fi

# ==========================================
# 5. ALERT STATUS
# ==========================================

if [ -s "$ALERT_FILE" ]; then
  echo "Alert generated."
else
  echo "No changes detected."
fi

echo "Recon Completed: $(date -u)"
