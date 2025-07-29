#!/bin/bash
set -e
echo "Starting bulk cleanup of expired secrets for ALL service principals..."

# Parse exclusion lists from environment variables
EXCLUDE_NAMES_LIST=""
EXCLUDE_DESCRIPTIONS_LIST=""
MAX_CONCURRENT=${MAX_CONCURRENT:-5} # Default to 5 concurrent processes
DRY_RUN=${DRY_RUN:-false}           # Set to true to just show what would be deleted

if [ -n "$EXCLUDE_NAMES" ]; then
  EXCLUDE_NAMES_LIST="$EXCLUDE_NAMES"
  echo "Excluding tokens with names: $EXCLUDE_NAMES_LIST"
fi

if [ -n "$EXCLUDE_DESCRIPTIONS" ]; then
  EXCLUDE_DESCRIPTIONS_LIST="$EXCLUDE_DESCRIPTIONS"
  echo "Excluding tokens with descriptions: $EXCLUDE_DESCRIPTIONS_LIST"
fi

if [ "$DRY_RUN" = "true" ]; then
  echo "DRY RUN MODE: Will show what would be deleted without actually deleting"
fi

echo "Maximum concurrent operations: $MAX_CONCURRENT"

# Function to check if a value should be excluded
should_exclude() {
  local display_name="$1"
  local hint="$2"

  # Check against excluded names (comma-separated)
  if [ -n "$EXCLUDE_NAMES_LIST" ]; then
    IFS=',' read -ra EXCLUDE_NAMES_ARRAY <<<"$EXCLUDE_NAMES_LIST"
    for exclude_name in "${EXCLUDE_NAMES_ARRAY[@]}"; do
      exclude_name=$(echo "$exclude_name" | xargs) # Trim whitespace
      if [ -n "$display_name" ] && [[ "$display_name" == *"$exclude_name"* ]]; then
        return 0
      fi
    done
  fi

  # Check against excluded descriptions (comma-separated)
  if [ -n "$EXCLUDE_DESCRIPTIONS_LIST" ]; then
    IFS=',' read -ra EXCLUDE_DESCRIPTIONS_ARRAY <<<"$EXCLUDE_DESCRIPTIONS_LIST"
    for exclude_desc in "${EXCLUDE_DESCRIPTIONS_ARRAY[@]}"; do
      exclude_desc=$(echo "$exclude_desc" | xargs) # Trim whitespace
      if [ -n "$hint" ] && [[ "$hint" == *"$exclude_desc"* ]]; then
        return 0
      fi
    done
  fi

  return 1
}

# Function to process a single service principal
process_service_principal() {
  local sp_id="$1"
  local sp_name="$2"
  local app_id="$3"
  local current_num="$4"
  local total_num="$5"

  echo "[$current_num/$total_num] Processing: $sp_name"
  echo "  Service Principal ID: $sp_id"
  echo "  Application ID: $app_id"

  # Get current date in ISO format
  CURRENT_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Get all credentials with full details for filtering
  ALL_CREDENTIALS=$(az ad app credential list --id "$app_id" -o json 2>/dev/null)
  if [ "$ALL_CREDENTIALS" = "[]" ] || [ -z "$ALL_CREDENTIALS" ]; then
    echo "  No credentials found"
    return 0
  fi

  # Process credentials and build list of expired ones to delete
  local keys_to_delete=""
  local excluded_count=0
  local expired_count=0
  local total_creds=0

  # Count total credentials
  total_creds=$(echo "$ALL_CREDENTIALS" | jq length)
  echo "  Total credentials: $total_creds"

  # Process each credential
  while IFS= read -r credential; do
    if [ -z "$credential" ]; then continue; fi

    # Decode the base64 encoded JSON
    DECODED=$(echo "$credential" | base64 --decode 2>/dev/null)
    if [ $? -ne 0 ]; then continue; fi

    # Extract fields
    KEY_ID=$(echo "$DECODED" | jq -r '.keyId // empty')
    DISPLAY_NAME=$(echo "$DECODED" | jq -r '.displayName // empty')
    HINT=$(echo "$DECODED" | jq -r '.hint // empty')
    END_DATE=$(echo "$DECODED" | jq -r '.endDateTime // empty')

    # Check if expired
    if [ -n "$END_DATE" ] && [[ "$END_DATE" < "$CURRENT_DATE" ]]; then
      # Check if should be excluded
      if should_exclude "$DISPLAY_NAME" "$HINT"; then
        echo "    Skipping expired token (excluded): $DISPLAY_NAME"
        excluded_count=$((excluded_count + 1))
      else
        echo "    Found expired token: $DISPLAY_NAME (Expires: $END_DATE)"
        expired_count=$((expired_count + 1))
        if [ -z "$keys_to_delete" ]; then
          keys_to_delete="$KEY_ID"
        else
          keys_to_delete="$keys_to_delete $KEY_ID"
        fi
      fi
    fi
  done < <(echo "$ALL_CREDENTIALS" | jq -r '.[] | @base64')

  # Summary for this service principal
  echo "  Summary: $expired_count expired (to delete), $excluded_count excluded"

  # Delete expired secrets if any
  if [ -n "$keys_to_delete" ]; then
    if [ "$DRY_RUN" = "true" ]; then
      echo "  DRY RUN: Would delete $expired_count expired secrets"
    else
      echo "  Deleting $expired_count expired secrets..."
      for KEY_ID in $keys_to_delete; do
        if az ad app credential delete --id "$app_id" --key-id "$KEY_ID" >/dev/null 2>&1; then
          echo "    Deleted secret: $KEY_ID"
        else
          echo "    Failed to delete secret: $KEY_ID"
        fi
      done
    fi
  else
    echo "  No expired secrets to delete"
  fi

  # Return counts for global summary
  echo "$expired_count $excluded_count $total_creds"
}

