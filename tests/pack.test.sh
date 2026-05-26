#!/usr/bin/env bash
# Integration test: packages the buildpack, starts a local SonarQube, and
# runs a full pack build against a real Maven project.
#
# Usage:
#   BP_SONARQUBE_APIKEY=<token> ./tests/pack.test.sh [--keep]
#
# Flags:
#   --keep   keep SonarQube running after the test so you can browse results
#
# Required env:
#   BP_SONARQUBE_APIKEY   SonarQube user token (generate once in the UI and export)
#
# Optional env:
#   SOURCE_DIR            path to Maven project (default: city-remittance-service-admin)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILDPACK_DIR="${SCRIPT_DIR}/.."

KEEP_SONAR=false
for arg in "$@"; do
  [[ "$arg" == "--keep" ]] && KEEP_SONAR=true
done

BP_SONARQUBE_APIKEY="${BP_SONARQUBE_APIKEY:-squ_1bf9749d0e8057630ada920eb909b45b3bfde460}"

SOURCE_DIR="${SOURCE_DIR:-/home/noman637/Projects/BS23/city-remittance/city-remittance-service-admin}"
SONARQUBE_URL="http://localhost:9000"
SONARQUBE_INTERNAL_URL="http://sonarqube-local:9000"
DOCKER_NETWORK="sonar-test-net"
BUILDPACK_IMAGE="sonarqube-cnb-local:test"
APP_IMAGE="city-remittance-admin-sonartest"
BUILDER="paketobuildpacks/builder-jammy-base"

log()  { echo "  [pack-test] $*"; }
fail() { echo "  [pack-test] ERROR: $*" >&2; exit 1; }

PACK_IMAGE="buildpacksio/pack:latest"

# ── 1. start SonarQube ────────────────────────────────────────────────────────
echo
echo "━━━ 1. Starting SonarQube"
docker compose -f "${BUILDPACK_DIR}/docker-compose.yml" up -d

if [[ "$KEEP_SONAR" == false ]]; then
  trap 'echo; echo "━━━ Stopping SonarQube"; docker compose -f "${BUILDPACK_DIR}/docker-compose.yml" down' EXIT
fi

# ── 2. wait for UP ───────────────────────────────────────────────────────────
echo
echo "━━━ 2. Waiting for SonarQube to be ready (this takes ~60-90s on first start)"
attempt=0
until curl -sf "${SONARQUBE_URL}/api/system/status" 2>/dev/null | grep -q '"status":"UP"'; do
  ((attempt++))
  [[ "$attempt" -gt 60 ]] && fail "SonarQube did not become ready after ${attempt} attempts"
  printf "     attempt %d/60 …\r" "$attempt"
  sleep 5
done
echo "     SonarQube is UP                           "

# ── 3. package the buildpack ─────────────────────────────────────────────────
echo
echo "━━━ 3. Packaging buildpack as Docker image"
# --workdir /buildpack so that uri = "." in package.toml resolves correctly.
docker run --rm \
  --workdir /buildpack \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "${BUILDPACK_DIR}:/buildpack:ro" \
  "${PACK_IMAGE}" \
  buildpack package "${BUILDPACK_IMAGE}" \
  --config /buildpack/package.toml \
  --pull-policy if-not-present

log "Buildpack image: ${BUILDPACK_IMAGE}"

# ── 4. run pack build ────────────────────────────────────────────────────────
echo
echo "━━━ 4. Running pack build"
echo "       source : ${SOURCE_DIR}"
echo "       builder: ${BUILDER}"
echo "       image  : ${APP_IMAGE}"
echo "       sonar  : ${SONARQUBE_INTERNAL_URL}"
echo

docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "${SOURCE_DIR}:/workspace:ro" \
  "${PACK_IMAGE}" \
  build "${APP_IMAGE}" \
  --path /workspace \
  --builder "${BUILDER}" \
  --buildpack "docker://${BUILDPACK_IMAGE}" \
  --buildpack "paketo-buildpacks/java" \
  --network "${DOCKER_NETWORK}" \
  --pull-policy if-not-present \
  --env BP_SONARQUBE_ENABLED=true \
  --env "BP_SONARQUBE_URL=${SONARQUBE_INTERNAL_URL}" \
  --env "BP_SONARQUBE_APIKEY=${BP_SONARQUBE_APIKEY}" \
  --env BP_SONARQUBE_REPO_NAME=city-remittance-service-admin \
  --env BP_SONARQUBE_REPO_BRANCH=deployment/release \
  --env BP_SONARQUBE_AUTO_CREATE_PROJECT=true \
  --env BP_SONARQUBE_STRICT=false \
  --env "BP_MAVEN_BUILD_ARGUMENTS=--batch-mode -Dmaven.test.skip=true package" \
  --env BP_JVM_VERSION=17 \
  --env "BP_DEPENDENCY_MIRROR_GITHUB_COM=https://nexus.internal.fintech23.xyz/repository/github-public" \
  ${BP_SONARQUBE_PROJECT_VERSION:+--env "BP_SONARQUBE_PROJECT_VERSION=${BP_SONARQUBE_PROJECT_VERSION}"}

# ── 5. results ───────────────────────────────────────────────────────────────
echo
echo "━━━ Build complete"
echo "    SonarQube dashboard: ${SONARQUBE_URL}/projects"
if [[ "$KEEP_SONAR" == true ]]; then
  echo "    SonarQube is still running. Stop it with:"
  echo "      docker compose -f docker-compose.yml down"
fi
