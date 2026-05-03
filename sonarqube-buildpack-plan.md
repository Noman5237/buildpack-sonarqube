# SonarQube Cloud Native Buildpack Plan

## Goal

Create a custom Cloud Native Buildpack (CNB) for SonarQube analysis that can be used by kpack builders alongside existing Paketo buildpacks such as Java and OpenTelemetry.

The buildpack will run during the image build, upload SonarQube analysis, and be controlled per service through build-time environment variables.

Target kpack builder file:

```text
/home/noman637/Projects/BS23/fintech-dev-cluster-revamped/deployments/infrastructure/argo/kpack/java-app-builder-jammy-base-default.yaml
```

Current Java builder order:

```yaml
order:
- group:
  - id: paketo-buildpacks/java
  - id: paketo-buildpacks/opentelemetry
```

Required Java builder order for Maven inline SonarQube analysis:

```yaml
order:
- group:
  - id: bs23-buildpacks/sonarqube
    optional: true
  - id: paketo-buildpacks/java
  - id: paketo-buildpacks/opentelemetry
```

Important: for Java/Maven apps, the SonarQube buildpack must run **before** `paketo-buildpacks/java`, because it will modify the build-time Maven arguments consumed by the Java buildpack.

---

## Important Design Decision

This should be implemented as a separate CNB buildpack image, not inside the CNB lifecycle repository.

The lifecycle executes buildpacks. The SonarQube logic should live in its own buildpack with its own `detect` and `build` scripts, then be added to the kpack `ClusterStore` and `ClusterBuilder` order.

The buildpack should not contribute runtime/launch layers to the final application image. Any contributed layer should be build-only and, if needed, cache-only.

---

## High-Level Architecture

### Java/Maven optimized flow

```text
Application source repo
        |
        v
kpack Image resource
        |
        v
ClusterBuilder
        |
        +--> bs23-buildpacks/sonarqube optional
        |      - checks BP_SONARQUBE_ENABLED
        |      - creates SonarQube project if enabled/missing
        |      - prepares build-time environment for later buildpacks
        |      - modifies BP_MAVEN_BUILD_ARGUMENTS
        |      - does NOT run Maven itself
        |
        +--> paketo-buildpacks/java
        |      - runs normal Maven package command
        |      - tests remain skipped if already configured
        |      - generated target/classes are reused by sonar:sonar
        |      - SonarQube analysis happens inside the same Maven execution
        |
        +--> paketo-buildpacks/opentelemetry
        |
        v
Final application image
```

### Non-Java flow

```text
Application source repo
        |
        v
Language buildpack builds app
        |
        v
bs23-buildpacks/sonarqube optional
        |
        v
sonar-scanner CLI uploads analysis
        |
        v
Final application image
```

---

## Core Requirements

The custom buildpack should:

1. Enable/disable SonarQube per service using `BP_SONARQUBE_ENABLED`.
2. Support strict/non-strict quality gate behavior using `BP_SONARQUBE_STRICT`.
3. For Java/Maven, avoid a second Maven build and avoid running tests.
4. For Java/Maven, inject SonarQube into the existing `BP_MAVEN_BUILD_ARGUMENTS` command.
5. For non-Java apps, run vendored SonarScanner CLI.
6. Automatically create the SonarQube project if configured and missing.
7. Avoid leaking the SonarQube token in logs, ConfigMaps, layers, or image metadata.
8. Fail the build only when enabled and strict/config/scanner behavior requires it.

---

## Environment Variables

### Main control variables

```text
BP_SONARQUBE_ENABLED=true|false
BP_SONARQUBE_STRICT=true|false
```

Recommended defaults:

```text
BP_SONARQUBE_ENABLED=false
BP_SONARQUBE_STRICT=false
```

Behavior:

| Variable | Value | Behavior |
|---|---|---|
| `BP_SONARQUBE_ENABLED` | `false` or unset | buildpack opts out with detect exit code `100`; normal app build continues |
| `BP_SONARQUBE_ENABLED` | `true` | buildpack runs; required config must be present |
| `BP_SONARQUBE_STRICT` | `false` or unset | upload analysis but do not block image publishing on quality gate |
| `BP_SONARQUBE_STRICT` | `true` | wait for quality gate and fail image build if quality gate fails |

`BP_SONARQUBE_STRICT` maps to:

```text
false -> sonar.qualitygate.wait=false
true  -> sonar.qualitygate.wait=true
```

