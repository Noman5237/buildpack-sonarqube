#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT="${SCRIPT_DIR}/../bin/detect"

PASS=0
FAIL=0
status=0
output=""

# ── harness ──────────────────────────────────────────────────────────────────

# run_detect <has_pom:true|false> [KEY=VAL ...]
# Sets global $status and $output.
run_detect() {
  local has_pom="$1"; shift
  local tmpdir
  tmpdir="$(mktemp -d)"
  [[ "$has_pom" == "true" ]] && touch "${tmpdir}/pom.xml"
  status=0
  output="$(cd "$tmpdir" && env -i PATH="$PATH" "$@" "$DETECT" "" "${tmpdir}/plan.txt" 2>&1)" || status=$?
  rm -rf "$tmpdir"
}

# run_detect_with_plan <has_pom:true|false> [KEY=VAL ...]
# Like run_detect but also sets $plan_content from the written plan file.
plan_content=""
run_detect_with_plan() {
  local has_pom="$1"; shift
  local tmpdir
  tmpdir="$(mktemp -d)"
  [[ "$has_pom" == "true" ]] && touch "${tmpdir}/pom.xml"
  local plan_path="${tmpdir}/plan.txt"
  status=0
  output="$(cd "$tmpdir" && env -i PATH="$PATH" "$@" "$DETECT" "" "$plan_path" 2>&1)" || status=$?
  plan_file_existed=false
  if [[ -f "$plan_path" ]]; then
    plan_file_existed=true
    plan_content="$(cat "$plan_path")"
  else
    plan_content=""
  fi
  rm -rf "$tmpdir"
}

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; ((PASS++)) || true; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; printf '       exit=%s\n       out=%s\n' "$status" "$output"; ((FAIL++)) || true; }

assert_exit() {
  local name="$1" expected="$2"
  [[ "$status" -eq "$expected" ]] && ok "$name" || fail "$name  (expected exit $expected, got $status)"
}

assert_output_has() {
  local name="$1" pattern="$2"
  printf '%s' "$output" | grep -qFe "$pattern" && ok "$name" || fail "$name  (expected: $pattern)"
}

assert_output_not_has() {
  local name="$1" pattern="$2"
  printf '%s' "$output" | grep -qFe "$pattern" && fail "$name  (should not contain: $pattern)" || ok "$name"
}

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ── tests ─────────────────────────────────────────────────────────────────────

section "1. BP_SONARQUBE_ENABLED — disabled / skip"

run_detect false
assert_exit "unset ENABLED → exit 100" 100

run_detect false BP_SONARQUBE_ENABLED=false
assert_exit "ENABLED=false → exit 100" 100

run_detect false BP_SONARQUBE_ENABLED=FALSE
assert_exit "ENABLED=FALSE (case) → exit 100" 100

run_detect false BP_SONARQUBE_ENABLED=0
assert_exit "ENABLED=0 → exit 100" 100

run_detect false BP_SONARQUBE_ENABLED=no
assert_exit "ENABLED=no → exit 100" 100

run_detect false BP_SONARQUBE_ENABLED=off
assert_exit "ENABLED=off → exit 100" 100

section "2. BP_SONARQUBE_ENABLED — invalid value"

run_detect false BP_SONARQUBE_ENABLED=maybe
assert_exit "ENABLED=maybe → exit 1" 1
assert_output_has "ENABLED=maybe → logs invalid value" "Invalid BP_SONARQUBE_ENABLED"

section "3. Always-required vars"

run_detect false \
  BP_SONARQUBE_ENABLED=true
assert_exit "missing URL → non-zero" 1
assert_output_has "missing URL → error mentions URL" "BP_SONARQUBE_URL"

run_detect false \
  BP_SONARQUBE_ENABLED=true \
  BP_SONARQUBE_URL=https://sonar.example.com
assert_exit "missing APIKEY → non-zero" 1
assert_output_has "missing APIKEY → error mentions APIKEY" "BP_SONARQUBE_APIKEY"

section "4. Project identity validation — neither pair provided"

run_detect false \
  BP_SONARQUBE_ENABLED=true \
  BP_SONARQUBE_URL=https://sonar.example.com \
  BP_SONARQUBE_APIKEY=tok
assert_exit "no identity pair → non-zero" 1

section "5. Project identity — only one of the explicit pair"

run_detect false \
  BP_SONARQUBE_ENABLED=true \
  BP_SONARQUBE_URL=https://sonar.example.com \
  BP_SONARQUBE_APIKEY=tok \
  BP_SONARQUBE_PROJECT_NAME=my-service
assert_exit "only PROJECT_NAME, no key, no repo → non-zero" 1

run_detect false \
  BP_SONARQUBE_ENABLED=true \
  BP_SONARQUBE_URL=https://sonar.example.com \
  BP_SONARQUBE_APIKEY=tok \
  BP_SONARQUBE_PROJECT_KEY=my-key
assert_exit "only PROJECT_KEY, no name, no repo → non-zero" 1

section "6. Project identity — explicit pair (no pom.xml)"

