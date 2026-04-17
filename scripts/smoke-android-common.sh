#!/usr/bin/env bash

android_smoke_provider_call() {
  local method="$1"
  shift
  "${ADB[@]}" shell content call \
    --uri "content://$ANDROID_APP_ID.debug.smoke" \
    --method "$method" \
    "$@" 2>/dev/null
}

android_smoke_write_file() {
  local file_name="$1"
  local file_value="$2"
  printf '%s' "$file_value" | "${ADB[@]}" shell "run-as $ANDROID_APP_ID sh -c 'cat > files/$file_name'" >/dev/null
}

android_smoke_delete_file() {
  local file_name="$1"
  "${ADB[@]}" shell "run-as $ANDROID_APP_ID sh -c 'rm -f files/$file_name'" >/dev/null 2>&1 || true
}

android_smoke_import_pairing() {
  local token="$1"
  local device_name="$2"
  local output
  output="$(android_smoke_provider_call "import_pairing" --arg "$token" --extra device_name:s:"$device_name")"
  [[ "$output" == *"result=1"* ]]
}

android_smoke_reset_probe() {
  local output
  output="$(android_smoke_provider_call "reset_probe")"
  [[ "$output" == *"result=1"* ]]
}

android_smoke_clear_pairing() {
  local output
  output="$(android_smoke_provider_call "clear_pairing")"
  [[ "$output" == *"result=1"* ]]
}
