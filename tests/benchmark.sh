#!/usr/bin/env bash
# Benchmark: measures pack build time for three SonarQube scenarios with warm .m2 cache.
# Before each run the source README is touched to bust Paketo's application layer cache
# while keeping the Maven dependency cache warm.
#
# Usage:
#   ./tests/benchmark.sh
#
# Optional env:
#   SOURCE_DIR               path to Maven project (default: city-remittance-service-admin)
#   BP_SONARQUBE_APIKEY      SonarQube token (default: hardcoded local token)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDPACK_DIR="${SCRIPT_DIR}/.."

SOURCE_DIR="${SOURCE_DIR:-/home/noman637/Projects/BS23/city-remittance/city-remittance-service-admin}"
BP_SONARQUBE_APIKEY="${BP_SONARQUBE_APIKEY:-squ_1bf9749d0e8057630ada920eb909b45b3bfde460}"
SONARQUBE_INTERNAL_URL="http://sonarqube-local:9000"
DOCKER_NETWORK="sonar-test-net"
BUILDPACK_IMAGE="sonarqube-cnb-local:test"
APP_IMAGE="city-remittance-admin-sonartest"
BUILDER="paketobuildpacks/builder-jammy-base"
PACK_IMAGE="buildpacksio/pack:latest"

COMMON_ARGS=(
  --path /workspace
  --builder "${BUILDER}"
  --network "${DOCKER_NETWORK}"
  --pull-policy if-not-present
  --env BP_JVM_VERSION=17
  --env "BP_MAVEN_BUILD_ARGUMENTS=--batch-mode -Dmaven.test.skip=true package"
  --env "BP_DEPENDENCY_MIRROR_GITHUB_COM=https://nexus.internal.fintech23.xyz/repository/github-public"
)

SONAR_BUILDPACK_ARGS=(
  --buildpack "docker://${BUILDPACK_IMAGE}"
  --buildpack "paketo-buildpacks/java"
)

SONAR_ARGS=(
  --env BP_SONARQUBE_ENABLED=true
  --env "BP_SONARQUBE_URL=${SONARQUBE_INTERNAL_URL}"
  --env "BP_SONARQUBE_APIKEY=${BP_SONARQUBE_APIKEY}"
  --env BP_SONARQUBE_REPO_NAME=city-remittance-service-admin
  --env BP_SONARQUBE_REPO_BRANCH=deployment/release
  --env BP_SONARQUBE_AUTO_CREATE_PROJECT=true
)

log()     { echo "  [benchmark] $*"; }
section() { echo; echo "━━━ $*"; }

bust_cache() {
  printf '\n<!-- benchmark run: %s -->\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >> "${SOURCE_DIR}/README.md"
  log "README.md updated — Paketo app-layer cache invalidated"
}

pack_build() {
  local outfile="$1"; shift
  docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${SOURCE_DIR}:/workspace:ro" \
    "${PACK_IMAGE}" \
    build "${APP_IMAGE}" \
    "${COMMON_ARGS[@]}" \
    "$@" 2>&1 | tee "$outfile" || { rm -f "$outfile"; return 1; }
}

warm_cache() {
  local label="$1"; shift
  log "Pre-warming cache for: ${label}"
  bust_cache
  local outfile; outfile="$(mktemp)"
  pack_build "$outfile" "$@"
  rm -f "$outfile"
  log "Cache warm for: ${label}"
}

time_build() {
  local label="$1"; shift
  bust_cache
  log "Timing: ${label}"
  local t0 t1 outfile
  t0=$(date +%s)
  outfile="$(mktemp)"

  pack_build "$outfile" "$@"

  t1=$(date +%s)
  grep -E "sonarqube-buildpack:|Executing mvnw|BUILD (SUCCESS|FAILURE)|ANALYSIS SUCCESSFUL|Successfully built image" \
    "$outfile" || true
  rm -f "$outfile"

  printf '  [benchmark] %-30s %ds\n' "${label}" "$((t1 - t0))"
  printf '%s\t%d\n' "${label}" "$((t1 - t0))" >> "${RESULTS_FILE}"
}

RESULTS_FILE="$(mktemp)"
trap 'rm -f "$RESULTS_FILE"' EXIT

# ── package buildpack once ────────────────────────────────────────────────────
section "Packaging buildpack"
docker run --rm \
  --workdir /buildpack \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "${BUILDPACK_DIR}:/buildpack:ro" \
  "${PACK_IMAGE}" \
  buildpack package "${BUILDPACK_IMAGE}" \
  --config /buildpack/package.toml \
  --pull-policy if-not-present 2>&1 | tail -1

# ── runs ──────────────────────────────────────────────────────────────────────
section "Run 1 — SonarQube disabled (pure Paketo Java, no sonarqube buildpack)"
warm_cache "disabled"
time_build "disabled"

section "Run 2 — SonarQube enabled, strict=false (no quality gate wait)"
warm_cache "enabled / strict=false" \
  "${SONAR_BUILDPACK_ARGS[@]}" \
  "${SONAR_ARGS[@]}" \
  --env BP_SONARQUBE_STRICT=false
time_build "enabled / strict=false" \
  "${SONAR_BUILDPACK_ARGS[@]}" \
  "${SONAR_ARGS[@]}" \
  --env BP_SONARQUBE_STRICT=false

section "Run 3 — SonarQube enabled, strict=true (waits for quality gate)"
warm_cache "enabled / strict=true" \
  "${SONAR_BUILDPACK_ARGS[@]}" \
  "${SONAR_ARGS[@]}" \
  --env BP_SONARQUBE_STRICT=true
time_build "enabled / strict=true" \
  "${SONAR_BUILDPACK_ARGS[@]}" \
  "${SONAR_ARGS[@]}" \
  --env BP_SONARQUBE_STRICT=true

# ── summary ───────────────────────────────────────────────────────────────────
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "%-32s %s\n" "Scenario" "Time"
echo "────────────────────────────────────────"
while IFS=$'\t' read -r label secs; do
  printf "%-32s %ds\n" "$label" "$secs"
done < "$RESULTS_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