### Required when enabled

```text
BP_SONARQUBE_URL
BP_SONARQUBE_APIKEY
BP_SONARQUBE_PROJECT_KEY
```

`BP_SONARQUBE_APIKEY` must come from a Kubernetes Secret, not a ConfigMap.

### Recommended optional variables

```text
BP_SONARQUBE_PROJECT_NAME
BP_SONARQUBE_BRANCH
BP_SONARQUBE_SCANNER_MODE=auto|maven-inline|cli|gradle|maven-separate
BP_SONARQUBE_AUTO_CREATE_PROJECT=true|false
BP_SONARQUBE_EXTRA_ARGS
BP_SONARQUBE_SOURCES
BP_SONARQUBE_TESTS
BP_SONARQUBE_COVERAGE_REPORT_PATHS
BP_SONARQUBE_FAIL_ON_UNKNOWN_PROJECT_TYPE=true|false
```

Recommended defaults:

```text
BP_SONARQUBE_SCANNER_MODE=auto
BP_SONARQUBE_AUTO_CREATE_PROJECT=true
BP_SONARQUBE_FAIL_ON_UNKNOWN_PROJECT_TYPE=false
BP_SONARQUBE_SOURCES=.
```

Optional project metadata can be generated from workflow values:

```text
BP_SONARQUBE_PROJECT_KEY={{project}}-{{service-name}}
BP_SONARQUBE_PROJECT_NAME={{service-name}}
BP_SONARQUBE_BRANCH={{branch}}
```

---

## Java/Maven Strategy: Inline Maven Analysis

For Java/Maven projects, do **not** run `mvn` separately from the SonarQube buildpack.

The existing app build already uses Paketo Java and usually receives Maven args like:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: rel-prod-bs23-ib-notification-service-build-configmap
  namespace: cicd
data:
  BP_OPENTELEMETRY_ENABLED: "true"
  BP_JVM_VERSION: "17"
  BP_MAVEN_BUILD_ARGUMENTS: "--batch-mode -Dmaven.test.skip=true -X package"
```

When SonarQube is enabled, the SonarQube buildpack should transform the build-time Maven args to include `sonar:sonar` in the same Maven invocation:

```text
--batch-mode -Dmaven.test.skip=true -X package sonar:sonar \
-Dsonar.host.url=https://sonarqube.example.com \
-Dsonar.projectKey=prod-bs23-ib-notification-service \
-Dsonar.projectName=bs23-ib-notification-service \
-Dsonar.branch.name=ncc/deployment/release \
-Dsonar.qualitygate.wait=false
```

Important requirements:

1. Keep `-Dmaven.test.skip=true` if already configured.
2. Do not append `verify`.
3. Do not run Maven tests in kpack.
4. Do not run a separate Maven command from the SonarQube buildpack.
5. Reuse the generated `target/classes` from the normal `package` phase.
6. Java coverage will be absent unless a report already exists; this is acceptable for this design.

### Why this is better for Java

Separate flow, not recommended:

```text
mvn package      # app build
mvn sonar:sonar  # second Maven invocation
```

Recommended flow:

```text
mvn --batch-mode -Dmaven.test.skip=true package sonar:sonar
```

Benefits:

- no second compilation/build cycle
- no test execution
- SonarQube can use generated bytecode/classes
- build time stays closer to current kpack build time

---

## CNB Mechanism for Java Env Mutation

Because the SonarQube buildpack runs before `paketo-buildpacks/java`, it should contribute a build-only layer with environment files that affect subsequent buildpacks.

Conceptual layer metadata:

```toml
[types]
build = true
launch = false
cache = false
```

Conceptual env contribution:

```text
<layer>/env/BP_MAVEN_BUILD_ARGUMENTS.override
<layer>/env/SONAR_TOKEN.override
<layer>/env/SONAR_HOST_URL.override
```

Purpose:

- override/extend `BP_MAVEN_BUILD_ARGUMENTS` for the Paketo Java buildpack
- expose token only as build-time environment, not launch/runtime environment
- avoid putting token into Maven args

Token handling preference:

```text
SONAR_TOKEN=$BP_SONARQUBE_APIKEY
SONAR_HOST_URL=$BP_SONARQUBE_URL
```

Avoid this unless absolutely required by scanner/plugin compatibility:

```text
-Dsonar.token=<token>
```

If a specific Sonar Maven plugin version does not honor `SONAR_TOKEN`, verify the approved internal scanner/plugin version before falling back to command-line token passing.

---

## Java/Maven Argument Mutation Rules

Input example:

```text
BP_MAVEN_BUILD_ARGUMENTS="--batch-mode -Dmaven.test.skip=true -X package"
```

Output example:

```text
BP_MAVEN_BUILD_ARGUMENTS="--batch-mode -Dmaven.test.skip=true -X package sonar:sonar -Dsonar.host.url=https://sonarqube.example.com -Dsonar.projectKey=prod-bs23-ib-notification-service -Dsonar.projectName=bs23-ib-notification-service -Dsonar.branch.name=ncc/deployment/release -Dsonar.qualitygate.wait=false"
```

Rules:

1. Preserve all existing user-supplied Maven args.
2. Append `sonar:sonar` only if it is not already present.
3. Preserve existing test-skip flags.
4. Do not add `test`, `verify`, or coverage-generation goals.
5. Append non-secret Sonar properties only.
6. Do not append `-Dsonar.token=...` by default.
7. If `BP_MAVEN_BUILD_ARGUMENTS` is unset, use a safe default such as:

```text
--batch-mode -Dmaven.test.skip=true package sonar:sonar
```

But if the application team already defines `BP_MAVEN_BUILD_ARGUMENTS`, that value is authoritative and should be preserved.

---

## Scanner Selection Logic

### `BP_SONARQUBE_SCANNER_MODE=auto`

Auto-detect project type:

```text
pom.xml                       -> maven-inline
build.gradle/build.gradle.kts -> gradle or cli, depending on plugin availability
sonar-project.properties      -> cli
package.json                  -> cli
requirements.txt/pyproject.toml -> cli
composer.json                 -> cli
fallback                      -> cli or no-op based on config
```

### `maven-inline`

For Java/Maven apps:

```text
Do not run Maven in SonarQube buildpack.
Modify BP_MAVEN_BUILD_ARGUMENTS for Paketo Java.
Paketo Java later runs package sonar:sonar.
```

### `cli`

For non-Java apps:

```bash
sonar-scanner \
  -Dsonar.host.url="$BP_SONARQUBE_URL" \
  -Dsonar.projectKey="$BP_SONARQUBE_PROJECT_KEY"
