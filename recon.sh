#!/bin/bash

# ==========================================
# 🛡️ 1. ENTERPRISE GUARDRAILS
# ==========================================
set -euo pipefail
IFS=$'\n\t'

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT 

mkdir -p db logs
touch db/subdomains.txt db/js_state.txt db/endpoints.txt db/live_maps.txt db/domain_health.txt
ALERT_FILE="slack_alert.txt"
> "$ALERT_FILE"

echo "🚀 [$(date)] - Elite Recon Engine Initiated"

# ==========================================
# 🌍 2. SUBDOMAIN DISCOVERY & STRICT DIFF
# ==========================================
subfinder -dL targets.txt -all -silent -o "$TMP_DIR/subs_raw.txt" || true

sort -u "$TMP_DIR/subs_raw.txt" -o "$TMP_DIR/subs_raw.txt"
sort -u db/subdomains.txt -o db/subdomains.txt

comm -23 "$TMP_DIR/subs_raw.txt" db/subdomains.txt > "$TMP_DIR/new_subs.txt" || true

if [ -s "$TMP_DIR/new_subs.txt" ]; then
    echo "🚨 *NEW SUBDOMAINS FOUND*" >> "$ALERT_FILE"
    head -n 15 "$TMP_DIR/new_subs.txt" >> "$ALERT_FILE"
    cat "$TMP_DIR/new_subs.txt" >> db/subdomains.txt
    sort -u db/subdomains.txt -o db/subdomains.txt
fi

# ==========================================
# 🩺 3. DOMAIN HEALTH & ELITE STATE MONITORING
# ==========================================
echo "🩺 Checking Infrastructure Health..."

httpx -l db/subdomains.txt -silent -t 15 -rl 30 -status-code -no-color > "$TMP_DIR/health_raw.txt" || true
awk '{gsub(/\[|\]/,"",$2); print $1"|"$2}' "$TMP_DIR/health_raw.txt" | sort -u > "$TMP_DIR/current_health.txt"

> "$TMP_DIR/live_hosts.txt"

# State Machine Diffing
while IFS='|' read -r domain new_status; do
    if [ "$new_status" == "200" ]; then
        echo "$domain" >> "$TMP_DIR/live_hosts.txt"
    fi

    old_status=$(awk -v dom="$domain" -F'|' '$1==dom {print $2}' db/domain_health.txt)
    old_status=${old_status:-NEW}

    if [ "$old_status" != "NEW" ] && [ "$old_status" != "$new_status" ]; then
        if [ "$new_status" == "200" ] && [[ "$old_status" =~ ^(401|403|404|302|500)$ ]]; then
            echo "🔓 *AUTH DROPPED / NEWLY LIVE:* $domain ($old_status ➔ 200)" >> "$ALERT_FILE"
        elif [ "$new_status" == "404" ]; then
            echo "💀 *POTENTIAL TAKEOVER:* $domain ($old_status ➔ 404)" >> "$ALERT_FILE"
        else
            echo "🔄 *STATE CHANGE:* $domain ($old_status ➔ $new_status)" >> "$ALERT_FILE"
        fi
    fi
done < "$TMP_DIR/current_health.txt"

# True Dead Host Detection
awk -F'|' '{print $1}' db/domain_health.txt | sort -u > "$TMP_DIR/old_domains.txt"
awk -F'|' '{print $1}' "$TMP_DIR/current_health.txt" | sort -u > "$TMP_DIR/new_domains.txt"
comm -23 "$TMP_DIR/old_domains.txt" "$TMP_DIR/new_domains.txt" > "$TMP_DIR/dead_domains.txt" || true

if [ -s "$TMP_DIR/dead_domains.txt" ]; then
    while read -r dead_domain; do
        old_status=$(awk -v dom="$dead_domain" -F'|' '$1==dom {print $2}' db/domain_health.txt)
        echo "🪦 *DNS DROPPED/OFFLINE:* $dead_domain (Was $old_status)" >> "$ALERT_FILE"
    done < "$TMP_DIR/dead_domains.txt"
