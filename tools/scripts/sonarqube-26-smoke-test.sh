#!/usr/bin/env bash

set -euo pipefail

readonly SONARQUBE_IMAGE="${SONARQUBE_IMAGE:-sonarqube:26.10.0.133078-community}"
readonly PLUGIN_JAR="${PLUGIN_JAR:-sonar-flutter-plugin/target/sonar-flutter-plugin-0.6.0-riverfold-SNAPSHOT.jar}"
readonly CONTAINER_NAME="sonar-flutter-smoke-$$"
readonly STARTUP_TIMEOUT_SECONDS="${STARTUP_TIMEOUT_SECONDS:-180}"
readonly ADMIN_CREDENTIALS="admin:admin"
readonly DART_PROJECT_KEY="sonar-flutter-dart-coverage"
readonly DART_FIXTURE_DIR="${DART_FIXTURE_DIR:-tools/fixtures/dart-coverage}"
readonly DART_EXECUTABLE="${DART_EXECUTABLE:-dart}"
readonly EXPECTED_DART_VERSION="${EXPECTED_DART_VERSION:-3.13.7}"
readonly FLUTTER_PROJECT_KEY="sonar-flutter-integration"
readonly FLUTTER_FIXTURE_DIR="${FLUTTER_FIXTURE_DIR:-tools/fixtures/flutter}"
readonly FLUTTER_EXECUTABLE="${FLUTTER_EXECUTABLE:-flutter}"
readonly EXPECTED_FLUTTER_VERSION="${EXPECTED_FLUTTER_VERSION:-3.47.9}"

container_started=false
temporary_directories=()

cleanup() {
  if [[ "${container_started}" == "true" ]]; then
    docker rm --force "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  fi
  local temporary_directory
  for temporary_directory in "${temporary_directories[@]}"; do
    [[ -d "${temporary_directory}" ]] && rm -rf -- "${temporary_directory}"
  done
}

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  if [[ "${container_started}" == "true" ]]; then
    docker logs "${CONTAINER_NAME}" >&2 || true
  fi
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

wait_for_sonarqube() {
  local base_url="$1"
  local deadline=$((SECONDS + STARTUP_TIMEOUT_SECONDS))
  local response

  while ((SECONDS < deadline)); do
    response="$(curl --fail --silent --user "${ADMIN_CREDENTIALS}" \
      "${base_url}/api/system/status" 2>/dev/null || true)"
    if jq --exit-status '.status == "UP"' <<<"${response}" >/dev/null 2>&1; then
      return 0
    fi

    if [[ "$(docker inspect --format '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null || true)" != "true" ]]; then
      fail "SonarQube container stopped before becoming ready"
    fi

    sleep 2
  done

  fail "SonarQube did not become ready within ${STARTUP_TIMEOUT_SECONDS} seconds"
}

assert_plugin_loaded() {
  local base_url="$1"
  local plugins
  local languages

  plugins="$(curl --fail --silent --user "${ADMIN_CREDENTIALS}" \
    "${base_url}/api/plugins/installed")" \
    || fail "Unable to query installed plugins"
  jq --exit-status '.plugins[] | select(.key == "flutter")' <<<"${plugins}" >/dev/null \
    || fail "Flutter plugin is not listed as installed"

  languages="$(curl --fail --silent --user "${ADMIN_CREDENTIALS}" \
    "${base_url}/api/languages/list")" \
    || fail "Unable to query recognised languages"
  jq --exit-status '.languages[] | select(.key == "dart" and .name == "Dart")' \
    <<<"${languages}" >/dev/null \
    || fail "Dart is not listed as a recognised language"
}

assert_no_known_startup_failure() {
  local logs

  logs="$(docker logs "${CONTAINER_NAME}" 2>&1)"
  if grep -Eiq \
    'BeanDefinitionOverrideException|sonar\.dart\.file\.suffixes.*(already|duplicate)|Could not load plugin.*flutter' \
    <<<"${logs}"; then
    fail "SonarQube logs contain a known plugin startup failure"
  fi
}

sonarqube_base_url() {
  local host_port

  host_port="$(docker port "${CONTAINER_NAME}" 9000/tcp | awk -F: 'NR == 1 {print $NF}')"
  [[ -n "${host_port}" ]] || fail "Unable to determine the allocated SonarQube port"
  printf 'http://127.0.0.1:%s' "${host_port}"
}