```

Prefer token via:

```bash
export SONAR_TOKEN="$BP_SONARQUBE_APIKEY"
```

### `gradle`

Gradle support should be added after MVP.

Gradle only works if the project has the SonarQube Gradle plugin configured. Detection should not blindly assume `./gradlew sonar` will work.

Recommended behavior:

```text
Gradle project + SonarQube plugin detected -> ./gradlew sonar
Gradle project without plugin             -> CLI scanner fallback or fail based on config
```

### `maven-separate`

This mode should not be used for the current Java rollout. It can exist as an emergency/manual mode only.

It would run:

```bash
mvn --batch-mode sonar:sonar
```

But this is discouraged because it may trigger extra dependency resolution and build work.

---

## Coverage and Test Reports

Important decision for current Java rollout:

```text
Maven tests should not run inside kpack builds.
```

Existing services commonly use:

```text
BP_MAVEN_BUILD_ARGUMENTS="--batch-mode -Dmaven.test.skip=true -X package"
```

Therefore:

- Do not change `-Dmaven.test.skip=true`.
- Do not add `verify`.
- Do not generate JaCoCo reports during kpack build.
- SonarQube analysis will upload code analysis and use compiled classes, but coverage may be missing.

If coverage is required later, it should be generated earlier in CI or by a dedicated test workflow, not by the kpack image build.

Optional later variable:

```text
BP_SONARQUBE_COVERAGE_REPORT_PATHS=target/site/jacoco/jacoco.xml
```

Mapping:

```text
-Dsonar.coverage.jacoco.xmlReportPaths=target/site/jacoco/jacoco.xml
```

Only add this when reports already exist.

---

## Auto Project Creation

If enabled:

```text
BP_SONARQUBE_AUTO_CREATE_PROJECT=true
```

The buildpack should:

1. Check whether `BP_SONARQUBE_PROJECT_KEY` exists in SonarQube.
2. If the project does not exist, create it through the SonarQube API.
3. Continue analysis.

Conceptual API calls:

```text
GET  /api/projects/search?projects=<projectKey>
POST /api/projects/create?project=<projectKey>&name=<projectName>
```

Requirements:

- The token must have permission to create projects.
- If auto-create is enabled and creation fails, fail the build.
- If auto-create is disabled and project is missing, behavior should be controlled by `BP_SONARQUBE_FAIL_ON_MISSING_PROJECT` or fail by default when enabled.

Recommended default:

```text
BP_SONARQUBE_AUTO_CREATE_PROJECT=true
```

---

## Secret Handling

`BP_SONARQUBE_APIKEY` must not be stored in a ConfigMap.

Use a Kubernetes Secret and inject it into the kpack build pod as an env var:

```yaml
- name: BP_SONARQUBE_APIKEY
  valueFrom:
    secretKeyRef:
      name: sonarqube-credentials
      key: token
