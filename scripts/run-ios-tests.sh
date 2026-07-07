#!/usr/bin/env bash
set -euo pipefail

phase="${1:-all}"

PROJECT="${PROJECT:-${XCODE_PROJECT:-SSHApp.xcodeproj}}"
SCHEME="${SCHEME:-${XCODE_SCHEME:-SSHApp}}"
XCODEBUILD="${XCODEBUILD:-xcodebuild}"
XCODE_SOURCE_PACKAGES_PATH="${XCODE_SOURCE_PACKAGES_PATH:-.build/ci/xcode-source-packages}"
XCODE_DERIVED_DATA_PATH="${XCODE_DERIVED_DATA_PATH:-.build/ci/xcode-derived-data}"
XCODE_RESULT_BUNDLE_PATH="${XCODE_RESULT_BUNDLE_PATH:-.build/ci/xcresults}"
UI_SIMULATOR_NAME="${UI_SIMULATOR_NAME:-SSHApp UI Tests}"
UI_TEST_ATTEMPTS="${UI_TEST_ATTEMPTS:-2}"

mkdir -p "$XCODE_SOURCE_PACKAGES_PATH" "$XCODE_DERIVED_DATA_PATH" "$XCODE_RESULT_BUNDLE_PATH"

common_xcodebuild_args=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -clonedSourcePackagesDirPath "$PWD/$XCODE_SOURCE_PACKAGES_PATH"
  -derivedDataPath "$PWD/$XCODE_DERIVED_DATA_PATH"
  -skipPackagePluginValidation
  -skipMacroValidation
)

resolve_default_destination() {
  if [[ -n "${XCODE_DESTINATION:-}" ]]; then
    printf '%s\n' "$XCODE_DESTINATION"
  else
    python3 ./scripts/resolve-ios-simulator.py
  fi
}

resolve_ui_destination() {
  if [[ -n "${XCODE_DESTINATION:-}" ]]; then
    printf '%s\n' "$XCODE_DESTINATION"
  else
    local udid
    udid="$(python3 ./scripts/resolve-ios-simulator.py \
      --name "$UI_SIMULATOR_NAME" \
      --dedicated \
      --erase \
      --boot \
      --udid-only)"
    printf 'platform=iOS Simulator,id=%s\n' "$udid"
  fi
}

run_test_target() {
  local label="$1"
  local target="$2"
  local destination="$3"
  local result_bundle="$4"

  rm -rf "$result_bundle"
  echo "Running $label on $destination"
  "$XCODEBUILD" test \
    "${common_xcodebuild_args[@]}" \
    -destination "$destination" \
    -only-testing:"$target" \
    -resultBundlePath "$result_bundle"
}

run_unit_tests() {
  local destination
  destination="$(resolve_default_destination)"
  run_test_target \
    "unit tests" \
    "SSHAppTests" \
    "$destination" \
    "$XCODE_RESULT_BUNDLE_PATH/unit-tests.xcresult"
}

run_ui_tests() {
  local attempt destination result_bundle
  for attempt in $(seq 1 "$UI_TEST_ATTEMPTS"); do
    destination="$(resolve_ui_destination)"
    result_bundle="$XCODE_RESULT_BUNDLE_PATH/ui-tests-attempt-${attempt}.xcresult"

    if run_test_target "UI tests attempt $attempt/$UI_TEST_ATTEMPTS" "SSHAppUITests" "$destination" "$result_bundle"; then
      return 0
    fi

    if [[ "$attempt" -lt "$UI_TEST_ATTEMPTS" ]]; then
      echo "UI tests failed on attempt $attempt; retrying with a fresh simulator."
    fi
  done

  return 1
}

case "$phase" in
  all)
    run_unit_tests
    run_ui_tests
    ;;
  unit)
    run_unit_tests
    ;;
  ui)
    run_ui_tests
    ;;
  *)
    echo "usage: $0 [all|unit|ui]" >&2
    exit 2
    ;;
esac
