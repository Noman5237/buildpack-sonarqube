#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="${SCRIPT_DIR}/../bin/build"

PASS=0
FAIL=0
status=0
output=""
LAYERS_DIR=""
BUILD_DIR=""

# ── mock curl ─────────────────────────────────────────────────────────────────
# Behaviour controlled by env vars:
#   MOCK_SONAR_PROJECT_EXISTS=true|false   (default: true)
#   MOCK_SONAR_CREATE_FAIL=true|false      (default: false)

MOCK_BIN="$(mktemp -d)"
trap 'rm -rf "$MOCK_BIN"' EXIT

cat > "${MOCK_BIN}/curl" <<'CURL_EOF'
#!/usr/bin/env bash
args=("$@")
for arg in "${args[@]}"; do
  if [[ "$arg" == *"projects/search"* ]]; then
    if [[ "${MOCK_SONAR_PROJECT_EXISTS:-true}" == "true" ]]; then
      project_key=""
      for ((i = 0; i < ${#args[@]}; i++)); do
        if [[ "${args[$i]}" == "--data-urlencode" ]]; then
          val="${args[$((i + 1))]}"
          [[ "$val" == projects=* ]] && project_key="${val#projects=}"
        fi
      done
      echo "{\"paging\":{\"total\":1},\"components\":[{\"key\":\"${project_key}\"}]}"
    else
      echo '{"paging":{"total":0},"components":[]}'
    fi
    exit 0
  fi
  if [[ "$arg" == *"projects/create"* ]]; then
    if [[ "${MOCK_SONAR_CREATE_FAIL:-false}" == "true" ]]; then
      echo '{"errors":[{"msg":"creation failed"}]}'
    else
      echo '{"project":{"key":"created","name":"created"}}'
    fi
    exit 0
  fi
done
exit 0
CURL_EOF
chmod +x "${MOCK_BIN}/curl"

# ── harness ───────────────────────────────────────────────────────────────────

setup() {
  LAYERS_DIR="$(mktemp -d)"
  BUILD_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$LAYERS_DIR" "$BUILD_DIR"
}

# run_build [KEY=VAL ...]
run_build() {
  status=0
  output="$(
    env -i PATH="${MOCK_BIN}:${PATH}" \
      "$@" \
      "$BUILD" "$LAYERS_DIR" "" "" "$BUILD_DIR" 2>&1
  )" || status=$?
}

layer_file()  { cat "${LAYERS_DIR}/sonarqube-env/env/$1"  2>/dev/null || true; }
layer_toml()  { cat "${LAYERS_DIR}/sonarqube-env.toml"    2>/dev/null || true; }

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; ((PASS++)) || true; }
nok()  {
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  [[ -n "$output"  ]] && printf '       out:  %s\n' "$output"
  [[ "$status" -ne 0 ]] && printf '       exit: %s\n' "$status"
  ((FAIL++)) || true
}

assert_exit() {
  local name="$1" exp="$2"
  [[ "$status" -eq "$exp" ]] && ok "$name" || nok "$name  (want exit $exp, got $status)"
}

assert_output_has() {
  local name="$1" pat="$2"
  printf '%s' "$output" | grep -qFe "$pat" && ok "$name" || nok "$name  (expected: $pat)"
}

assert_output_not_has() {
  local name="$1" pat="$2"
  printf '%s' "$output" | grep -qFe "$pat" && nok "$name  (must not contain: $pat)" || ok "$name"
}

assert_layer_has() {
  local name="$1" file="$2" pat="$3"
  local c; c="$(layer_file "$file")"
  printf '%s' "$c" | grep -qFe "$pat" && ok "$name" || nok "$name  (want '$pat' in $file; got: $c)"
}

assert_layer_not_has() {
  local name="$1" file="$2" pat="$3"
  local c; c="$(layer_file "$file")"
  printf '%s' "$c" | grep -qFe "$pat" && nok "$name  (must not contain '$pat' in $file)" || ok "$name"
}

assert_toml_has() {
  local name="$1" pat="$2"
  local c; c="$(layer_toml)"
  printf '%s' "$c" | grep -qFe "$pat" && ok "$name" || nok "$name  (want '$pat' in layer toml; got: $c)"
}

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Common base env — every test that should succeed needs at least these.
BASE=(
  BP_SONARQUBE_ENABLED=true
  BP_SONARQUBE_URL=https://sonar.example.com
  BP_SONARQUBE_APIKEY=secret-token
  BP_SONARQUBE_PROJECT_NAME=my-service
  BP_SONARQUBE_PROJECT_KEY=my-service-key
)

# ── tests ─────────────────────────────────────────────────────────────────────

section "1. Invalid boolean inputs"

setup
run_build "${BASE[@]}" BP_SONARQUBE_STRICT=garbage
assert_exit "STRICT=garbage → fail" 1
assert_output_has "STRICT=garbage → error message" "Invalid BP_SONARQUBE_STRICT"
teardown

setup
run_build "${BASE[@]}" BP_SONARQUBE_AUTO_CREATE_PROJECT=garbage
assert_exit "AUTO_CREATE=garbage → fail" 1
assert_output_has "AUTO_CREATE=garbage → error message" "Invalid BP_SONARQUBE_AUTO_CREATE_PROJECT"
teardown

section "2. Project resolution — explicit pair"

setup
run_build \
  BP_SONARQUBE_ENABLED=true \
  BP_SONARQUBE_URL=https://sonar.example.com \
  BP_SONARQUBE_APIKEY=secret-token \
  BP_SONARQUBE_PROJECT_NAME=display-name \
  BP_SONARQUBE_PROJECT_KEY=unique-key
assert_exit "explicit pair → exit 0" 0
assert_layer_has "explicit pair → projectKey in sonar args" \
  "BP_MAVEN_ADDITIONAL_BUILD_ARGUMENTS.override" "-Dsonar.projectKey=unique-key"
assert_layer_has "explicit pair → projectName in sonar args" \
  "BP_MAVEN_ADDITIONAL_BUILD_ARGUMENTS.override" "-Dsonar.projectName=display-name"
teardown

section "3. Project resolution — repo pair"

setup
run_build \
  BP_SONARQUBE_ENABLED=true \
  BP_SONARQUBE_URL=https://sonar.example.com \
  BP_SONARQUBE_APIKEY=secret-token \
  BP_SONARQUBE_REPO_NAME=My-Repo \
  BP_SONARQUBE_REPO_BRANCH=feature/my-branch
assert_exit "repo pair → exit 0" 0
assert_layer_has "repo pair → slugified key in sonar args" \
  "BP_MAVEN_ADDITIONAL_BUILD_ARGUMENTS.override" "-Dsonar.projectKey=my-repo-feature-my-branch"
assert_output_has "repo pair → logs slug transformation" "my-repo"
teardown

section "4. Quality gate — strict mode"

setup
run_build "${BASE[@]}" BP_SONARQUBE_STRICT=false
assert_exit "STRICT=false → exit 0" 0
assert_layer_has "STRICT=false → qualitygate.wait=false" \
  "BP_MAVEN_ADDITIONAL_BUILD_ARGUMENTS.override" "-Dsonar.qualitygate.wait=false"
teardown

setup
run_build "${BASE[@]}" BP_SONARQUBE_STRICT=true
assert_exit "STRICT=true → exit 0" 0
assert_layer_has "STRICT=true → qualitygate.wait=true" \
  "BP_MAVEN_ADDITIONAL_BUILD_ARGUMENTS.override" "-Dsonar.qualitygate.wait=true"
teardown

section "5. SonarQube API — project existence"

setup
run_build MOCK_SONAR_PROJECT_EXISTS=true "${BASE[@]}"
assert_exit "project exists → exit 0 (no create)" 0
assert_output_has "project exists → logs already exists" "already exists"
assert_output_not_has "project exists → no create log" "Creating SonarQube project"
teardown

setup
run_build MOCK_SONAR_PROJECT_EXISTS=false "${BASE[@]}" BP_SONARQUBE_AUTO_CREATE_PROJECT=true
assert_exit "project missing + auto_create=true → exit 0" 0
assert_output_has "project missing → create log" "Creating SonarQube project"
assert_output_has "project missing → created log" "created"
teardown

setup
run_build MOCK_SONAR_PROJECT_EXISTS=false "${BASE[@]}" BP_SONARQUBE_AUTO_CREATE_PROJECT=false
assert_exit "project missing + auto_create=false → fail" 1
assert_output_has "auto_create=false → error message" "does not exist and auto-create is disabled"
teardown

setup
run_build MOCK_SONAR_PROJECT_EXISTS=false MOCK_SONAR_CREATE_FAIL=true "${BASE[@]}" BP_SONARQUBE_AUTO_CREATE_PROJECT=true
assert_exit "project create API failure → fail" 1
assert_output_has "create failure → error message" "Failed to create SonarQube project"
teardown

section "6. sonar:sonar goal always set"

setup
run_build "${BASE[@]}"
assert_exit "sonar:sonar present → exit 0" 0
assert_layer_has "sonar:sonar in additional args" \
  "BP_MAVEN_ADDITIONAL_BUILD_ARGUMENTS.override" "sonar:sonar"
assert_layer_has "sonar.host.url in additional args" \
  "BP_MAVEN_ADDITIONAL_BUILD_ARGUMENTS.override" "-Dsonar.host.url=https://sonar.example.com"
teardown

section "7. Extra args"

setup
run_build "${BASE[@]}" "BP_SONARQUBE_EXTRA_ARGS=-Dsonar.coverage.jacoco.xmlReportPaths=target/jacoco.xml"
assert_exit "extra args appended → exit 0" 0
assert_layer_has "extra args present in sonar args" \
  "BP_MAVEN_ADDITIONAL_BUILD_ARGUMENTS.override" "-Dsonar.coverage.jacoco.xmlReportPaths=target/jacoco.xml"
teardown

section "8. Layer files"

setup
run_build "${BASE[@]}"
assert_exit "layer files setup → exit 0" 0
assert_toml_has "layer toml: build = true"   "build = true"
assert_toml_has "layer toml: cache = false"  "cache = false"
assert_toml_has "layer toml: launch = false" "launch = false"
assert_layer_has "BP_MAVEN_ADDITIONAL_BUILD_ARGUMENTS.override exists with sonar goal" \
  "BP_MAVEN_ADDITIONAL_BUILD_ARGUMENTS.override" "sonar:sonar"
assert_layer_has "sonar.token passed as maven property" \
  "BP_MAVEN_ADDITIONAL_BUILD_ARGUMENTS.override" "-Dsonar.token=secret-token"
teardown

section "9. Security — token not in buildpack log output"

setup
run_build "${BASE[@]}"
assert_exit "security check setup → exit 0" 0
assert_output_not_has "token redacted in our log output" "secret-token"
teardown

# ── summary ───────────────────────────────────────────────────────────────────

printf '\n%s\n' "────────────────────────────────"
printf "Results: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