generate_analysis_token() {
  local base_url="$1"
  local token_name="$2"
  local response

  response="$(curl --fail --silent --user "${ADMIN_CREDENTIALS}" \
    --request POST \
    --data-urlencode "name=${token_name}" \
    "${base_url}/api/user_tokens/generate")" \
    || fail "Unable to generate an analysis token"
  jq --exit-status --raw-output '.token | select(length > 0)' <<<"${response}" \
    || fail "SonarQube did not return an analysis token"
}

wait_for_analysis() {
  local base_url="$1"
  local analysis_token="$2"
  local task_id="$3"
  local deadline=$((SECONDS + STARTUP_TIMEOUT_SECONDS))
  local response
  local status

  while ((SECONDS < deadline)); do
    response="$(curl --fail --silent --user "${analysis_token}:" \
      --get --data-urlencode "id=${task_id}" "${base_url}/api/ce/task")" \
      || fail "Unable to query analysis task ${task_id}"
    status="$(jq --raw-output '.task.status // empty' <<<"${response}")"

    case "${status}" in
      SUCCESS)
        return 0
        ;;
      FAILED | CANCELED)
        fail "Analysis task ${task_id} finished with status ${status}: $(jq --raw-output '.task.errorMessage // "No error message"' <<<"${response}")"
        ;;
    esac

    sleep 2
  done

  fail "Analysis task ${task_id} did not finish within ${STARTUP_TIMEOUT_SECONDS} seconds"
}

assert_dart_analysis_results() {
  local base_url="$1"
  local analysis_token="$2"
  local components
  local classifier_key
  local issues
  local measures

  components="$(curl --fail --silent --user "${analysis_token}:" \
    --get \
    --data-urlencode "component=${DART_PROJECT_KEY}" \
    --data-urlencode "qualifiers=FIL" \
    "${base_url}/api/components/tree")" \
    || fail "Unable to query analysed files"
  jq --exit-status \
    '.components[] | select(.path == "lib/classifier.dart" and .language == "dart" and .qualifier == "FIL")' \
    <<<"${components}" >/dev/null \
    || fail "The fixture source was not indexed as Dart"
  jq --exit-status \
    '.components[] | select(.path == "lib/analyzer_fixture.dart" and .language == "dart" and .qualifier == "FIL")' \
    <<<"${components}" >/dev/null \
    || fail "The analyzer fixture was not indexed as Dart"
  classifier_key="$(jq --raw-output \
    '.components[] | select(.path == "lib/classifier.dart") | .key' <<<"${components}")"
  [[ -n "${classifier_key}" ]] || fail "Unable to determine the classifier component key"

  measures="$(curl --fail --silent --user "${analysis_token}:" \
    --get \
    --data-urlencode "component=${classifier_key}" \
    --data-urlencode "metricKeys=coverage,line_coverage,lines_to_cover,uncovered_lines" \
    "${base_url}/api/measures/component")" \
    || fail "Unable to query coverage measures"
  jq --exit-status \
    '.component.measures | any(.metric == "lines_to_cover" and .value == "3")' \
    <<<"${measures}" >/dev/null \
    || fail "Expected three lines to cover"
  jq --exit-status \
    '.component.measures | any(.metric == "uncovered_lines" and .value == "1")' \
    <<<"${measures}" >/dev/null \
    || fail "Expected one uncovered line"
  jq --exit-status \
    '.component.measures | any(.metric == "line_coverage" and .value == "66.7")' \
    <<<"${measures}" >/dev/null \
    || fail "Expected line coverage of 66.7 percent"

  issues="$(curl --fail --silent --user "${analysis_token}:" \
    --get \
    --data-urlencode "componentKeys=${DART_PROJECT_KEY}" \
    --data-urlencode "rules=dartanalyzer:avoid_print" \
    "${base_url}/api/issues/search")" \
    || fail "Unable to query imported Dart analyzer issues"
  jq --exit-status \
    '.total == 1 and (.issues[0].component | endswith(":lib/analyzer_fixture.dart")) and .issues[0].line == 2' \
    <<<"${issues}" >/dev/null \
    || fail "Expected one avoid_print issue on analyzer_fixture.dart line 2"
}

assert_dart_version() {
  local version

  version="$("${DART_EXECUTABLE}" --version 2>&1)" \
    || fail "Unable to run Dart executable: ${DART_EXECUTABLE}"
  grep -Fq "Dart SDK version: ${EXPECTED_DART_VERSION}" <<<"${version}" \
    || fail "Expected Dart ${EXPECTED_DART_VERSION}, found: ${version}"
}

