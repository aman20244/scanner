#!/bin/bash
# ==========================================
# 🛡️ ELITE RECON ENGINE v5 - FULL PRODUCTION
# ==========================================

set -euo pipefail
IFS=$'\n\t'

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p db logs
touch db/subdomains.txt db/domain_health.txt db/js_state.txt db/endpoints.txt db/live_maps.txt

ALERT_FILE="slack_alert.txt"
> "$ALERT_FILE"

echo "🚀 Recon Started: $(date)"

# ==========================================
# 🌍 1. SUBDOMAIN ENUMERATION (ALL SOURCES)
# ==========================================

echo "🔎 Running subfinder..."
subfinder -dL targets.txt -silent -all -o "$TMP_DIR/sf.txt" || true

echo "🔎 Running amass (passive)..."
amass enum -passive -df targets.txt -silent -o "$TMP_DIR/amass.txt" || true

echo "🔎 Running chaos..."
chaos -dL targets.txt -silent -o "$TMP_DIR/chaos.txt" || true

echo "🌐 Querying crt.sh..."
while read -r domain; do
  curl -s --max-time 40 "https://crt.sh/?q=%25.${domain}&output=json" \
  | jq -r '.[].name_value' 2>/dev/null \
  | sed 's/\*\.//g' >> "$TMP_DIR/crt.txt" || true
done < targets.txt

echo "🌐 Querying THC sb/cn..."
while read -r domain; do
  curl -s --max-time 30 "https://ip.thc.org/sb/${domain}" \
  | grep -Eo "([a-zA-Z0-9._-]+\.)+${domain}" >> "$TMP_DIR/thc_sb.txt" || true
  curl -s --max-time 30 "https://ip.thc.org/cn/${domain}" \
  | grep -Eo "([a-zA-Z0-9._-]+\.)+${domain}" >> "$TMP_DIR/thc_cn.txt" || true
done < targets.txt

# Merge all
cat "$TMP_DIR/"*.txt 2>/dev/null \
| tr '[:upper:]' '[:lower:]' \
| sed 's/\.$//' \
| sort -u > "$TMP_DIR/subs_raw.txt"

# ==========================================
# 🛡️ 2. WILDCARD FILTER + RESOLUTION
# ==========================================

echo "🛡️ Filtering Wildcard DNS..."
dnsx -l "$TMP_DIR/subs_raw.txt" -wd -silent -o "$TMP_DIR/subs_resolved.txt"

# ==========================================
# 🧠 3. STATE MANAGEMENT (anew)
# ==========================================

echo "🧠 Detecting new subdomains..."
cat "$TMP_DIR/subs_resolved.txt" \
| anew db/subdomains.txt > "$TMP_DIR/new_subs.txt"

if [ -s "$TMP_DIR/new_subs.txt" ]; then
  echo "🚨 NEW SUBDOMAINS" >> "$ALERT_FILE"
  head -n 15 "$TMP_DIR/new_subs.txt" >> "$ALERT_FILE"
fi

TOTAL=$(wc -l < db/subdomains.txt)
echo "📊 Total subdomains tracked: $TOTAL"

# ==========================================
# 🩺 4. HEALTH MONITORING
# ==========================================

echo "🩺 Probing with httpx..."
httpx -l db/subdomains.txt -silent -t 50 -rl 100 \
-status-code -no-color > "$TMP_DIR/health.txt" || true

awk '{gsub(/\[|\]/,"",$2); print $1"|"$2}' "$TMP_DIR/health.txt" \
| sort -u > "$TMP_DIR/current_health.txt"

cat "$TMP_DIR/current_health.txt" \
| anew db/domain_health.txt > "$TMP_DIR/health_changes.txt"

if [ -s "$TMP_DIR/health_changes.txt" ]; then
  echo "🔄 STATUS CHANGES" >> "$ALERT_FILE"
  head -n 15 "$TMP_DIR/health_changes.txt" >> "$ALERT_FILE"
fi

awk -F'|' '$2=="200"{print $1}' "$TMP_DIR/current_health.txt" \
> "$TMP_DIR/live_hosts.txt"

LIVE=$(wc -l < "$TMP_DIR/live_hosts.txt" 2>/dev/null || echo 0)
echo "🌐 Live hosts: $LIVE"

# ==========================================
# 📦 5. CONCURRENT JS MONITORING
# ==========================================

if [ -s "$TMP_DIR/live_hosts.txt" ]; then
  echo "📦 Crawling JS with katana..."
  katana -list "$TMP_DIR/live_hosts.txt" -silent -jc -d 2 -concurrency 5 \
  | grep "\.js$" | sort -u > "$TMP_DIR/js_list.txt"
fi

process_js() {
  js=$1
  res=$(curl -sL -w "%{http_code}" "$js" -o "$TMP_DIR/tmp_js")
  if [ "$res" = "200" ]; then
    hash=$(sha256sum "$TMP_DIR/tmp_js" | awk '{print $1}')
    echo "$js|$hash"
  fi
}
export -f process_js
export TMP_DIR

cat "$TMP_DIR/js_list.txt" 2>/dev/null \
| xargs -I % -P 20 bash -c 'process_js %' \
> "$TMP_DIR/js_hashes.txt" || true

cat "$TMP_DIR/js_hashes.txt" \
| anew db/js_state.txt > "$TMP_DIR/js_changes.txt"

if [ -s "$TMP_DIR/js_changes.txt" ]; then
  echo "⚡ JS CHANGES" >> "$ALERT_FILE"
  head -n 15 "$TMP_DIR/js_changes.txt" >> "$ALERT_FILE"
fi

# Source Map Detection
grep "\.js|" "$TMP_DIR/js_changes.txt" | cut -d'|' -f1 \
| while read -r js; do
    if curl -sI "${js}.map" | grep -q "200"; then
      echo "${js}.map" | anew db/live_maps.txt >> "$ALERT_FILE"
    fi
done

# ==========================================
# 🎯 6. ENDPOINT EXTRACTION
# ==========================================

echo "🎯 Extracting endpoints..."
> "$TMP_DIR/endpoints_raw.txt"

for js in $(cut -d'|' -f1 "$TMP_DIR/js_hashes.txt" 2>/dev/null); do
  curl -sL "$js" \
  | grep -oP "(?<=[\"'\`])(https?://[^\"'\` ]+|/[^\"'\` ]+)(?=[\"'\`])" \
  >> "$TMP_DIR/endpoints_raw.txt" || true
done

sort -u "$TMP_DIR/endpoints_raw.txt" > "$TMP_DIR/endpoints_clean.txt"

cat "$TMP_DIR/endpoints_clean.txt" \
| anew db/endpoints.txt > "$TMP_DIR/new_endpoints.txt"

if [ -s "$TMP_DIR/new_endpoints.txt" ]; then
  echo "🎯 NEW ENDPOINTS" >> "$ALERT_FILE"
  head -n 15 "$TMP_DIR/new_endpoints.txt" >> "$ALERT_FILE"
fi

# ==========================================
# 📨 7. ALERT SUMMARY
# ==========================================

if [ -s "$ALERT_FILE" ]; then
  echo -e "\n📢 Recon Alerts Generated"
else
  echo "No new changes detected."
fi

echo "✅ Recon Completed: $(date)"
