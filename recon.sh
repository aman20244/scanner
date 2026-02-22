#!/bin/bash

# ==========================================
# 🛡️ 1. ENTERPRISE GUARDRAILS
# ==========================================
set -euo pipefail
IFS=$'\n\t'

# Workspace & Cleanup
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT 

# Required Directories
mkdir -p db logs
touch db/subdomains.txt db/js_state.txt db/endpoints.txt db/live_maps.txt
ALERT_FILE="slack_alert.txt"
> "$ALERT_FILE"

echo "🚀 [$(date)] - Hardened Engine Initiated"

# ==========================================
# 🌍 2. RECONNAISSANCE LAYER
# ==========================================
# Subdomain Discovery (Passive & Active)
subfinder -dL targets.txt -all -silent -o "$TMP_DIR/subs_raw.txt" || true
sort -u "$TMP_DIR/subs_raw.txt" -o "$TMP_DIR/subs_raw.txt"

# Atomic Diff for Subdomains
comm -23 "$TMP_DIR/subs_raw.txt" db/subdomains.txt > "$TMP_DIR/new_subs.txt" || true

if [ -s "$TMP_DIR/new_subs.txt" ]; then
    echo "🚨 *NEW SUBDOMAINS FOUND*" >> "$ALERT_FILE"
    cat "$TMP_DIR/new_subs.txt" >> "$ALERT_FILE"
    cat "$TMP_DIR/new_subs.txt" >> db/subdomains.txt
    sort -u db/subdomains.txt -o db/subdomains.txt
fi

# Live Host Probing (Rate Limited for Stealth)
httpx -l db/subdomains.txt -silent -t 15 -rl 30 -o "$TMP_DIR/live_hosts.txt"

# ==========================================
# 📦 3. JAVASCRIPT & ENDPOINT ANALYTICS
# ==========================================
# Deep JS Crawling
katana -list "$TMP_DIR/live_hosts.txt" -jc -d 2 -silent -concurrency 3 | grep "\.js$" | sort -u > "$TMP_DIR/js_list.txt"

while read -r js_url; do
    asset_file="$TMP_DIR/asset.js"
    # Download with timeout and size check
    curl -sL --max-time 15 --head "$js_url" | grep -q "200 OK" || continue
    curl -sL --max-time 20 "$js_url" -o "$asset_file" || continue
    
    # 1. State-Aware Hash Check
    new_hash=$(sha256sum "$asset_file" | awk '{print $1}')
    # Format: URL|HASH (Extracting second field)
    old_hash=$(grep "^$js_url|" db/js_state.txt | cut -d'|' -f2 || echo "NEW")

    if [ "$new_hash" != "$old_hash" ]; then
        echo "⚡ *JS CHANGE/NEW:* $js_url" >> "$ALERT_FILE"
        
        # Update State (Atomic Swap)
        grep -v "^$js_url|" db/js_state.txt > "$TMP_DIR/js_state_tmp" || true
        echo "$js_url|$new_hash|$(date +%s)" >> "$TMP_DIR/js_state_tmp"
        mv "$TMP_DIR/js_state_tmp" db/js_state.txt

        # 2. Source Map Hunting
        if curl -sL -I --max-time 5 "${js_url}.map" | grep -q "200 OK"; then
             if ! grep -q "${js_url}.map" db/live_maps.txt; then
                echo "🔥 *SOURCE MAP DETECTED:* ${js_url}.map" >> "$ALERT_FILE"
                echo "${js_url}.map" >> db/live_maps.txt
             fi
        fi

        # 3. Aggressive API Extraction
        grep -Eo "(['\"]|`)(https?://|\/|//)[a-zA-Z0-9\.\/_?=&%#+-]+(['\"]|`)" "$asset_file" \
            | tr -d "'\"\`" | sed 's/^\///' | sort -u >> "$TMP_DIR/raw_endpoints.txt" || true
    fi
done < "$TMP_DIR/js_list.txt"

# ==========================================
# 🎯 4. ENDPOINT DIFFING
# ==========================================
if [ -f "$TMP_DIR/raw_endpoints.txt" ]; then
    sort -u "$TMP_DIR/raw_endpoints.txt" -o "$TMP_DIR/raw_endpoints.txt"
    comm -23 "$TMP_DIR/raw_endpoints.txt" <(sort -u db/endpoints.txt) > "$TMP_DIR/new_endpoints.txt" || true
    
    if [ -s "$TMP_DIR/new_endpoints.txt" ]; then
        echo -e "\n🎯 *NEW API ENDPOINTS*" >> "$ALERT_FILE"
        cat "$TMP_DIR/new_endpoints.txt" | head -n 15 >> "$ALERT_FILE"
        cat "$TMP_DIR/new_endpoints.txt" >> db/endpoints.txt
        sort -u db/endpoints.txt -o db/endpoints.txt
    fi
fi