run_dart_analyzer() {
  local fixture_dir="$1"
  local report_path="$2"

  "${DART_EXECUTABLE}" analyze --format=machine "${fixture_dir}" >"${report_path}" 2>&1 || true
  grep -Eq \
    '^[A-Z]+\|LINT\|AVOID_PRINT\|.*analyzer_fixture\.dart\|2\|3\|[0-9]+\|' \
    "${report_path}" \
    || fail "Dart analyzer did not report the expected avoid_print finding"
}

run_dart_fixture_analysis() {
  local base_url="$1"
  local fixture_dir="$2"
  local analysis_token
  local analyzer_report
  local scanner_work_dir
  local sonar_work_dir
  local task_id

  analysis_token="$(generate_analysis_token "${base_url}" "sonar-flutter-dart-smoke-$$")"
  scanner_work_dir="$(mktemp -d "${TMPDIR:-/tmp}/sonar-flutter-dart-e2e.XXXXXX")"
  temporary_directories+=("${scanner_work_dir}")
  analyzer_report="${scanner_work_dir}/dart-analyzer-machine.txt"
  sonar_work_dir="${scanner_work_dir}/scanner"
  run_dart_analyzer "${fixture_dir}" "${analyzer_report}"

  sonar-scanner \
    -Dsonar.host.url="${base_url}" \
    -Dsonar.token="${analysis_token}" \
    -Dsonar.projectKey="${DART_PROJECT_KEY}" \
    -Dsonar.projectName="Sonar Flutter Dart coverage fixture" \
    -Dsonar.projectBaseDir="${fixture_dir}" \
    -Dsonar.working.directory="${sonar_work_dir}" \
    -Dsonar.sources="lib,pubspec.yaml" \
    -Dsonar.sourceEncoding=UTF-8 \
    -Dsonar.scm.disabled=true \
    -Dsonar.dart.analyzer.mode=MANUAL \
    -Dsonar.dart.analyzer.report.mode=MACHINE \
    -Dsonar.dart.analyzer.report.path="${analyzer_report}" \
    -Dsonar.dart.analyzer.options.override=false \
    -Dsonar.flutter.tests.reportPath="${fixture_dir}/test-results.txt" \
    -Dsonar.flutter.coverage.reportPath=coverage/lcov.info

  [[ -f "${sonar_work_dir}/report-task.txt" ]] \
    || fail "SonarScanner did not create report-task.txt"
  task_id="$(awk -F= '$1 == "ceTaskId" {print $2}' "${sonar_work_dir}/report-task.txt")"
  [[ -n "${task_id}" ]] || fail "SonarScanner did not report a compute-engine task ID"

  wait_for_analysis "${base_url}" "${analysis_token}" "${task_id}"
  assert_dart_analysis_results "${base_url}" "${analysis_token}"
}

assert_flutter_version() {
  local version

  version="$("${FLUTTER_EXECUTABLE}" --version 2>&1)" \
    || fail "Unable to run Flutter executable: ${FLUTTER_EXECUTABLE}"
  grep -Fq "Flutter ${EXPECTED_FLUTTER_VERSION}" <<<"${version}" \
    || fail "Expected Flutter ${EXPECTED_FLUTTER_VERSION}, found: ${version}"
}

