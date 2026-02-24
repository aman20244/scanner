#!/bin/bash
# ==========================================
# ELITE RECON ENGINE v5 - CHAOS FULL ASM
# ==========================================

set -euo pipefail
IFS=$'\n\t'

export CHAOS_KEY="${CHAOS_KEY:-}"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p db logs
touch db/subdomains.txt db/domain_health.txt db/js_state.txt db/endpoints.txt db/live_maps.txt

ALERT_FILE="slack_alert.txt"
> "$ALERT_FILE"

# ==========================================
# GUARD: targets.txt must exist
# ==========================================

if [ ! -f targets.txt ]; then
  echo "ERROR: targets.txt not found in working directory!" >&2
  exit 1
fi

echo "Recon Started: $(date -u)"

# ==========================================
# 1. SUBDOMAIN ENUMERATION (ALL PASSIVE)
# ==========================================

echo "Running subfinder..."
subfinder -dL targets.txt -silent -all -o "$TMP_DIR/sf.txt" || true

echo "Running chaos..."
if [ -n "$CHAOS_KEY" ]; then
  chaos -dL targets.txt -key "$CHAOS_KEY" -silent -o "$TMP_DIR/chaos.txt" || true
else
  touch "$TMP_DIR/chaos.txt"
fi

echo "Querying crt.sh..."
while IFS= read -r domain || [ -n "$domain" ]; do
  [ -z "$domain" ] && continue
  curl -s --max-time 40 "https://crt.sh/?q=%25.${domain}&output=json" \
    | jq -r '.[].name_value' 2>/dev/null \
    | sed 's/\*\.//g' >> "$TMP_DIR/crt.txt" || true
done < targets.txt

echo "Querying THC sb/cn..."
while IFS= read -r domain || [ -n "$domain" ]; do
  [ -z "$domain" ] && continue
  curl -s --max-time 30 "https://ip.thc.org/sb/${domain}" \
    | grep -Eo "([a-zA-Z0-9._-]+\.)+${domain}" >> "$TMP_DIR/thc_sb.txt" || true
  curl -s --max-time 30 "https://ip.thc.org/cn/${domain}" \
    | grep -Eo "([a-zA-Z0-9._-]+\.)+${domain}" >> "$TMP_DIR/thc_cn.txt" || true
done < targets.txt

# Merge & normalize — ensure all source files exist before cat
for f in sf chaos crt thc_sb thc_cn; do
  touch "$TMP_DIR/${f}.txt"
done

cat "$TMP_DIR/sf.txt" \
    "$TMP_DIR/chaos.txt" \
    "$TMP_DIR/crt.txt" \
    "$TMP_DIR/thc_sb.txt" \
    "$TMP_DIR/thc_cn.txt" \
  | tr '[:upper:]' '[:lower:]' \
  | sed 's/\.$//' \
  | grep -Eo '^([a-zA-Z0-9._-]+\.)+[a-zA-Z]{2,}$' \
  | sort -u > "$TMP_DIR/subs_raw.txt"

echo "Raw subdomains collected: $(wc -l < "$TMP_DIR/subs_raw.txt")"

# ==========================================
# 2. WILDCARD FILTER + DNS RESOLUTION
# ==========================================

echo "Resolving & filtering wildcard DNS..."
dnsx -l "$TMP_DIR/subs_raw.txt" -silent -o "$TMP_DIR/subs_resolved.txt" || true

# Ensure file exists even if dnsx produced nothing
touch "$TMP_DIR/subs_resolved.txt"
echo "Resolved subdomains: $(wc -l < "$TMP_DIR/subs_resolved.txt")"

# ==========================================
# 3. STATE MANAGEMENT
# ==========================================

echo "Detecting new subdomains..."
anew db/subdomains.txt < "$TMP_DIR/subs_resolved.txt" > "$TMP_DIR/new_subs.txt"

if [ -s "$TMP_DIR/new_subs.txt" ]; then
  NEW_COUNT=$(wc -l < "$TMP_DIR/new_subs.txt" | xargs)
  echo "🚀 *NEW SUBDOMAINS ($NEW_COUNT)*" >> "$ALERT_FILE"
  head -n 15 "$TMP_DIR/new_subs.txt" >> "$ALERT_FILE"
  echo "" >> "$ALERT_FILE"
  echo "New subdomains found: $NEW_COUNT"
else
  echo "No new subdomains."
fi

echo "Total subdomains tracked: $(wc -l < db/subdomains.txt)"

# ==========================================
# 4. HEALTH MONITORING
# ==========================================

echo "Probing with httpx..."
# Removed invalid -http and -https flags; added -sc to ensure status codes print
httpx -l "$TMP_DIR/subs_resolved.txt" \
  -sc -silent -no-color \
  > "$TMP_DIR/health.txt" 2>/dev/null || true

# Parse format: https://sub.domain.com [200] -> https://sub.domain.com|200
awk '{gsub(/\[|\]/, "", $2); print $1"|"$2}' "$TMP_DIR/health.txt" \
  | sort -u > "$TMP_DIR/current_health.txt"

anew db/domain_health.txt < "$TMP_DIR/current_health.txt" > "$TMP_DIR/health_changes.txt"

