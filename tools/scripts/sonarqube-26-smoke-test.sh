#!/usr/bin/env bash

set -euo pipefail

readonly SONARQUBE_IMAGE="${SONARQUBE_IMAGE:-sonarqube:26.10.0.133078-community}"
readonly PLUGIN_JAR="${PLUGIN_JAR:-sonar-flutter-plugin/target/sonar-flutter-plugin-0.5.2.jar}"
readonly CONTAINER_NAME="sonar-flutter-smoke-$$"
readonly STARTUP_TIMEOUT_SECONDS="${STARTUP_TIMEOUT_SECONDS:-180}"
readonly ADMIN_CREDENTIALS="admin:admin"

container_started=false

cleanup() {
  if [[ "${container_started}" == "true" ]]; then
    docker rm --force "${CONTAINER_NAME}" >/dev/null 2>&1 || true
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

require_command curl
require_command docker
require_command jq
require_command mvn

trap cleanup EXIT INT TERM

printf 'Building plugin...\n'
mvn --quiet clean package

[[ -f "${PLUGIN_JAR}" ]] || fail "Plugin JAR not found: ${PLUGIN_JAR}"
readonly PLUGIN_JAR_ABSOLUTE="$(cd "$(dirname "${PLUGIN_JAR}")" && pwd)/$(basename "${PLUGIN_JAR}")"

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

printf 'SonarQube 26.10 plugin smoke test passed.\n'