assert_flutter_analysis_results() {
  local base_url="$1"
  local analysis_token="$2"
  local components
  local greeting_key
  local issues
  local measures
  local test_measures

  components="$(curl --fail --silent --user "${analysis_token}:" \
    --get \
    --data-urlencode "component=${FLUTTER_PROJECT_KEY}" \
    --data-urlencode "ps=500" \
    "${base_url}/api/components/tree")" \
    || fail "Unable to query analysed Flutter files"
  jq --exit-status \
    '.components[] | select(.path == "lib/greeting.dart" and .language == "dart")' \
    <<<"${components}" >/dev/null \
    || fail "The Flutter source was not indexed as Dart"
  jq --exit-status \
    '.components[] | select(.path == "test/greeting_test.dart" and .language == "dart")' \
    <<<"${components}" >/dev/null \
    || fail "The Flutter test was not indexed as Dart"
  greeting_key="$(jq --raw-output \
    '.components[] | select(.path == "lib/greeting.dart") | .key' <<<"${components}")"
  [[ -n "${greeting_key}" ]] || fail "Unable to determine the Flutter source component key"

  measures="$(curl --fail --silent --user "${analysis_token}:" \
    --get \
    --data-urlencode "component=${greeting_key}" \
    --data-urlencode "metricKeys=coverage,line_coverage,lines_to_cover,uncovered_lines" \
    "${base_url}/api/measures/component")" \
    || fail "Unable to query Flutter coverage measures"
  jq --exit-status \
    '.component.measures | any(.metric == "lines_to_cover" and (.value | tonumber) == 3)' \
    <<<"${measures}" >/dev/null \
    || fail "Expected three Flutter lines to cover"
  jq --exit-status \
    '.component.measures | any(.metric == "uncovered_lines" and (.value | tonumber) == 0)' \
    <<<"${measures}" >/dev/null \
    || fail "Expected no uncovered Flutter lines"
  jq --exit-status \
    '.component.measures | any(.metric == "line_coverage" and (.value | tonumber) == 100)' \
    <<<"${measures}" >/dev/null \
    || fail "Expected Flutter line coverage of 100 percent"

  issues="$(curl --fail --silent --user "${analysis_token}:" \
    --get \
    --data-urlencode "componentKeys=${FLUTTER_PROJECT_KEY}" \
    --data-urlencode "rules=dartanalyzer:avoid_print" \
    "${base_url}/api/issues/search")" \
    || fail "Unable to query imported Flutter analyzer issues"
  jq --exit-status \
    '.total == 1 and (.issues[0].component | endswith(":lib/greeting.dart")) and .issues[0].line == 8' \
    <<<"${issues}" >/dev/null \
    || fail "Expected one avoid_print issue on greeting.dart line 8"

  test_measures="$(curl --fail --silent --user "${analysis_token}:" \
    --get \
    --data-urlencode "component=${FLUTTER_PROJECT_KEY}" \
    --data-urlencode "metricKeys=tests,test_errors,test_failures,skipped_tests,test_execution_time" \
    "${base_url}/api/measures/component")" \
    || fail "Unable to query Flutter test measures"
  jq --exit-status \
    '.component.measures | any(.metric == "tests" and (.value | tonumber) == 1)' \
    <<<"${test_measures}" >/dev/null \
    || fail "Expected one imported Flutter test"
  jq --exit-status \
    '.component.measures | any(.metric == "test_errors" and (.value | tonumber) == 0)' \
    <<<"${test_measures}" >/dev/null \
    || fail "Expected no Flutter test errors"
  jq --exit-status \
    '.component.measures | any(.metric == "test_failures" and (.value | tonumber) == 0)' \
    <<<"${test_measures}" >/dev/null \
    || fail "Expected no Flutter test failures"
  jq --exit-status \
    '.component.measures | any(.metric == "skipped_tests" and (.value | tonumber) == 0)' \
    <<<"${test_measures}" >/dev/null \
    || fail "Expected no skipped Flutter tests"
  jq --exit-status \
    '.component.measures | any(.metric == "test_execution_time" and (.value | tonumber) > 0)' \
    <<<"${test_measures}" >/dev/null \
    || fail "Expected a positive Flutter test execution time"
}

