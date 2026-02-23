#!/bin/bash
# ==========================================
# 🛡️ ELITE RECON ENGINE v3 - CHAOS EDITION
# ==========================================

set -euo pipefail
IFS=$'\n\t'

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Setup file structure
mkdir -p db logs
touch db/subdomains.txt db/endpoints.txt db/js_state.txt db/live_maps.txt db/domain_health.txt

ALERT_FILE="slack_alert.txt"
> "$ALERT_FILE"

echo "🚀 [$(date)] - Ultimate Recon Engine Initiated"

# ==========================================
# 🌍 1. SUBDOMAIN ENUMERATION
# ==========================================

echo "🔎 Running Discovery..."

# Standard tooling
subfinder -dL targets.txt -silent -all -o "$TMP_DIR/sf.txt" || true
chaos -dL targets.txt -silent > "$TMP_DIR/chaos.txt" || true

# Robust crt.sh querying
echo "🌐 Querying crt.sh..."
while read -r domain; do
    sleep 1
    response=$(curl -s --max-time 40 "https://crt.sh/?q=%25.${domain}&output=json" || true)
    if [[ "$response" == \[* ]]; then
        echo "$response" | jq -r '.[].name_value' 2>/dev/null \
            | sed 's/\*\.//g' >> "$TMP_DIR/crt.txt" || true
    fi
done < targets.txt

# THC Passive Sources
echo "🌐 Querying THC Sources..."
while read -r domain; do
    sleep 1
    curl -s --max-time 30 "https://ip.thc.org/sb/${domain}" \
        | grep -Eo "([a-zA-Z0-9._-]+\.)+${domain}" >> "$TMP_DIR/thc_sb.txt" || true
    sleep 1
    curl -s --max-time 30 "https://ip.thc.org/cn/${domain}" \
        | grep -Eo "([a-zA-Z0-9._-]+\.)+${domain}" >> "$TMP_DIR/thc_cn.txt" || true
done < targets.txt

# --- Merge & Normalize ---
cat \
  "$TMP_DIR/sf.txt" \
  "$TMP_DIR/chaos.txt" \
  "$TMP_DIR/crt.txt" \
  "$TMP_DIR/thc_sb.txt" \
  "$TMP_DIR/thc_cn.txt" \
  2>/dev/null \
| tr '[:upper:]' '[:lower:]' \
| sed 's/\.$//' \
| sort -u > "$TMP_DIR/subs_raw.txt"

sort -u db/subdomains.txt -o db/subdomains.txt

comm -23 "$TMP_DIR/subs_raw.txt" db/subdomains.txt > "$TMP_DIR/new_subs.txt" || true

if [ -s "$TMP_DIR/new_subs.txt" ]; then
    echo "🚨 *NEW SUBDOMAINS FOUND*" >> "$ALERT_FILE"
    head -n 10 "$TMP_DIR/new_subs.txt" >> "$ALERT_FILE"
    [[ $(wc -l < "$TMP_DIR/new_subs.txt") -gt 10 ]] && echo "...and more in db/subdomains.txt" >> "$ALERT_FILE"
    cat "$TMP_DIR/new_subs.txt" >> db/subdomains.txt
    sort -u db/subdomains.txt -o db/subdomains.txt
fi

# ==========================================
# 🩺 2. DOMAIN HEALTH CHECK
# ==========================================

echo "🩺 Checking health and status codes..."

httpx -l db/subdomains.txt -silent -t 20 -rl 40 -status-code -fr -title -no-color \
    > "$TMP_DIR/health_raw.txt" || true

awk '{gsub(/\[|\]/,"",$2); print $1"|"$2}' "$TMP_DIR/health_raw.txt" \
    | sort -u > "$TMP_DIR/current_health.txt"

> "$TMP_DIR/live_hosts.txt"

while IFS='|' read -r domain new_status; do
    [[ "$new_status" == "200" ]] && echo "$domain" >> "$TMP_DIR/live_hosts.txt"
    old_status=$(awk -v dom="$domain" -F'|' '$1==dom {print $2}' db/domain_health.txt)
    old_status=${old_status:-NEW}
    if [ "$old_status" != "NEW" ] && [ "$old_status" != "$new_status" ]; then
        if [ "$new_status" == "200" ] && [[ "$old_status" =~ ^(401|403|404|302|500)$ ]]; then
            echo "🔓 *AUTH DROPPED:* $domain ($old_status ➔ 200)" >> "$ALERT_FILE"
        elif [ "$new_status" == "404" ]; then
            echo "💀 *POTENTIAL TAKEOVER:* $domain ($old_status ➔ 404)" >> "$ALERT_FILE"
        else
            echo "🔄 *STATE CHANGE:* $domain ($old_status ➔ $new_status)" >> "$ALERT_FILE"
        fi
    fi
done < "$TMP_DIR/current_health.txt"

# --- Dead Hosts Detection ---
awk -F'|' '{print $1}' db/domain_health.txt | sort -u > "$TMP_DIR/old.txt"
awk -F'|' '{print $1}' "$TMP_DIR/current_health.txt" | sort -u > "$TMP_DIR/new.txt"
comm -23 "$TMP_DIR/old.txt" "$TMP_DIR/new.txt" > "$TMP_DIR/dead.txt" || true

if [ -s "$TMP_DIR/dead.txt" ]; then
    while read -r d; do
        old=$(awk -v dom="$d" -F'|' '$1==dom {print $2}' db/domain_health.txt)
        echo "🪦 *OFFLINE:* $d (Was $old)" >> "$ALERT_FILE"
    done < "$TMP_DIR/dead.txt"
fi

cp "$TMP_DIR/current_health.txt" db/domain_health.txt

# ==========================================
# 📦 3. JS MONITORING & SOURCE MAPS
# ==========================================

echo "📦 Crawling for JavaScript and diffing changes..."

if [ -s "$TMP_DIR/live_hosts.txt" ]; then
    katana -list "$TMP_DIR/live_hosts.txt" -jc -kf all -fx -d 3 -silent -concurrency 3 \
        | grep "\.js$" | sort -u > "$TMP_DIR/js_list.txt" || true

    while read -r js_url; do
        sleep 0.5
        status=$(curl -sL -o /dev/null -w "%{http_code}" --max-time 15 "$js_url" || echo "000")
        [ "$status" != "200" ] && continue
        asset="$TMP_DIR/asset.js"
        curl -sL --max-time 20 "$js_url" -o "$asset" || continue
        [ ! -s "$asset" ] && continue
        new_hash=$(sha256sum "$asset" | awk '{print $1}')
        old_hash=$(awk -v url="$js_url" -F'|' '$1==url {print $2}' db/js_state.txt)
        old_hash=${old_hash:-NEW}
        if [ "$new_hash" != "$old_hash" ]; then
            echo "⚡ *JS CHANGE:* $js_url" >> "$ALERT_FILE"
            grep -vF "${js_url}|" db/js_state.txt > "$TMP_DIR/js_tmp" || true
            echo "$js_url|$new_hash|$(date +%s)" >> "$TMP_DIR/js_tmp"
            mv "$TMP_DIR/js_tmp" db/js_state.txt
            # Source maps
            if curl -sI --max-time 5 "${js_url}.map" | grep -q "200 OK"; then
                if ! grep -qF "${js_url}.map" db/live_maps.txt; then
                    echo "🔥 *MAP FOUND:* ${js_url}.map" >> "$ALERT_FILE"
                    echo "${js_url}.map" >> db/live_maps.txt
                fi
            fi
            # Extract Endpoints
            grep -oP "(?<=[\"'\`])(https?://[^\"'\` ]+|/[^\"'\` ]+)(?=[\"'\`])" "$asset" \
                | sort -u >> "$TMP_DIR/raw_endpoints.txt" || true
        fi
    done < "$TMP_DIR/js_list.txt"
fi

# ==========================================
# 🎯 4. ENDPOINT DIFF
# ==========================================

echo "🎯 Analyzing endpoints..."

if [ -f "$TMP_DIR/raw_endpoints.txt" ]; then
    sort -u "$TMP_DIR/raw_endpoints.txt" -o "$TMP_DIR/raw_endpoints.txt"
    sort -u db/endpoints.txt -o db/endpoints.txt
    comm -23 "$TMP_DIR/raw_endpoints.txt" db/endpoints.txt > "$TMP_DIR/new_endpoints.txt" || true
    if [ -s "$TMP_DIR/new_endpoints.txt" ]; then
        echo -e "\n🎯 *NEW ENDPOINTS*" >> "$ALERT_FILE"
        head -n 10 "$TMP_DIR/new_endpoints.txt" >> "$ALERT_FILE"
        [[ $(wc -l < "$TMP_DIR/new_endpoints.txt") -gt 10 ]] && echo "...and more in db/endpoints.txt" >> "$ALERT_FILE"
        cat "$TMP_DIR/new_endpoints.txt" >> db/endpoints.txt
        sort -u db/endpoints.txt -o db/endpoints.txt
    fi
fi

echo "✅ Finished: $(date)"
