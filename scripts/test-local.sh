#!/usr/bin/env bash
set -euo pipefail

IMAGE_TAG="${1:-sonarqube-cnb-local:test}"
BUILDER="${2:-harbor.local.fintech23.xyz/builders/java-app-builder-jammy-base-default}"

pack build "$IMAGE_TAG" \
  --builder "$BUILDER" \
  --env BP_SONARQUBE_ENABLED=true \
  --env BP_SONARQUBE_URL="${BP_SONARQUBE_URL:?Set BP_SONARQUBE_URL before running}" \
  --env BP_SONARQUBE_APIKEY="${BP_SONARQUBE_APIKEY:?Set BP_SONARQUBE_APIKEY before running}" \
  --env BP_SONARQUBE_PROJECT_KEY="${BP_SONARQUBE_PROJECT_KEY:?Set BP_SONARQUBE_PROJECT_KEY before running}" \
  --env BP_MAVEN_BUILD_ARGUMENTS="${BP_MAVEN_BUILD_ARGUMENTS:-\"--batch-mode -Dmaven.test.skip=true package\"}" \
  --env BP_SONARQUBE_STRICT=false