run_flutter_fixture_analysis() {
  local base_url="$1"
  local fixture_dir="$2"
  local analysis_token
  local analyzer_report
  local flutter_bin_dir
  local flutter_project_dir
  local flutter_work_dir
  local sonar_work_dir
  local task_id

  analysis_token="$(generate_analysis_token "${base_url}" "sonar-flutter-integration-smoke-$$")"
  flutter_work_dir="$(mktemp -d "${TMPDIR:-/tmp}/sonar-flutter-integration.XXXXXX")"
  temporary_directories+=("${flutter_work_dir}")
  flutter_project_dir="${flutter_work_dir}/project"
  sonar_work_dir="${flutter_work_dir}/scanner"
  analyzer_report="${flutter_work_dir}/flutter-analyzer.txt"
  mkdir -p "${flutter_project_dir}"
  cp -R "${fixture_dir}/." "${flutter_project_dir}/"

  (cd "${flutter_project_dir}" && "${FLUTTER_EXECUTABLE}" pub get)
  (cd "${flutter_project_dir}" && \
    "${FLUTTER_EXECUTABLE}" analyze --no-fatal-warnings --no-fatal-infos) \
    >"${analyzer_report}" 2>&1 || true
  grep -Eq \
    'info.*avoid_print' \
    "${analyzer_report}" \
    || fail "Flutter analyzer did not report the expected avoid_print finding"
  (cd "${flutter_project_dir}" && \
    "${FLUTTER_EXECUTABLE}" test --machine --coverage) \
    >"${flutter_project_dir}/tests.output" \
    || fail "Flutter fixture tests failed"
  [[ -f "${flutter_project_dir}/coverage/lcov.info" ]] \
    || fail "Flutter did not generate an LCOV report"
  grep -Fq '"name":"shows the greeting"' "${flutter_project_dir}/tests.output" \
    || fail "Flutter machine test output does not contain the expected test"

  flutter_bin_dir="$(cd "$(dirname "$(command -v "${FLUTTER_EXECUTABLE}")")" && pwd)"
  PATH="${flutter_bin_dir}:${PATH}" sonar-scanner \
    -Dsonar.host.url="${base_url}" \
    -Dsonar.token="${analysis_token}" \
    -Dsonar.projectKey="${FLUTTER_PROJECT_KEY}" \
    -Dsonar.projectName="Sonar Flutter integration fixture" \
    -Dsonar.projectBaseDir="${flutter_project_dir}" \
    -Dsonar.working.directory="${sonar_work_dir}" \
    -Dsonar.sources="lib,pubspec.yaml" \
    -Dsonar.tests=test \
    -Dsonar.sourceEncoding=UTF-8 \
    -Dsonar.scm.disabled=true \
    -Dsonar.dart.analyzer.mode=FLUTTER \
    -Dsonar.dart.analyzer.report.mode=LEGACY \
    -Dsonar.dart.analyzer.options.override=false \
    -Dsonar.flutter.tests.reportPath="${flutter_project_dir}/tests.output" \
    -Dsonar.flutter.coverage.reportPath="${flutter_project_dir}/coverage/lcov.info"

  [[ -f "${sonar_work_dir}/report-task.txt" ]] \
    || fail "SonarScanner did not create the Flutter report-task.txt"
  task_id="$(awk -F= '$1 == "ceTaskId" {print $2}' "${sonar_work_dir}/report-task.txt")"
  [[ -n "${task_id}" ]] || fail "SonarScanner did not report a Flutter compute-engine task ID"

  wait_for_analysis "${base_url}" "${analysis_token}" "${task_id}"
  assert_flutter_analysis_results "${base_url}" "${analysis_token}"
}

require_command curl
require_command docker
require_command jq
require_command mvn
require_command sonar-scanner
require_command "${DART_EXECUTABLE}"
require_command "${FLUTTER_EXECUTABLE}"

assert_dart_version
assert_flutter_version

trap cleanup EXIT INT TERM

printf 'Building plugin...\n'
mvn --quiet clean package

[[ -f "${PLUGIN_JAR}" ]] || fail "Plugin JAR not found: ${PLUGIN_JAR}"
PLUGIN_JAR_ABSOLUTE="$(cd "$(dirname "${PLUGIN_JAR}")" && pwd)/$(basename "${PLUGIN_JAR}")"
readonly PLUGIN_JAR_ABSOLUTE
DART_FIXTURE_DIR_ABSOLUTE="$(cd "${DART_FIXTURE_DIR}" && pwd)"
readonly DART_FIXTURE_DIR_ABSOLUTE
FLUTTER_FIXTURE_DIR_ABSOLUTE="$(cd "${FLUTTER_FIXTURE_DIR}" && pwd)"
readonly FLUTTER_FIXTURE_DIR_ABSOLUTE

printf 'Starting isolated SonarQube container %s...\n' "${CONTAINER_NAME}"
docker run --detach \
  --name "${CONTAINER_NAME}" \
  --publish 127.0.0.1::9000 \
  --volume "${PLUGIN_JAR_ABSOLUTE}:/opt/sonarqube/extensions/plugins/sonar-flutter-plugin.jar:ro" \
  "${SONARQUBE_IMAGE}" >/dev/null
container_started=true

BASE_URL="$(sonarqube_base_url)"

printf 'Waiting for first startup at %s...\n' "${BASE_URL}"
wait_for_sonarqube "${BASE_URL}"
assert_plugin_loaded "${BASE_URL}"
assert_no_known_startup_failure

printf 'Restarting isolated SonarQube container...\n'
docker restart "${CONTAINER_NAME}" >/dev/null
BASE_URL="$(sonarqube_base_url)"
wait_for_sonarqube "${BASE_URL}"
assert_plugin_loaded "${BASE_URL}"
assert_no_known_startup_failure

printf 'Analysing Dart coverage fixture...\n'
run_dart_fixture_analysis "${BASE_URL}" "${DART_FIXTURE_DIR_ABSOLUTE}"

printf 'Analysing Flutter integration fixture...\n'
run_flutter_fixture_analysis "${BASE_URL}" "${FLUTTER_FIXTURE_DIR_ABSOLUTE}"

printf 'SonarQube 26.10 plugin, Dart and Flutter integration smoke test passed.\n'
