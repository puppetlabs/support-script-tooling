#!/usr/bin/env bash
set -euo pipefail

# Configurable variables (defaults)

# REQUIRED API token INCLUDING the 'Bearer ' prefix, e.g. 'Bearer abc123...'
API_TOKEN="${API_TOKEN:-Bearer your_api_token_here}"

# OPTIONAL Base Forge API URL
FORGE_URI="${FORGE_URI:-https://forgeapi.puppet.com/}"

# OPTIONAL Module slug
MODULE_SLUG="${MODULE_SLUG:-puppetlabs-sce_linux}"

# OPTIONAL: where to place the downloaded file
OUT_DIR="${OUT_DIR:-.}"

# OPTIONAL: extra curl options (e.g., proxy, CA bundle, etc.)
CURL_OPTS=${CURL_OPTS:-}

# Helpers

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Error: required command '$1' not found in PATH." >&2
    exit 127
  }
}
# Validate API token (must not be the placeholder)
if [[ "${API_TOKEN}" == "Bearer your_api_token_here" ]]; then
  echo "You have not provided an API token. Please edit this script and add your API token to proceed." >&2
  exit 1
fi

join_url() {
  # join_url "https://forgeapi.puppet.com/" "/v3/modules/foo"
  local base="${1%/}"
  local path="$2"
  if [[ "$path" != /* ]]; then path="/$path"; fi
  printf '%s%s' "$base" "$path"
}

# Pre-flight

need curl
need jq

AUTH_HEADERS=(
  -H "authorization: ${API_TOKEN}"
  -H "x-authentication: ${API_TOKEN}"
)

MODULE_URL="$(join_url "$FORGE_URI" "v3/modules/${MODULE_SLUG}")"

echo "==> Querying module: ${MODULE_URL}"
module_json="$(
  curl -sS ${CURL_OPTS} \
    -X GET "$MODULE_URL" \
    "${AUTH_HEADERS[@]}"
)"

# Try to get the release URI from the module payload
release_uri="$(jq -r '.current_release.uri // empty' <<<"$module_json")"
if [[ -z "$release_uri" || "$release_uri" == "null" ]]; then
  echo "Error: Could not find .current_release.uri in module response." >&2
  exit 1
fi

RELEASE_URL="$(join_url "$FORGE_URI" "$release_uri")"
echo "==> Resolving release: ${RELEASE_URL}"
release_json="$(
  curl -sS ${CURL_OPTS} \
    -X GET "$RELEASE_URL" \
    "${AUTH_HEADERS[@]}"
)"

# Prefer file_uri from release JSON; fall back to module JSON if needed
file_uri="$(jq -r '.file_uri // empty' <<<"$release_json")"
if [[ -z "$file_uri" || "$file_uri" == "null" ]]; then
  file_uri="$(jq -r '.current_release.file_uri // empty' <<<"$module_json")"
fi
if [[ -z "$file_uri" || "$file_uri" == "null" ]]; then
  echo "Error: Could not find file_uri in release/module response." >&2
  exit 1
fi

FILE_URL="$(join_url "$FORGE_URI" "$file_uri")"
file_name="$(basename "$file_uri")"

mkdir -p "$OUT_DIR"
out_path="${OUT_DIR%/}/$file_name"

echo "==> Downloading binary: ${FILE_URL}"
echo "    -> Output file: ${out_path}"
# Binary download with verbose output (-v). Follow redirects (-L), fail on HTTP errors (--fail).
curl -L --fail --show-error -v ${CURL_OPTS} \
  "${AUTH_HEADERS[@]}" \
  -X GET "$FILE_URL" \
  -o "$out_path"

echo "Download complete: $out_path"