```

Non-secret values can come from ConfigMaps:

```yaml
- name: BP_SONARQUBE_ENABLED
  value: "true"
- name: BP_SONARQUBE_URL
  value: "https://sonarqube.example.com"
- name: BP_SONARQUBE_PROJECT_KEY
  value: "prod-bs23-ib-notification-service"
- name: BP_SONARQUBE_PROJECT_NAME
  value: "bs23-ib-notification-service"
- name: BP_SONARQUBE_BRANCH
  value: "ncc/deployment/release"
- name: BP_SONARQUBE_STRICT
  value: "false"
```

Security requirements:

1. Do not print the token.
2. Do not use `set -x` in buildpack scripts.
3. Do not persist token in launch layers.
4. Do not write token into `BP_MAVEN_BUILD_ARGUMENTS` unless there is no compatible alternative.
5. Do not allow `BP_SONARQUBE_APIKEY` to be placed in the build ConfigMap.

---

## Existing Workflow Template Security Gap

Current file:

```text
/home/noman637/Projects/BS23/fintech-dev-cluster-revamped/deployments/infrastructure/argo/workflow-templates/generate-kpack-manifest-template.yaml
```

Current behavior:

```sh
set -x
...
CONFIGMAP_DATA=$(jq -r '.data | to_entries | map("      - name: \"" + .key + "\"\n        value: \"" + .value + "\"") | join("\n")' "$CONFIGMAP_FILE")
...
cat /workspace/kpack/manifest.yaml
```

This is acceptable only if the SonarQube token is never in the ConfigMap.

Required future changes:

1. Inject `BP_SONARQUBE_APIKEY` using `valueFrom.secretKeyRef`.
2. Prevent `BP_SONARQUBE_APIKEY` from being copied from ConfigMap into the manifest.
3. Consider removing `set -x` or redacting output when secret env support is added.
4. Avoid printing generated manifests if they ever contain sensitive values.

---

## kpack Image Env Injection

Current generated kpack Image manifests come from:

```text
/home/noman637/Projects/BS23/fintech-dev-cluster-revamped/deployments/infrastructure/argo/workflow-templates/generate-kpack-manifest-template.yaml
```

It currently reads ConfigMap data and converts entries into env vars:

```sh
CONFIGMAP_DATA=$(jq -r '.data | to_entries | map("      - name: \"" + .key + "\"\n        value: \"" + .value + "\"") | join("\n")' "$CONFIGMAP_FILE")
```

This is fine for non-secret variables, but not for the API key.

Desired env section:

```yaml
env:
- name: BP_SONARQUBE_ENABLED
  value: "true"
- name: BP_SONARQUBE_URL
  value: "https://sonarqube.example.com"
- name: BP_SONARQUBE_PROJECT_KEY
  value: "prod-bs23-ib-notification-service"
- name: BP_SONARQUBE_PROJECT_NAME
  value: "bs23-ib-notification-service"
- name: BP_SONARQUBE_BRANCH
  value: "ncc/deployment/release"
- name: BP_SONARQUBE_STRICT
  value: "false"
- name: BP_SONARQUBE_APIKEY
  valueFrom:
    secretKeyRef:
      name: sonarqube-credentials
      key: token
```

Implementation options:

### Option A: Fixed secret name

Use a standard secret name in every namespace:

```text
sonarqube-credentials
```

with key:

```text
token
```

Template generation can add the `valueFrom` block when `BP_SONARQUBE_ENABLED=true`.

### Option B: Configurable secret name/key

Pass these as workflow parameters:

```text
sonarqube-secret-name
sonarqube-secret-key
```

This is more flexible but requires changing workflow templates and callers.

Recommended initial approach: Option A.

---

## Kubernetes Secret Example

Create this secret in namespaces where kpack Image resources are created:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: sonarqube-credentials
  namespace: application-namespace
type: Opaque
stringData:
  token: "replace-with-token"
```

