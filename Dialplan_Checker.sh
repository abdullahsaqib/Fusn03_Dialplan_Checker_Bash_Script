#!/bin/bash

DB_NAME="fusionpbx"
DB_USER="fusionpbx"
DB_PASS="D4xLYHmARlT0B6lueew9XqVE"
DB_HOST="127.0.0.1"
DB_PORT="5432"

echo -ne "Enter destination number to test: "
read number
echo -ne "Enter caller number (extension): "
read caller

MATCHED_FLAG="/tmp/dialplan_matched_$$"
> "$MATCHED_FLAG"

# Cache gateway UUID → name & IP
declare -A GATEWAY_NAME_MAP
declare -A GATEWAY_IP_MAP

while IFS='|' read -r uuid name; do
  GATEWAY_NAME_MAP["$uuid"]="$name"
done < <(
  PGPASSWORD="$DB_PASS" psql -U "$DB_USER" -d "$DB_NAME" -h "$DB_HOST" -p "$DB_PORT" -t -A -F "|" -c \
  "SELECT gateway_uuid, gateway FROM v_gateways;" 2>/dev/null
)

while IFS='|' read -r name ip; do
  GATEWAY_IP_MAP["$name"]="$ip"
done < <(
  PGPASSWORD="$DB_PASS" psql -U "$DB_USER" -d "$DB_NAME" -h "$DB_HOST" -p "$DB_PORT" -t -A -F "|" -c \
  "SELECT gateway, proxy FROM v_gateways;" 2>/dev/null
)

# Fetch dialplans with destination_number conditions
PGPASSWORD="$DB_PASS" psql -U "$DB_USER" -d "$DB_NAME" -h "$DB_HOST" -p "$DB_PORT" -t -A -F "|" -c \
"SELECT dp.dialplan_uuid, dp.dialplan_name, dd.dialplan_detail_data
 FROM v_dialplans dp
 JOIN v_dialplan_details dd ON dp.dialplan_uuid = dd.dialplan_uuid
 WHERE dd.dialplan_detail_type = 'destination_number'
   AND dd.dialplan_detail_data LIKE '^%';" 2>/dev/null | while IFS='|' read -r uuid name dest_regex
do
  # Clean up regex: replace \\d with [0-9], remove extra escapes
  clean_regex=$(echo "$dest_regex" | sed 's/\\d/[0-9]/g; s/\\//g')

  # Skip if regex is empty or invalid
  if [[ -z "$clean_regex" ]]; then
    echo "Skipping dialplan '$name': Empty or invalid destination regex" >&2
    continue
  fi

  # Check destination_number match using grep with PCRE
  if echo "$number" | grep -Pq "^$clean_regex$" 2>/dev/null; then
    # Fetch caller_id_number regex
    caller_regex=$(PGPASSWORD="$DB_PASS" psql -U "$DB_USER" -d "$DB_NAME" -h "$DB_HOST" -p "$DB_PORT" -t -A -F "|" -c \
      "SELECT dialplan_detail_data FROM v_dialplan_details WHERE dialplan_uuid = '$uuid' AND dialplan_detail_type = 'caller_id_number' LIMIT 1;" 2>/dev/null)

    # Skip if no caller_id_number condition exists
    if [[ -z "$caller_regex" ]]; then
      continue
    fi

    # Clean caller regex
    clean_caller_regex=$(echo "$caller_regex" | sed 's/\\d/[0-9]/g; s/\\//g')

    # Skip if caller regex is empty or invalid
    if [[ -z "$clean_caller_regex" ]]; then
      echo "Skipping dialplan '$name': Empty or invalid caller regex" >&2
      continue
    fi

    # Check caller_id_number match
    if ! echo "$caller" | grep -Pq "^$clean_caller_regex$" 2>/dev/null; then
      continue
    fi

    # Check if dialplan has a bridge action
    has_bridge=$(PGPASSWORD="$DB_PASS" psql -U "$DB_USER" -d "$DB_NAME" -h "$DB_HOST" -p "$DB_PORT" -t -A -F "|" -c \
      "SELECT 1 FROM v_dialplan_details WHERE dialplan_uuid = '$uuid' AND dialplan_detail_tag = 'action' AND dialplan_detail_type = 'bridge' LIMIT 1;" 2>/dev/null)

    # Skip dialplans without a bridge action
    if [[ -z "$has_bridge" ]]; then
      continue
    fi

    # Output matched dialplan details
    echo "Matched Dialplan: $name"
    echo "   Conditions:"
    # Fetch all conditions
    PGPASSWORD="$DB_PASS" psql -U "$DB_USER" -d "$DB_NAME" -h "$DB_HOST" -p "$DB_PORT" -t -A -F "|" -c \
      "SELECT dialplan_detail_type, dialplan_detail_data FROM v_dialplan_details WHERE dialplan_uuid = '$uuid' AND dialplan_detail_tag = 'condition' ORDER BY dialplan_detail_order;" 2>/dev/null | while IFS='|' read -r cond_type cond_data
    do
      echo "      • $cond_type => $cond_data"
    done
    echo "   Actions:"
    # Fetch all actions
    PGPASSWORD="$DB_PASS" psql -U "$DB_USER" -d "$DB_NAME" -h "$DB_HOST" -p "$DB_PORT" -t -A -F "|" -c \
      "SELECT dialplan_detail_type, dialplan_detail_data FROM v_dialplan_details WHERE dialplan_uuid = '$uuid' AND dialplan_detail_tag = 'action' ORDER BY dialplan_detail_order;" 2>/dev/null | while IFS='|' read -r action_type action_data
    do
      # Replace gateway UUID with name in bridge action
      if [[ "$action_type" == "bridge" && "$action_data" =~ sofia/gateway/([a-f0-9\-]{36}) ]]; then
        gw_uuid="${BASH_REMATCH[1]}"
        gw_name="${GATEWAY_NAME_MAP[$gw_uuid]}"
        gw_ip="${GATEWAY_IP_MAP[$gw_name]}"
        if [[ -n "$gw_name" ]]; then
          action_data="${action_data//$gw_uuid/$gw_name}"
          if [[ -n "$gw_ip" ]]; then
            action_data="$action_data (IP: $gw_ip)"
          fi
        fi
      fi
      echo "      • $action_type => $action_data"
    done
    echo ""
    echo "matched" > "$MATCHED_FLAG"
  fi
done

if ! grep -q matched "$MATCHED_FLAG"; then
  echo "No matching dialplan found for: $number (Caller: $caller)"
fi

rm -f "$MATCHED_FLAG"