fi

cp "$TMP_DIR/current_health.txt" db/domain_health.txt

# ==========================================
# 📦 4. JAVASCRIPT & ENDPOINT ANALYTICS
# ==========================================
if [ -s "$TMP_DIR/live_hosts.txt" ]; then
    echo "🕷️ Crawling Javascript..."
    # ✅ FIX 4: Deep Katana crawling with form extraction and known files
    katana -list "$TMP_DIR/live_hosts.txt" -jc -kf all -fx -d 3 -silent -concurrency 3 | grep "\.js$" | sort -u > "$TMP_DIR/js_list.txt" || true

    while read -r js_url; do
        asset_file="$TMP_DIR/asset.js"
        
        # ✅ FIX 2: Rate Limiting to protect the GitHub Runner
        sleep 0.5 
        
        status=$(curl -sL -o /dev/null -w "%{http_code}" --max-time 15 "$js_url" || echo "000")
        if [ "$status" != "200" ]; then continue; fi
        
        curl -sL --max-time 20 "$js_url" -o "$asset_file" || continue
        if [ ! -s "$asset_file" ]; then continue; fi
        
        new_hash=$(sha256sum "$asset_file" | awk '{print $1}')
        old_hash=$(awk -v url="$js_url" -F'|' '$1==url {print $2}' db/js_state.txt)
        old_hash=${old_hash:-NEW}

        if [ "$new_hash" != "$old_hash" ]; then
            echo "⚡ *JS CHANGE/NEW:* $js_url" >> "$ALERT_FILE"
            
            grep -vF "${js_url}|" db/js_state.txt > "$TMP_DIR/js_state_tmp" || true
            echo "$js_url|$new_hash|$(date +%s)" >> "$TMP_DIR/js_state_tmp"
            mv "$TMP_DIR/js_state_tmp" db/js_state.txt

            map_status=$(curl -sL -o /dev/null -w "%{http_code}" --max-time 5 "${js_url}.map" || echo "000")
            if [ "$map_status" == "200" ]; then
                 if ! grep -qF "${js_url}.map" db/live_maps.txt; then
                    echo "🔥 *SOURCE MAP DETECTED:* ${js_url}.map" >> "$ALERT_FILE"
                    echo "${js_url}.map" >> db/live_maps.txt
                 fi
            fi

            # ✅ FIX 3: Advanced Endpoint Extraction Regex (PCRE for strict bounding)
            # Extracts everything between quotes/backticks that starts with http or /
            grep -oP "(?<=[\"'\`])(https?://[^\"'\` ]+|/[^\"'\` ]+)(?=[\"'\`])" "$asset_file" \
                | sort -u >> "$TMP_DIR/raw_endpoints.txt" || true
        fi
    done < "$TMP_DIR/js_list.txt"
fi

# ==========================================
# 🎯 5. ENDPOINT DIFFING
# ==========================================
if [ -f "$TMP_DIR/raw_endpoints.txt" ]; then
    sort -u "$TMP_DIR/raw_endpoints.txt" -o "$TMP_DIR/raw_endpoints.txt"
    sort -u db/endpoints.txt -o db/endpoints.txt
    
    comm -23 "$TMP_DIR/raw_endpoints.txt" db/endpoints.txt > "$TMP_DIR/new_endpoints.txt" || true
    
    if [ -s "$TMP_DIR/new_endpoints.txt" ]; then
        echo -e "\n🎯 *NEW API ENDPOINTS*" >> "$ALERT_FILE"
        head -n 15 "$TMP_DIR/new_endpoints.txt" >> "$ALERT_FILE"
        cat "$TMP_DIR/new_endpoints.txt" >> db/endpoints.txt
        sort -u db/endpoints.txt -o db/endpoints.txt
    fi
fi