If builds run in many namespaces, manage this Secret through ArgoCD or External Secrets.

The token needs permissions for:

```text
Execute Analysis
Create Projects, if BP_SONARQUBE_AUTO_CREATE_PROJECT=true
```

---

## Buildpack Repository Layout

Create a new repository or directory, for example:

```text
sonarqube-cnb/
  buildpack.toml
  package.toml
  project.toml
  bin/
    detect
    build
  vendor/
    sonar-scanner/
  scripts/
    package.sh
    test-local.sh
  README.md
```

### `buildpack.toml`

Example:

```toml
api = "0.10"

[buildpack]
id = "bs23-buildpacks/sonarqube"
version = "0.1.0"
name = "BS23 SonarQube Buildpack"
```

For Buildpack API `0.10`, stack declarations are not always required in the buildpack descriptor. Confirm against the lifecycle/kpack version in use.

### `package.toml`

Example:

```toml
[buildpack]
uri = "."
```

Do not treat SonarScanner CLI as a `package.toml` buildpack dependency. Vendor the scanner files inside the buildpack image, for example under:

```text
vendor/sonar-scanner/
```

The buildpack should add the scanner to `PATH` only during the build phase.

---

## Packaging SonarScanner CLI

Package SonarScanner CLI inside the buildpack image instead of downloading it during each build.

Reason:

- kpack build pods may not have internet access.
- Builds should be deterministic.
- Downloading scanner every build is slow and fragile.

Preferred option:

```text
SonarScanner CLI with embedded JRE
```

This makes the buildpack usable for Node.js, PHP, Python, and other non-Java projects.

Architecture requirement:

```text
Confirm kpack node architecture: linux/amd64 or linux/arm64.
```

If all build nodes are `amd64`, package amd64 first. If mixed architecture is possible, prepare multi-arch buildpack images or scanner variants.

---

## Maven/Gradle Dependency Mirror Requirement

Even with a vendored SonarScanner CLI, Java Maven inline mode may need to resolve the Sonar Maven plugin:

```text
org.sonarsource.scanner.maven:sonar-maven-plugin
```

Gradle mode may need:

```text
org.sonarqube Gradle plugin
```

Therefore the kpack build environment must have:

- internet access, or
- Nexus/Artifactory mirror configuration that serves these plugins.

This is especially important because existing builds already configure dependency mirrors such as:

```text
BP_DEPENDENCY_MIRROR_GITHUB_COM=https://nexus.internal.fintech23.xyz/repository/github-public
```

Need to verify Maven repository settings for Sonar Maven plugin resolution before rollout.

---

## Detection Behavior

`bin/detect` should:

1. Read `BP_SONARQUBE_ENABLED`.
2. If not enabled, exit `100`.
3. If enabled, validate required config.
4. Exit `0` if SonarQube should run.
5. Exit non-zero if enabled but invalid/missing required config.

Pseudo-logic:

```bash
#!/usr/bin/env bash
set -euo pipefail

case "${BP_SONARQUBE_ENABLED:-false}" in
  true|TRUE|True|1|yes|YES)
    ;;
  false|FALSE|False|0|no|NO|"")
    echo "SonarQube buildpack disabled: BP_SONARQUBE_ENABLED is not true"
    exit 100
    ;;
  *)
    echo "Invalid BP_SONARQUBE_ENABLED value: ${BP_SONARQUBE_ENABLED}"
    exit 1
    ;;
esac

if [[ -z "${BP_SONARQUBE_URL:-}" ]]; then
  echo "SonarQube buildpack enabled but BP_SONARQUBE_URL is missing"
  exit 1
fi

if [[ -z "${BP_SONARQUBE_APIKEY:-}" ]]; then
  echo "SonarQube buildpack enabled but BP_SONARQUBE_APIKEY is missing"
  exit 1
fi

if [[ -z "${BP_SONARQUBE_PROJECT_KEY:-}" ]]; then
  echo "SonarQube buildpack enabled but BP_SONARQUBE_PROJECT_KEY is missing"
  exit 1
fi

exit 0
```

Because the buildpack will be marked `optional: true`, `exit 100` allows normal builds to continue when SonarQube is disabled.

