#!/usr/bin/env bash
set -euo pipefail

DN_API_KEY="${DN_API_KEY:?Set DN_API_KEY to your Defined Networking API key}"
NETLIFY_TOKEN="${NETLIFY_TOKEN:?Set NETLIFY_TOKEN to your Netlify personal access token}"
DOMAIN="${DOMAIN:?Set DOMAIN to your domain (e.g. example.com)}"
SUBDOMAIN="${SUBDOMAIN:-dn}"

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

# Look up the Netlify DNS zone ID from the domain name
NETLIFY_ZONE_ID=$(api \
  -H "Authorization: Bearer $NETLIFY_TOKEN" \
  "$NETLIFY_API/dns_zones" \
  | jq -r --arg dom "$DOMAIN" '.[] | select(.name == $dom) | .id' \
  | head -1)

if [ -z "$NETLIFY_ZONE_ID" ]; then
  echo "Error: no Netlify DNS zone found for $DOMAIN" >&2
  exit 1
fi

echo "Found zone $NETLIFY_ZONE_ID for $DOMAIN"

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
    label: (.name | ascii_downcase | gsub("[\u0027\u2018\u2019\u02bc]"; "") | gsub("[^a-z0-9-]"; "-") | gsub("-+"; "-") | gsub("^-|-$"; ""))
  }] | group_by(.label) | map(select(length > 1)) | .[] |
  "::warning::\([.[].original] | map("\"" + . + "\"") | join(", ")) \(if length == 2 then "both" else "all" end) sanitize to \"\(.[0].label)\""
' >&2

# Build the desired record set from the host list
desired=$(echo "$all_hosts" | jq -r --arg sub "$SUBDOMAIN" --arg dom "$DOMAIN" '
  [.[] | {
    name: .name,
    addresses: .ipAddresses
  }] | map(
    .name as $n | .addresses[] | {
      hostname: (($n | ascii_downcase | gsub("[\u0027\u2018\u2019\u02bc]"; "") | gsub("[^a-z0-9-]"; "-") | gsub("-+"; "-") | gsub("^-|-$"; "")) + "." + $sub + "." + $dom),
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
echo "$desired" | jq -c '.[]' | while read -r record; do
  hostname=$(echo "$record" | jq -r '.hostname')
  type=$(echo "$record" | jq -r '.type')
  value=$(echo "$record" | jq -r '.value')

  match=$(echo "$existing" | jq --arg h "$hostname" --arg t "$type" --arg v "$value" \
    '[.[] | select(.hostname == $h and .type == $t and .value == $v)] | length')
  if [ "$match" -eq 0 ]; then
    echo "Creating record: $type $hostname -> $value"
    api -X POST \
      -H "Authorization: Bearer $NETLIFY_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg type "$type" --arg hostname "$hostname" --arg value "$value" \
        '{type: $type, hostname: $hostname, value: $value, ttl: 3600}')" \
      "$NETLIFY_API/dns_zones/$NETLIFY_ZONE_ID/dns_records" > /dev/null
  fi
done

echo "Sync complete."
