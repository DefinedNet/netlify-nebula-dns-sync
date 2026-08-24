#!/usr/bin/env bash
set -euo pipefail

DN_API_KEY="${DN_API_KEY:?Set DN_API_KEY to your Defined Networking API key}"
NETLIFY_TOKEN="${NETLIFY_TOKEN:?Set NETLIFY_TOKEN to your Netlify personal access token}"
NETLIFY_ZONE_ID="${NETLIFY_ZONE_ID:?Set NETLIFY_ZONE_ID to your Netlify DNS zone ID}"
SUBDOMAIN="${SUBDOMAIN:-dn}"
DOMAIN="${DOMAIN:?Set DOMAIN to your domain (e.g. example.com)}"

NETLIFY_API="https://api.netlify.com/api/v1"

api() {
  local response http_code body
  response=$(curl -s -w '\n%{http_code}' "$@")
  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')
  if [ "$http_code" -ge 400 ]; then
    echo "Error: HTTP $http_code — $body" >&2
    return 1
  fi
  echo "$body"
}

sanitize() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed "s/['''ʼ]//g" \
    | sed 's/[^a-z0-9-]/-/g' \
    | sed 's/--*/-/g' \
    | sed 's/^-//;s/-$//'
}

# Fetch all hosts from the DN API, handling pagination
cursor=""
all_hosts="[]"
while true; do
  if [ -z "$cursor" ]; then
    page=$(api -H "Authorization: Bearer $DN_API_KEY" \
      "https://api.defined.net/v2/hosts")
  else
    page=$(api -H "Authorization: Bearer $DN_API_KEY" \
      "https://api.defined.net/v2/hosts?cursor=$cursor")
  fi

  all_hosts=$(echo "$all_hosts $page" | jq -s '.[0] + (.[1].data // [])')

  has_next=$(echo "$page" | jq -r '.metadata.hasNextPage // false')
  if [ "$has_next" != "true" ]; then
    break
  fi
  cursor=$(echo "$page" | jq -r '.metadata.nextCursor // empty')
done

# Warn about name collisions
echo "$all_hosts" | jq -r '
  [.[] | {
    original: .name,
    label: (.name | ascii_downcase | gsub("['\''ʼ']"; "") | gsub("[^a-z0-9-]"; "-") | gsub("-+"; "-") | gsub("^-|-$"; ""))
  }] | group_by(.label) | map(select(length > 1)) | .[] |
  "Warning: \([.[].original] | map("\"" + . + "\"") | join(" and ")) both sanitize to \"\(.[0].label)\""
' >&2

# Build the desired record set from the host list
# Netlify hostnames are relative to the zone, so "db-01.dn" becomes "db-01.dn.example.com"
desired=$(echo "$all_hosts" | jq -r --arg sub "$SUBDOMAIN" --arg dom "$DOMAIN" '
  [.[] | {
    name: .name,
    addresses: .ipAddresses
  }] | map(
    (.name | ascii_downcase | gsub("['\''ʼ'\'']"; "") | gsub("[^a-z0-9-]"; "-") | gsub("-+"; "-") | gsub("^-|-$"; "")) as $label |
    .addresses[] | {
      hostname: ($label + "." + $sub + "." + $dom),
      api_hostname: ($label + "." + $sub),
      type: (if test(":") then "AAAA" else "A" end),
      value: .
    }
  )
')

# Fetch existing DNS records from Netlify, filtered to our subdomain
existing=$(api \
  -H "Authorization: Bearer $NETLIFY_TOKEN" \
  "$NETLIFY_API/dns_zones/$NETLIFY_ZONE_ID/dns_records" \
  | jq --arg suffix ".$SUBDOMAIN.$DOMAIN" \
    '[.[] | select(.hostname | endswith($suffix)) | select(.type == "A" or .type == "AAAA")]')

# Delete stale records (exist in Netlify but not in desired set)
echo "$existing" | jq -r '.[] | [.id, .hostname, .type, .value] | @tsv' | while IFS=$'\t' read -r id hostname type value; do
  match=$(echo "$desired" | jq --arg h "$hostname" --arg t "$type" --arg v "$value" \
    '[.[] | select(.hostname == $h and .type == $t and .value == $v)] | length')
  if [ "$match" -eq 0 ]; then
    echo "Deleting stale record: $type $hostname -> $value"
    api -X DELETE \
      -H "Authorization: Bearer $NETLIFY_TOKEN" \
      "$NETLIFY_API/dns_zones/$NETLIFY_ZONE_ID/dns_records/$id" > /dev/null
  fi
done

# Create missing records (exist in desired set but not in Netlify)
created=0
echo "$desired" | jq -c '.[]' | while read -r record; do
  hostname=$(echo "$record" | jq -r '.hostname')
  api_hostname=$(echo "$record" | jq -r '.api_hostname')
  type=$(echo "$record" | jq -r '.type')
  value=$(echo "$record" | jq -r '.value')

  match=$(echo "$existing" | jq --arg h "$hostname" --arg t "$type" --arg v "$value" \
    '[.[] | select(.hostname == $h and .type == $t and .value == $v)] | length')
  if [ "$match" -eq 0 ]; then
    echo "Creating record: $type $hostname -> $value"
    api -X POST \
      -H "Authorization: Bearer $NETLIFY_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"type\": \"$type\", \"hostname\": \"$api_hostname\", \"value\": \"$value\", \"ttl\": 3600}" \
      "$NETLIFY_API/dns_zones/$NETLIFY_ZONE_ID/dns_records" > /dev/null
    created=$((created + 1))
  fi
done

echo "Sync complete."