---

## Build Behavior

`bin/build` should:

1. Enter/read the application workspace.
2. Resolve scanner mode.
3. Create SonarQube project if configured.
4. For Maven Java, contribute build-time env for Paketo Java and exit.
5. For non-Java CLI mode, run vendored `sonar-scanner`.
6. Fail if scanner/project creation fails when enabled.
7. Avoid contributing launch layers.

Pseudo-logic:

```bash
#!/usr/bin/env bash
set -euo pipefail

MODE="${BP_SONARQUBE_SCANNER_MODE:-auto}"
STRICT="${BP_SONARQUBE_STRICT:-false}"
QUALITYGATE_WAIT="false"

if [[ "$STRICT" == "true" ]]; then
  QUALITYGATE_WAIT="true"
fi

# Build common non-secret args:
SONAR_ARGS=(
  "-Dsonar.host.url=${BP_SONARQUBE_URL}"
  "-Dsonar.projectKey=${BP_SONARQUBE_PROJECT_KEY}"
  "-Dsonar.qualitygate.wait=${QUALITYGATE_WAIT}"
)

if [[ -n "${BP_SONARQUBE_PROJECT_NAME:-}" ]]; then
  SONAR_ARGS+=("-Dsonar.projectName=${BP_SONARQUBE_PROJECT_NAME}")
fi

if [[ -n "${BP_SONARQUBE_BRANCH:-}" ]]; then
  SONAR_ARGS+=("-Dsonar.branch.name=${BP_SONARQUBE_BRANCH}")
fi

# Do not echo token.
export SONAR_TOKEN="${BP_SONARQUBE_APIKEY}"
```

---

## kpack Integration

### 1. Add buildpack image to ClusterStore

File:

```text
/home/noman637/Projects/BS23/fintech-dev-cluster-revamped/deployments/infrastructure/argo/kpack/clusterstore-default.yaml
```

Add:

```yaml
- image: harbor.local.fintech23.xyz/buildpacks/sonarqube-cnb:0.1.0
```

Example result:

```yaml
spec:
  sources:
  - image: harbor.local.fintech23.xyz/dockerhub/paketobuildpacks/java
  - image: harbor.local.fintech23.xyz/dockerhub/paketobuildpacks/nodejs
  - image: harbor.local.fintech23.xyz/dockerhub/paketobuildpacks/web-servers
  - image: harbor.local.fintech23.xyz/dockerhub/paketobuildpacks/opentelemetry
  - image: harbor.local.fintech23.xyz/dockerhub/paketobuildpacks/java-native-image
  - image: harbor.local.fintech23.xyz/dockerhub/paketobuildpacks/graalvm
  - image: harbor.local.fintech23.xyz/buildpacks/sonarqube-cnb:0.1.0
```

### 2. Add buildpack before Java in Java ClusterBuilder order

File:

```text
/home/noman637/Projects/BS23/fintech-dev-cluster-revamped/deployments/infrastructure/argo/kpack/java-app-builder-jammy-base-default.yaml
```

Change to:

```yaml
order:
- group:
  - id: bs23-buildpacks/sonarqube
    optional: true
  - id: paketo-buildpacks/java
  - id: paketo-buildpacks/opentelemetry
```

Also update:

```text
/home/noman637/Projects/BS23/fintech-dev-cluster-revamped/deployments/infrastructure/argo/kpack/java-app-builder-jammy-full-default.yaml
```

with the same group order.

### 3. Consider other builders later

For non-Java builders, placement should be after the language buildpack, because CLI scanner should analyze after dependencies/build artifacts are available:

```yaml
order:
- group:
  - id: paketo-buildpacks/nodejs
  - id: bs23-buildpacks/sonarqube
    optional: true
```

Consider later:

```text
web-app-builder-jammy-base-default.yaml
python-app-builder-jammy-base.yaml
php-app-builder-jammy-full.yaml
```

Only after CLI scanner mode has been tested.

---

## Example Service ConfigMap

For the given Java service, non-secret config could look like:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: rel-prod-bs23-ib-notification-service-build-configmap
  namespace: cicd
