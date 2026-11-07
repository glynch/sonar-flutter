#!/usr/bin/env bash

set -euo pipefail

readonly SONARQUBE_IMAGE="${SONARQUBE_IMAGE:-sonarqube:26.10.0.133078-community}"
readonly PLUGIN_JAR="${PLUGIN_JAR:-sonar-flutter-plugin/target/sonar-flutter-plugin-0.5.2.jar}"
readonly CONTAINER_NAME="sonar-flutter-smoke-$$"
readonly STARTUP_TIMEOUT_SECONDS="${STARTUP_TIMEOUT_SECONDS:-180}"
readonly ADMIN_CREDENTIALS="admin:admin"
readonly PROJECT_KEY="sonar-flutter-dart-coverage"
readonly FIXTURE_DIR="${FIXTURE_DIR:-tools/fixtures/dart-coverage}"

container_started=false
scanner_work_dir=""

cleanup() {
  if [[ "${container_started}" == "true" ]]; then
    docker rm --force "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${scanner_work_dir}" && -d "${scanner_work_dir}" ]]; then
    rm -rf -- "${scanner_work_dir}"
  fi
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
  local response

  response="$(curl --fail --silent --user "${ADMIN_CREDENTIALS}" \
    --request POST \
    --data-urlencode "name=sonar-flutter-smoke-$$" \
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

assert_analysis_results() {
  local base_url="$1"
  local analysis_token="$2"
  local components
  local measures

  components="$(curl --fail --silent --user "${analysis_token}:" \
    --get \
    --data-urlencode "component=${PROJECT_KEY}" \
    --data-urlencode "qualifiers=FIL" \
    "${base_url}/api/components/tree")" \
    || fail "Unable to query analysed files"
  jq --exit-status \
    '.components[] | select(.path == "lib/classifier.dart" and .language == "dart" and .qualifier == "FIL")' \
    <<<"${components}" >/dev/null \
    || fail "The fixture source was not indexed as Dart"

  measures="$(curl --fail --silent --user "${analysis_token}:" \
    --get \
    --data-urlencode "component=${PROJECT_KEY}" \
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
}

run_fixture_analysis() {
  local base_url="$1"
  local fixture_dir="$2"
  local analysis_token
  local task_id

  analysis_token="$(generate_analysis_token "${base_url}")"
  scanner_work_dir="$(mktemp -d "${TMPDIR:-/tmp}/sonar-flutter-e2e.XXXXXX")"

  sonar-scanner \
    -Dsonar.host.url="${base_url}" \
    -Dsonar.token="${analysis_token}" \
    -Dsonar.projectKey="${PROJECT_KEY}" \
    -Dsonar.projectName="Sonar Flutter Dart coverage fixture" \
    -Dsonar.projectBaseDir="${fixture_dir}" \
    -Dsonar.working.directory="${scanner_work_dir}" \
    -Dsonar.sources="lib,pubspec.yaml" \
    -Dsonar.sourceEncoding=UTF-8 \
    -Dsonar.scm.disabled=true \
    -Dsonar.dart.analyzer.mode=MANUAL \
    -Dsonar.dart.analyzer.report.mode=MACHINE \
    -Dsonar.dart.analyzer.report.path=analysis-results.txt \
    -Dsonar.dart.analyzer.options.override=false \
    -Dsonar.flutter.tests.reportPath="${fixture_dir}/test-results.txt" \
    -Dsonar.flutter.coverage.reportPath=coverage/lcov.info

  [[ -f "${scanner_work_dir}/report-task.txt" ]] \
    || fail "SonarScanner did not create report-task.txt"
  task_id="$(awk -F= '$1 == "ceTaskId" {print $2}' "${scanner_work_dir}/report-task.txt")"
  [[ -n "${task_id}" ]] || fail "SonarScanner did not report a compute-engine task ID"

  wait_for_analysis "${base_url}" "${analysis_token}" "${task_id}"
  assert_analysis_results "${base_url}" "${analysis_token}"
}

require_command curl
require_command docker
require_command jq
require_command mvn
require_command sonar-scanner

trap cleanup EXIT INT TERM

printf 'Building plugin...\n'
mvn --quiet clean package

[[ -f "${PLUGIN_JAR}" ]] || fail "Plugin JAR not found: ${PLUGIN_JAR}"
PLUGIN_JAR_ABSOLUTE="$(cd "$(dirname "${PLUGIN_JAR}")" && pwd)/$(basename "${PLUGIN_JAR}")"
readonly PLUGIN_JAR_ABSOLUTE
FIXTURE_DIR_ABSOLUTE="$(cd "${FIXTURE_DIR}" && pwd)"
readonly FIXTURE_DIR_ABSOLUTE

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
run_fixture_analysis "${BASE_URL}" "${FIXTURE_DIR_ABSOLUTE}"

printf 'SonarQube 26.10 plugin and Dart coverage smoke test passed.\n'
