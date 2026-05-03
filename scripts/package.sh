#!/usr/bin/env bash
set -euo pipefail

TAG="${1:-harbor.local.fintech23.xyz/buildpacks/sonarqube-cnb:0.1.0}"

pack buildpack package "$TAG" --config package.toml