data:
  BP_OPENTELEMETRY_ENABLED: "true"
  BP_JVM_VERSION: "17"
  BP_MAVEN_BUILD_ARGUMENTS: "--batch-mode -Dmaven.test.skip=true -X package"
  BP_SONARQUBE_ENABLED: "true"
  BP_SONARQUBE_URL: "https://sonarqube.example.com"
  BP_SONARQUBE_PROJECT_KEY: "prod-bs23-ib-notification-service"
  BP_SONARQUBE_PROJECT_NAME: "bs23-ib-notification-service"
  BP_SONARQUBE_BRANCH: "ncc/deployment/release"
  BP_SONARQUBE_STRICT: "false"
  BP_SONARQUBE_SCANNER_MODE: "auto"
  BP_SONARQUBE_AUTO_CREATE_PROJECT: "true"
```

Secret should be separate:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: sonarqube-credentials
  namespace: ib-app
type: Opaque
stringData:
  token: "replace-with-token"
```

Note: the Secret must exist in the namespace where the kpack `Image` resource/build pod is created.

---

## Local Development and Testing

### Build/package buildpack

Use `pack` to package and publish the buildpack image.

Example:

```bash
pack buildpack package harbor.local.fintech23.xyz/buildpacks/sonarqube-cnb:0.1.0 \
  --config package.toml
```

Push to Harbor if needed:

```bash
docker push harbor.local.fintech23.xyz/buildpacks/sonarqube-cnb:0.1.0
```

### Local Java app test

Use a sample Maven app:

```bash
pack build test-sonarqube-app \
  --builder harbor.local.fintech23.xyz/builders/java-app-builder-jammy-base-default \
  --env BP_SONARQUBE_ENABLED=true \
  --env BP_SONARQUBE_URL=https://sonarqube.example.com \
  --env BP_SONARQUBE_APIKEY=xxxxx \
  --env BP_SONARQUBE_PROJECT_KEY=test-sonarqube-app \
  --env BP_SONARQUBE_PROJECT_NAME=test-sonarqube-app \
  --env BP_SONARQUBE_STRICT=false \
  --env 'BP_MAVEN_BUILD_ARGUMENTS=--batch-mode -Dmaven.test.skip=true package'
```

Expected behavior:

- SonarQube buildpack detects `BP_SONARQUBE_ENABLED=true`.
- SonarQube project is created if missing and auto-create is enabled.
- SonarQube buildpack modifies Maven args for the Java buildpack.
- Paketo Java runs one Maven build with `package sonar:sonar`.
- Tests remain skipped.
- OpenTelemetry buildpack runs as before.
- Build only fails on quality gate if `BP_SONARQUBE_STRICT=true`.

---

## CI/CD Rollout Plan

### Phase 1: Java Maven inline MVP

- Create `sonarqube-cnb` repo.
- Implement `detect` using `BP_SONARQUBE_ENABLED`.
- Implement `build` for Maven inline mode only.
- Mutate `BP_MAVEN_BUILD_ARGUMENTS` through a build-only env layer.
- Export token as `SONAR_TOKEN` for build-time only.
- Verify Maven tests remain skipped.
- Test with one Maven service using `pack build`.

### Phase 2: Auto project creation

- Add SonarQube API client logic using `curl` or equivalent.
- Check if project exists.
- Create project if missing and `BP_SONARQUBE_AUTO_CREATE_PROJECT=true`.
- Validate token permissions.

### Phase 3: kpack integration in dev

- Publish buildpack image to Harbor.
- Add buildpack to `clusterstore-default.yaml`.
- Add buildpack before Java in Java builders.
- Apply through ArgoCD/kpack.
- Trigger one test service build.

### Phase 4: Secret/env integration

- Add `sonarqube-credentials` Secret in application build namespaces.
- Update manifest generation to inject `BP_SONARQUBE_APIKEY` from Secret.
- Keep non-secret SonarQube config in ConfigMap.
- Validate token is not printed in logs or manifest output.

### Phase 5: Non-Java CLI support

- Add vendored SonarScanner CLI with embedded JRE.
- Add CLI mode.
- Verify Node/Python/PHP analysis.
- Add buildpack after language buildpacks for non-Java builders.

### Phase 6: Gradle support

- Add Gradle plugin detection.
- Add Gradle scanner mode only when plugin exists.
- Fallback to CLI or fail based on config.

### Phase 7: Production rollout

- Roll out to Java base/full builders.
- Enable per service using `BP_SONARQUBE_ENABLED=true`.
- Start with `BP_SONARQUBE_STRICT=false`.
- Later enable strict mode for selected services.
- Monitor build time and SonarQube API/scanner failures.