# Check for Azure authentication
if [ -n "$AZURE_CLIENT_ID" ] && [ -n "$AZURE_CLIENT_SECRET" ] && [ -n "$AZURE_TENANT_ID" ]; then
  echo "Logging in with service principal..."
  az login --service-principal -u "$AZURE_CLIENT_ID" -p "$AZURE_CLIENT_SECRET" --tenant "$AZURE_TENANT_ID" >/dev/null
elif [ -d "/root/.azure" ]; then
  echo "Using mounted Azure credentials..."
else
  echo "Error: No Azure authentication found."
  echo "Either:"
  echo "1. Mount your Azure config: -v ~/.azure:/root/.azure"
  echo "2. Or provide service principal credentials:"
  echo "   -e AZURE_CLIENT_ID=xxx -e AZURE_CLIENT_SECRET=xxx -e AZURE_TENANT_ID=xxx"
  exit 1
fi

echo "Fetching all service principals..."
# Get all service principals with their associated application IDs
SERVICE_PRINCIPALS=$(az ad sp list --all --query '[?appId != null].{id:id, displayName:displayName, appId:appId}' -o json)
if [ "$SERVICE_PRINCIPALS" = "[]" ] || [ -z "$SERVICE_PRINCIPALS" ]; then
  echo "No service principals found or insufficient permissions"
  exit 1
fi

TOTAL_SPS=$(echo "$SERVICE_PRINCIPALS" | jq length)
echo "Found $TOTAL_SPS service principals to process"

# Global counters
GLOBAL_TOTAL_EXPIRED=0
GLOBAL_TOTAL_EXCLUDED=0
GLOBAL_TOTAL_CREDENTIALS=0
GLOBAL_PROCESSED=0

# Create a temporary directory for parallel processing
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Process service principals
echo ""
echo "Starting processing..."

# Process in batches of 5
batch_size=5
pids=()

# Read each service principal and process in batches
echo "$SERVICE_PRINCIPALS" | jq -c '.[]' | while read -r sp_data; do
  if [ -z "$sp_data" ]; then continue; fi

  SP_ID=$(echo "$sp_data" | jq -r '.id')
  SP_NAME=$(echo "$sp_data" | jq -r '.displayName')
  APP_ID=$(echo "$sp_data" | jq -r '.appId')

  GLOBAL_PROCESSED=$((GLOBAL_PROCESSED + 1))

  # Process in background with concurrency control
  (
    result=$(process_service_principal "$SP_ID" "$SP_NAME" "$APP_ID" "$GLOBAL_PROCESSED" "$TOTAL_SPS" 2>&1)
    echo "$result" >"$TEMP_DIR/result_${GLOBAL_PROCESSED}.txt"
  ) &
  pids+=($!)

  # Wait if we've reached the batch size
  if [ $((GLOBAL_PROCESSED % batch_size)) -eq 0 ]; then
    wait
    # Collect results from this batch
    for i in $(seq $((GLOBAL_PROCESSED - batch_size + 1)) $GLOBAL_PROCESSED); do
      if [ -f "$TEMP_DIR/result_${i}.txt" ]; then
        cat "$TEMP_DIR/result_${i}.txt"
        # Extract counts from the last line if it contains numbers
        last_line=$(tail -n 1 "$TEMP_DIR/result_${i}.txt")
        if [[ $last_line =~ ^[0-9]+\ [0-9]+\ [0-9]+$ ]]; then
          expired=$(echo "$last_line" | cut -d' ' -f1)
          excluded=$(echo "$last_line" | cut -d' ' -f2)
          total=$(echo "$last_line" | cut -d' ' -f3)
          GLOBAL_TOTAL_EXPIRED=$((GLOBAL_TOTAL_EXPIRED + expired))
          GLOBAL_TOTAL_EXCLUDED=$((GLOBAL_TOTAL_EXCLUDED + excluded))
          GLOBAL_TOTAL_CREDENTIALS=$((GLOBAL_TOTAL_CREDENTIALS + total))
        fi
      fi
    done
  fi
done

# Wait for any remaining background processes
wait

echo ""
echo "BULK CLEANUP COMPLETED!"
echo "FINAL SUMMARY:"
echo "  Service Principals Processed: $GLOBAL_PROCESSED"
echo "  Total Credentials Found: $GLOBAL_TOTAL_CREDENTIALS"
echo "  Total Expired Credentials: $((GLOBAL_TOTAL_EXPIRED + GLOBAL_TOTAL_EXCLUDED))"
echo "  Expired Credentials Deleted: $GLOBAL_TOTAL_EXPIRED"
echo "  Expired Credentials Excluded: $GLOBAL_TOTAL_EXCLUDED"

if [ "$DRY_RUN" = "true" ]; then
  echo "  DRY RUN: No actual deletions were performed"
fi

# Cleanup
rm -rf "$TEMP_DIR"