if [ -s "$TMP_DIR/health_changes.txt" ]; then
  HEALTH_COUNT=$(wc -l < "$TMP_DIR/health_changes.txt" | xargs)
  echo "🔄 *STATUS CHANGES ($HEALTH_COUNT)*" >> "$ALERT_FILE"
  head -n 15 "$TMP_DIR/health_changes.txt" >> "$ALERT_FILE"
  echo "" >> "$ALERT_FILE"
  echo "Status changes detected: $HEALTH_COUNT"
else
  echo "No status changes."
fi

# Extract live 200 hosts
awk -F'|' '$2=="200"{print $1}' "$TMP_DIR/current_health.txt" \
  > "$TMP_DIR/live_hosts.txt" || true

LIVE=0
[ -s "$TMP_DIR/live_hosts.txt" ] && LIVE=$(wc -l < "$TMP_DIR/live_hosts.txt")
echo "Live hosts (HTTP 200): $LIVE"

# ==========================================
# 5. JS MONITORING
# ==========================================

touch "$TMP_DIR/js_list.txt"

if [ -s "$TMP_DIR/live_hosts.txt" ]; then
  echo "Crawling JS with katana..."
  katana -list "$TMP_DIR/live_hosts.txt" -silent -jc -d 2 -concurrency 5 \
    | grep "\.js$" \
    | sort -u > "$TMP_DIR/js_list.txt" || true
fi

# Process JS files — unique temp file per job to avoid race conditions
process_js() {
  local js="$1"
  local tmp
  tmp=$(mktemp "$TMP_DIR/tmp_js_XXXXXX")
  local status
  status=$(curl -sL --max-time 20 -w "%{http_code}" -o "$tmp" "$js" 2>/dev/null || echo "000")
  if [ "$status" = "200" ] && [ -s "$tmp" ]; then
    local hash
    hash=$(sha256sum "$tmp" | awk '{print $1}')
    echo "$js|$hash"
  fi
  rm -f "$tmp"
}
export -f process_js
export TMP_DIR

# Run JS processing in parallel with xargs
if [ -s "$TMP_DIR/js_list.txt" ]; then
  cat "$TMP_DIR/js_list.txt" | xargs -P 10 -I{} bash -c 'process_js "{}"' > "$TMP_DIR/js_hashes.txt" || true
else
  touch "$TMP_DIR/js_hashes.txt"
fi

anew db/js_state.txt < "$TMP_DIR/js_hashes.txt" > "$TMP_DIR/js_changes.txt"

if [ -s "$TMP_DIR/js_changes.txt" ]; then
  JS_COUNT=$(wc -l < "$TMP_DIR/js_changes.txt" | xargs)
  echo "📦 *JS CHANGES ($JS_COUNT)*" >> "$ALERT_FILE"
  head -n 15 "$TMP_DIR/js_changes.txt" >> "$ALERT_FILE"
  echo "" >> "$ALERT_FILE"
  echo "JS changes detected: $JS_COUNT"
else
  echo "No JS changes."
fi

# Source Map Detection
if [ -s "$TMP_DIR/js_changes.txt" ]; then
  cut -d'|' -f1 "$TMP_DIR/js_changes.txt" | while IFS= read -r js || [ -n "$js" ]; do
    [ -z "$js" ] && continue
    map_status=$(curl -sI --max-time 10 "${js}.map" 2>/dev/null | awk 'NR==1{print $2}' || echo "000")
    if echo "$map_status" | grep -q "200"; then
      if echo "${js}.map" | anew db/live_maps.txt | grep -q .; then
        echo "🗺️ *SOURCE MAP:* ${js}.map" >> "$ALERT_FILE"
      fi
    fi
  done || true
fi

# ==========================================
# 6. ENDPOINT EXTRACTION
# ==========================================

echo "Extracting endpoints from JS..."
> "$TMP_DIR/endpoints_raw.txt"

if [ -s "$TMP_DIR/js_hashes.txt" ]; then
  cut -d'|' -f1 "$TMP_DIR/js_hashes.txt" | while IFS= read -r js || [ -n "$js" ]; do
    [ -z "$js" ] && continue
    # Added -a flag to grep to prevent it from aborting on minified JS that looks like binary data
    curl -sL --max-time 20 "$js" \
      | grep -aoP "(?<=[\"'\`])(https?://[^\"'\` ]+|/[^\"'\` ]+)(?=[\"'\`])" \
      >> "$TMP_DIR/endpoints_raw.txt" || true
  done || true
fi

sort -u "$TMP_DIR/endpoints_raw.txt" > "$TMP_DIR/endpoints_clean.txt"
anew db/endpoints.txt < "$TMP_DIR/endpoints_clean.txt" > "$TMP_DIR/new_endpoints.txt"

if [ -s "$TMP_DIR/new_endpoints.txt" ]; then
  EP_COUNT=$(wc -l < "$TMP_DIR/new_endpoints.txt" | xargs)
  echo "🔗 *NEW ENDPOINTS ($EP_COUNT)*" >> "$ALERT_FILE"
  head -n 15 "$TMP_DIR/new_endpoints.txt" >> "$ALERT_FILE"
  echo "" >> "$ALERT_FILE"
  echo "New endpoints found: $EP_COUNT"
else
  echo "No new endpoints."
fi

# ==========================================
# 7. SLACK ALERT
# ==========================================

if [ -s "$ALERT_FILE" ]; then
  echo "Alert file written: $ALERT_FILE"
else
  echo "No changes detected — no alert."
fi

echo "Recon Completed: $(date -u)"
