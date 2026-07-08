#!/usr/bin/env bash
set -euo pipefail

phase="${1:-all}"

PROJECT="${PROJECT:-${XCODE_PROJECT:-SSHApp.xcodeproj}}"
SCHEME="${SCHEME:-${XCODE_SCHEME:-SSHApp}}"
XCODEBUILD="${XCODEBUILD:-xcodebuild}"
XCODE_SOURCE_PACKAGES_PATH="${XCODE_SOURCE_PACKAGES_PATH:-.build/ci/xcode-source-packages}"
XCODE_DERIVED_DATA_PATH="${XCODE_DERIVED_DATA_PATH:-.build/ci/xcode-derived-data}"
XCODE_RESULT_BUNDLE_PATH="${XCODE_RESULT_BUNDLE_PATH:-.build/ci/xcresults}"
TEST_SIMULATOR_NAME="${TEST_SIMULATOR_NAME:-SSHApp Tests}"
ALL_TEST_PLAN="${ALL_TEST_PLAN:-SSHAppAllTests}"
UNIT_TEST_PLAN="${UNIT_TEST_PLAN:-SSHAppUnitTests}"
UI_TEST_PLAN="${UI_TEST_PLAN:-SSHAppUITests}"
UNIT_SIMULATOR_NAME="${UNIT_SIMULATOR_NAME:-SSHApp Unit Tests}"
UNIT_TEST_ATTEMPTS="${UNIT_TEST_ATTEMPTS:-2}"
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

resolve_dedicated_destination() {
  local simulator_name="$1"

  if [[ -n "${XCODE_DESTINATION:-}" ]]; then
    printf '%s\n' "$XCODE_DESTINATION"
  else
    local udid
    udid="$(python3 ./scripts/resolve-ios-simulator.py \
      --name "$simulator_name" \
      --dedicated \
      --erase \
      --boot \
      --udid-only)"
    printf 'platform=iOS Simulator,id=%s\n' "$udid"
  fi
}

resolve_unit_destination() {
  resolve_dedicated_destination "$UNIT_SIMULATOR_NAME"
}

resolve_ui_destination() {
  resolve_dedicated_destination "$UI_SIMULATOR_NAME"
}

build_for_testing() {
  local label="$1"
  local test_plan="$2"
  local destination="$3"
  local result_bundle="$4"

  rm -rf "$result_bundle"
  echo "Building $label on $destination"
  "$XCODEBUILD" build-for-testing \
    "${common_xcodebuild_args[@]}" \
    -destination "$destination" \
    -testPlan "$test_plan" \
    -resultBundlePath "$result_bundle"
}

run_test_plan() {
  local label="$1"
  local test_plan="$2"
  local destination="$3"
  local result_bundle="$4"

  rm -rf "$result_bundle"
  echo "Running $label on $destination"
  "$XCODEBUILD" test-without-building \
    "${common_xcodebuild_args[@]}" \
    -destination "$destination" \
    -testPlan "$test_plan" \
    -resultBundlePath "$result_bundle"
}

run_test_plan_with_retries() {
  local label="$1"
  local test_plan="$2"
  local simulator_name="$3"
  local attempts="$4"
  local result_prefix="$5"
  local destination="${6:-}"

  local attempt result_bundle
  for attempt in $(seq 1 "$attempts"); do
    if [[ -z "$destination" || ( "$attempt" -gt 1 && -z "${XCODE_DESTINATION:-}" ) ]]; then
      destination="$(resolve_dedicated_destination "$simulator_name")"
    fi

    result_bundle="$XCODE_RESULT_BUNDLE_PATH/${result_prefix}-attempt-${attempt}.xcresult"

    if run_test_plan "$label attempt $attempt/$attempts" "$test_plan" "$destination" "$result_bundle"; then
      return 0
    fi

    if [[ "$attempt" -lt "$attempts" ]]; then
      if [[ -n "${XCODE_DESTINATION:-}" ]]; then
        echo "$label failed on attempt $attempt; retrying on the configured destination."
      else
        echo "$label failed on attempt $attempt; retrying with a fresh simulator."
      fi
    fi
  done

  return 1
}

run_unit_tests() {
  local destination
  destination="$(resolve_unit_destination)"
  build_for_testing "unit test plan" "$UNIT_TEST_PLAN" "$destination" "$XCODE_RESULT_BUNDLE_PATH/unit-build-for-testing.xcresult"
  run_test_plan_with_retries "unit tests" "$UNIT_TEST_PLAN" "$UNIT_SIMULATOR_NAME" "$UNIT_TEST_ATTEMPTS" "unit-tests" "$destination"
}

run_ui_tests() {
  local destination
  destination="$(resolve_ui_destination)"
  build_for_testing "UI test plan" "$UI_TEST_PLAN" "$destination" "$XCODE_RESULT_BUNDLE_PATH/ui-build-for-testing.xcresult"
  run_test_plan_with_retries "UI tests" "$UI_TEST_PLAN" "$UI_SIMULATOR_NAME" "$UI_TEST_ATTEMPTS" "ui-tests" "$destination"
}

run_all_tests() {
  local destination
  destination="$(resolve_dedicated_destination "$TEST_SIMULATOR_NAME")"
  build_for_testing "all test plans" "$ALL_TEST_PLAN" "$destination" "$XCODE_RESULT_BUNDLE_PATH/all-build-for-testing.xcresult"
  run_test_plan_with_retries "unit tests" "$UNIT_TEST_PLAN" "$TEST_SIMULATOR_NAME" "$UNIT_TEST_ATTEMPTS" "unit-tests" "$destination"
  run_test_plan_with_retries "UI tests" "$UI_TEST_PLAN" "$TEST_SIMULATOR_NAME" "$UI_TEST_ATTEMPTS" "ui-tests" "$destination"
}

case "$phase" in
  all)
    run_all_tests
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
