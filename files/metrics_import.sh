#!/bin/bash
set -o pipefail
shopt -s nullglob

# ---------------------------
# Config
# ---------------------------
SEND_SLACK=true                 # set to false to disable Slack posting
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"  # must come from environment when SEND_SLACK=true

# ---------------------------
# Helpers
# ---------------------------
slack_post() {
  # Usage: slack_post "message"
  local msg="$1"

  # Only post if enabled and webhook present
  [[ "$SEND_SLACK" == "true" ]] || return 0
  [[ -n "$SLACK_WEBHOOK_URL" ]] || return 0

  # Minimal JSON escaping for double-quotes, plus newlines -> \n
  local esc="${msg//\\/\\\\}"
  esc="${esc//\"/\\\"}"
  esc="${esc//$'\n'/\\n}"

  curl -sS -X POST -H 'Content-type: application/json' \
    --data "{\"text\":\"$esc\"}" \
    "$SLACK_WEBHOOK_URL" >/dev/null 2>&1 || true
}

log() {
  # Usage: log "message"
  local msg="$1"
  echo "$msg"
  slack_post "$msg"
}

# ---------------------------
# Main
# ---------------------------
for f in /opt/mft-automations/puppet_enterprise_support*gz \
         /opt/mft-automations/puppet_enterprise_support*gz.gpg \
         /opt/mft-automations/puppet_enterprise_support*tar \
         /opt/mft-automations/puppet_enterprise_support*tar.gz; do

  # Does the file have a 5 digit ticket number after puppet_enterprise_support_
  has_ticket=$(echo "$f" | grep -Eo -- 'puppet_enterprise_support_[[:digit:]]+_')

  if [[ $(find "$f" -mmin -2 2>/dev/null) ]]; then
    log "INFO: $f is still downloading (mtime < 2 minutes). Skipping..."
    continue
  fi

  if ! [[ $has_ticket ]]; then
    log "ERROR: no ticket ID found in $f"
    mv "$f" /opt/mft-automations/err
    continue
  fi

  if [[ "${f##*.}" == 'gpg' ]]; then
    # Decrypt the file to the same location as the source, stripping the .gpg suffix
    # Delete source file if it decrypts ok, otherwise move it to err/
    if cat /root/.support_gpg | gpg --pinentry-mode loopback --passphrase-fd 0 --batch --yes --output "${f%.*}" --decrypt "$f"; then
      rm -- "$f"
      f="${f%.*}"
    else
      log "ERROR: failed to decrypt $f"
      mv "$f" /opt/mft-automations/err
      continue
    fi
  fi

  if ! tar tf "$f" | grep -q -m 1 'metrics\/.*json'; then
    log "No metrics found in $f.  Skipping"
    rm -- "$f"
    continue
  fi

  # Strip the trailing _, then everything up to the last _ to get just the number
  ticket="${has_ticket%_}"
  ticket="${ticket##*_}"

  _tmp="$(mktemp)"
  /opt/puppetlabs/bolt/bin/bolt plan run puppet_operational_dashboards::load_metrics \
    --targets localhost --run-as root influxdb_bucket="$ticket" support_script_file="$f" \
    |& tee "$_tmp"

  if ! grep -q 'Wrote batch of [[:digit:]]* metrics' "$_tmp"; then
    log "ERROR: failed to import metrics from $f"
    mv "$f" /opt/mft-automations/err
    continue
  fi

  rm -- "$_tmp"
  rm -- "$f"
done

# Delete sup scripts older than 30 days
find /opt/mft-automations/err/ -type f -name "puppet_enterprise_support*gz" -mtime -30 -delete
