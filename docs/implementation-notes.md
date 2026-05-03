# Phase 0–4 Implementation Notes

## Phase 0 validated assumptions

Based on your inputs:

- SonarQube URL is provided by workflow parameters and passed to kpack image env.
- SonarQube is **Community** (no branch support, no PR decoration).
- Use the latest approved tool versions in future when packaging; CLI Maven plugin comes from existing internal artifact flows.
- Maven/Gradle plugins can be resolved through internal Nexus/Artifactory proxy.
- Build architecture: `linux/amd64`.
- One global CI token is used across services.

## Phase 1 completed

Created the root buildpack source without additional nested project directories:

- `buildpack.toml`
- `package.toml`
- `project.toml`
- `bin/detect`
- `bin/build`
- `scripts/package.sh`
- `scripts/test-local.sh`
- `README.md`
- `vendor/sonar-scanner/.keep`

## Phase 2 completed

`bin/detect` now:

- Parses `BP_SONARQUBE_ENABLED`:
  - false/unset -> `exit 100` (optional skip)
  - true -> continue
  - invalid -> fail
- Validates required env variables in enabled mode:
  - `BP_SONARQUBE_URL`
  - `BP_SONARQUBE_APIKEY`
  - `BP_SONARQUBE_PROJECT_KEY`
- Supports `BP_SONARQUBE_SCANNER_MODE` values:
  - `auto` and `maven-inline`
- For auto mode, only detects Maven projects (`pom.xml`) in MVP.
- Writes a minimal plan with `[[provides]]`.

## Phase 3 completed

`bin/build` now implements Java Maven inline strategy:

- Ensures only Maven inline mode is executed.
- For `mode=auto`, if no `pom.xml`, build exits with `0` after logging no-op.
- Appends/adjusts Maven args via a build layer:
  - `sonar:sonar`
  - `-Dsonar.host.url=...`
  - `-Dsonar.projectKey=...`
  - `-Dsonar.projectName=...`
  - `-Dsonar.qualitygate.wait=...`
- Writes overrides to build-only layer `sonarqube-env`:
  - `BP_MAVEN_BUILD_ARGUMENTS.override`
  - `SONAR_TOKEN.override`
  - `SONAR_HOST_URL.override`
- Sets layer metadata as build-only (`build=true`, `launch=false`, `cache=false`) so values are only for build-time and do not leak to runtime env.
- Ignores `BP_SONARQUBE_BRANCH` with explicit note since Community build has no branch support.

## Phase 4 completed

Project auto-create flow added in `bin/build`:

- Calls `GET /api/projects/search` to verify project existence.
- Creates project with `POST /api/projects/create` when absent and `BP_SONARQUBE_AUTO_CREATE_PROJECT=true`.
- Fails early when missing and auto-create is disabled.

## Paketo Maven compatibility considerations

This buildpack only mutates `BP_MAVEN_BUILD_ARGUMENTS` and does not execute Maven itself, which is aligned with Paketo Java/Maven behavior.
The downstream Paketo Maven buildpack will run with the final value.

Security checks added:

- No token output in logs.
- Build pack never writes token into Maven args.
- API token stored as build-only environment in layer only (`SONAR_TOKEN.override`).