run_detect false \
  BP_SONARQUBE_ENABLED=true \
  BP_SONARQUBE_URL=https://sonar.example.com \
  BP_SONARQUBE_APIKEY=tok \
  BP_SONARQUBE_PROJECT_NAME=my-service \
  BP_SONARQUBE_PROJECT_KEY=my-service-key
assert_exit "explicit pair + no pom.xml → exit 100 (optional skip)" 100

section "7. Project identity — explicit pair (with pom.xml)"

run_detect true \
  BP_SONARQUBE_ENABLED=true \
  BP_SONARQUBE_URL=https://sonar.example.com \
  BP_SONARQUBE_APIKEY=tok \
  BP_SONARQUBE_PROJECT_NAME=my-service \
  BP_SONARQUBE_PROJECT_KEY=my-service-key
assert_exit "explicit pair + pom.xml → exit 0" 0
assert_output_has "explicit pair → logs project name" "my-service"
assert_output_has "explicit pair → logs project key" "my-service-key"

section "8. Project identity — repo pair (no pom.xml)"

run_detect false \
  BP_SONARQUBE_ENABLED=true \
  BP_SONARQUBE_URL=https://sonar.example.com \
  BP_SONARQUBE_APIKEY=tok \
  BP_SONARQUBE_REPO_NAME=my-repo \
  BP_SONARQUBE_REPO_BRANCH=main
assert_exit "repo pair + no pom.xml → exit 100 (optional skip)" 100

section "9. Project identity — repo pair (with pom.xml)"

run_detect true \
  BP_SONARQUBE_ENABLED=true \
  BP_SONARQUBE_URL=https://sonar.example.com \
  BP_SONARQUBE_APIKEY=tok \
  BP_SONARQUBE_REPO_NAME=my-repo \
  BP_SONARQUBE_REPO_BRANCH=main
assert_exit "repo pair + pom.xml → exit 0" 0
assert_output_has "repo pair → detected message" "SonarQube buildpack detected"

section "10. Slug formatting"

run_detect true \
  BP_SONARQUBE_ENABLED=true \
  BP_SONARQUBE_URL=https://sonar.example.com \
  BP_SONARQUBE_APIKEY=tok \
  "BP_SONARQUBE_REPO_NAME=My Repo/Name" \
  BP_SONARQUBE_REPO_BRANCH=main
assert_exit "repo name with spaces/slashes is slugified → exit 0" 0

run_detect true \
  BP_SONARQUBE_ENABLED=true \
  BP_SONARQUBE_URL=https://sonar.example.com \
  BP_SONARQUBE_APIKEY=tok \
  BP_SONARQUBE_REPO_NAME=my-repo \
  BP_SONARQUBE_REPO_BRANCH=feature/my-branch
assert_exit "branch with slash is slugified → exit 0" 0

run_detect true \
  BP_SONARQUBE_ENABLED=true \
  BP_SONARQUBE_URL=https://sonar.example.com \
  BP_SONARQUBE_APIKEY=tok \
  BP_SONARQUBE_REPO_NAME=--- \
  BP_SONARQUBE_REPO_BRANCH=main
assert_exit "all-dashes repo name → exit 1 (empty slug)" 1
assert_output_has "all-dashes slug → error message" "BP_SONARQUBE_REPO_NAME must contain"

run_detect true \
  BP_SONARQUBE_ENABLED=true \
  BP_SONARQUBE_URL=https://sonar.example.com \
  BP_SONARQUBE_APIKEY=tok \
  BP_SONARQUBE_REPO_NAME=my-repo \
  BP_SONARQUBE_REPO_BRANCH=---
assert_exit "all-dashes branch → exit 1 (empty slug)" 1
assert_output_has "all-dashes branch slug → error message" "BP_SONARQUBE_REPO_BRANCH must contain"

section "11. Plan file output"

run_detect_with_plan true \
  BP_SONARQUBE_ENABLED=true \
  BP_SONARQUBE_URL=https://sonar.example.com \
  BP_SONARQUBE_APIKEY=tok \
  BP_SONARQUBE_PROJECT_NAME=svc \
  BP_SONARQUBE_PROJECT_KEY=svc-key
assert_exit "plan file written on success → exit 0" 0
[[ "$plan_file_existed" == "true" ]] && ok "plan file created" || fail "plan file not created"
[[ -z "$plan_content" ]] && ok "plan file is empty (no provides/requires — avoids unused-provide error)" || fail "plan should be empty; got: $plan_content"

section "12. Security — token never logged"

run_detect true \
  BP_SONARQUBE_ENABLED=true \
  BP_SONARQUBE_URL=https://sonar.example.com \
  BP_SONARQUBE_APIKEY=super-secret-token \
  BP_SONARQUBE_PROJECT_NAME=svc \
  BP_SONARQUBE_PROJECT_KEY=svc-key
assert_output_not_has "APIKEY not printed in output" "super-secret-token"

# ── summary ───────────────────────────────────────────────────────────────────

printf '\n%s\n' "────────────────────────────────"
printf "Results: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"

[[ "$FAIL" -eq 0 ]]