---

## Failure Behavior

Recommended behavior:

| Scenario | Behavior |
|---|---|
| `BP_SONARQUBE_ENABLED=false` or unset | detect exits `100`, build continues |
| `BP_SONARQUBE_ENABLED=true` and URL missing | fail build |
| `BP_SONARQUBE_ENABLED=true` and API key missing | fail build |
| `BP_SONARQUBE_ENABLED=true` and project key missing | fail build unless generated by workflow |
| project missing and auto-create enabled | create project, continue |
| project missing and auto-create disabled | fail or follow `BP_SONARQUBE_FAIL_ON_MISSING_PROJECT` |
| scanner/upload fails | fail build |
| quality gate fails and `BP_SONARQUBE_STRICT=true` | fail build; image not published |
| quality gate fails and `BP_SONARQUBE_STRICT=false` | do not wait/block image publishing |
| Java Maven project | mutate Maven args; do not run separate scanner |
| non-Java project | run CLI scanner |
| unknown project type and fail-on-unknown false | no-op or CLI fallback |
| unknown project type and fail-on-unknown true | fail build |

---

## Logging Requirements

Logs should show:

```text
SonarQube Buildpack enabled
Detected scanner mode: maven-inline
SonarQube strict mode: false
SonarQube project key: prod-bs23-ib-notification-service
Prepared Maven inline SonarQube analysis
SonarQube project exists or was created
```

Logs must not show:

```text
BP_SONARQUBE_APIKEY
sonar.token=<token>
Authorization headers
SONAR_TOKEN value
```

Do not use `set -x` in buildpack scripts.

---

## Recommended Initial MVP

For the first version, keep scope small:

1. Optional buildpack.
2. Enable only when `BP_SONARQUBE_ENABLED=true`.
3. Java Maven inline only.
4. No test execution.
5. Modify `BP_MAVEN_BUILD_ARGUMENTS` for Paketo Java.
6. Use `SONAR_TOKEN` instead of `-Dsonar.token`.
7. Auto-create project if missing.
8. Add to Java kpack builders only.
9. Start with `BP_SONARQUBE_STRICT=false`.

After successful Java testing, add CLI mode for non-Java builders.

---

## Files Expected to Change in fintech-dev-cluster-revamped

```text
/home/noman637/Projects/BS23/fintech-dev-cluster-revamped/deployments/infrastructure/argo/kpack/clusterstore-default.yaml
/home/noman637/Projects/BS23/fintech-dev-cluster-revamped/deployments/infrastructure/argo/kpack/java-app-builder-jammy-base-default.yaml
/home/noman637/Projects/BS23/fintech-dev-cluster-revamped/deployments/infrastructure/argo/kpack/java-app-builder-jammy-full-default.yaml
/home/noman637/Projects/BS23/fintech-dev-cluster-revamped/deployments/infrastructure/argo/workflow-templates/generate-kpack-manifest-template.yaml
```

Potential new secret manifest:

```text
/home/noman637/Projects/BS23/fintech-dev-cluster-revamped/deployments/infrastructure/argo/kpack/sonarqube-credentials.yaml
```

or manage it separately with External Secrets.

---

## Open Questions

Resolved decisions:

1. Should SonarQube be mandatory for all Java app builds or only enabled per service?
   - Resolved: controlled per service by `BP_SONARQUBE_ENABLED`.
2. Should quality gate failure block image publishing?
   - Resolved: controlled by `BP_SONARQUBE_STRICT`.
3. Should Maven tests run inside kpack builds, or should CI generate coverage before kpack?
   - Resolved: Maven tests should not run inside kpack builds. Preserve `-Dmaven.test.skip=true`.
4. Should Java run separate scanner or reuse Maven build output?
   - Resolved: Java should use Maven inline mode by modifying `BP_MAVEN_BUILD_ARGUMENTS`.

Remaining questions:

1. Which SonarQube version is deployed?
2. Which SonarScanner CLI and Sonar Maven plugin versions are approved internally?
3. Does the kpack build environment have network access to SonarQube?
4. Does Nexus/Artifactory already mirror the Sonar Maven plugin?
5. Should the token be global or per project/team?
6. Should branch analysis use `sonar.branch.name` for all branches, and is the SonarQube edition licensed for branch analysis?
7. Should PR decoration be supported later?
8. Should non-Java scanner support be added to all builders or only selected builders?
