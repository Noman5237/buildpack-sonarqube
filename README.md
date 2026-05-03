# SonarQube Buildpack (CNB for Paketo Java flow)

This repository builds a Cloud Native Buildpack (`bs23-buildpacks/sonarqube`) intended to be used in the same builder as Paketo Java. It is designed to be used only when explicitly enabled via env:

```text
BP_SONARQUBE_ENABLED=true
```

When enabled, the buildpack does **not** execute Maven itself. Instead it mutates the existing `BP_MAVEN_BUILD_ARGUMENTS` environment for downstream Paketo Maven/Java buildpacks so SonarQube runs as part of the normal Maven invocation.

This keeps build runtime fast and avoids a second Maven execution.

## Key assumptions from platform

- Build target: Java on Linux/amd64
- SonarQube edition: **Community**
  - No branch analysis
  - No PR decoration
- Token source: Kubernetes Secret (never ConfigMap)
- Default behavior:
  - No quality gate wait unless `BP_SONARQUBE_STRICT=true`
  - SonarQube project auto-creation enabled by default

## How it integrates with Paketo

The buildpack is placed **before** `paketo-buildpacks/java` in builder group:

```yaml
order:
- group:
  - id: bs23-buildpacks/sonarqube
    optional: true
  - id: paketo-buildpacks/java
  - id: paketo-buildpacks/opentelemetry
```

Because the build is executed in-order, the SonarQube buildpack writes a build-only layer with environment overrides that are picked up by Paketo Java in the same build execution.

Paketo-compatible behavior implemented:

- Writes `BP_MAVEN_BUILD_ARGUMENTS` into
  `LAYERS_DIR/sonarqube-env/env/BP_MAVEN_BUILD_ARGUMENTS.override`
- Adds `SONAR_TOKEN` via
  `LAYERS_DIR/sonarqube-env/env/SONAR_TOKEN.override`
- Sets `build=true`, `launch=false`, `cache=false` in `sonarqube-env.toml`

This ensures:

- The updated Maven arguments are visible to subsequent buildpacks (including Paketo Java).
- Sonar credentials are not exposed to launch/runtime.

## Implemented behavior (MVP / phase 4)

1. **Detect** (`bin/detect`)
   - Enabled by `BP_SONARQUBE_ENABLED=true` only.
   - Validates required vars.
   - Supports modes:
     - `maven-inline`
     - `auto` (maps to Maven inline only when `pom.xml` exists)
   - No-op (`exit 100`) when mode is `auto` and no `pom.xml`.

2. **Build** (`bin/build`)
   - Verifies enabled state and required vars.
   - Mutates Maven args for downstream build:
     - preserves existing `BP_MAVEN_BUILD_ARGUMENTS`
     - appends `sonar:sonar`
     - appends Sonar host/project key/project name/quality gate flags
   - Writes build-only layer with env overrides above.
   - Detects existing SonarQube project.
   - Creates project when missing and `BP_SONARQUBE_AUTO_CREATE_PROJECT=true`.

3. **Community restrictions**
   - Branch-related scanner arguments are intentionally ignored.

## Supported env vars

### Required when enabled

- `BP_SONARQUBE_ENABLED=true|false`
- `BP_SONARQUBE_URL`
- `BP_SONARQUBE_APIKEY`
- `BP_SONARQUBE_PROJECT_KEY`

### Optional

- `BP_SONARQUBE_PROJECT_NAME`
- `BP_SONARQUBE_STRICT`
- `BP_SONARQUBE_SCANNER_MODE` (`auto`, `maven-inline`)
- `BP_MAVEN_BUILD_ARGUMENTS`
- `BP_SONARQUBE_AUTO_CREATE_PROJECT` (default: `true`)
- `BP_SONARQUBE_EXTRA_ARGS`

## Notes for kpack integration

A separate kpack manifest workflow step should inject:

- `BP_SONARQUBE_APIKEY` from Secret via `valueFrom`.
- Non-secret values (`URL`, `PROJECT_KEY`, etc.) from ConfigMap.

## Packaging

```bash
./scripts/package.sh harbor.local.fintech23.xyz/buildpacks/sonarqube-cnb:0.1.0
```

This repository is currently MVP focused on Java/Maven inline mode only.
