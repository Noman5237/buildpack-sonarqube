# SonarQube Buildpack Project Task List

## Phase 0: Confirm Decisions and Prerequisites

- [ ] Ensure SonarQube server URL is sourced from workflow/manifest params and passed through kpack `Image.spec.build.env`.
- [ ] Confirm SonarQube edition is **Community** and explicitly document: no branch analysis support, no PR decoration support.
- [ ] Update buildpack logic to **not** append/use branch-related scanner args in Community mode.
- [ ] Confirm kpack build pods can reach the SonarQube server URL.
- [ ] Confirm approved Sonar Maven/CLI versions strategy:
  - [ ] Use latest supported versions at implementation/release time.
  - [ ] Add notes to pin versions only when enterprise policy requires reproducibility.
- [ ] Confirm kpack build pods can resolve/download Sonar Maven plugin via Nexus/Artifactory mirror.
- [ ] Confirm kpack build node architecture is `linux/amd64`.
- [ ] Confirm single global CI token approach:
  - [ ] One global SonarQube token can be used for all services.
  - [ ] Token has at least:
    - [ ] Execute Analysis
    - [ ] Create Projects

---

## Phase 1: Create Buildpack Repository/Directory

- [ ] Create the buildpack project directory, for example `sonarqube-cnb/`.
- [ ] Add base repository layout:

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

- [ ] Create `buildpack.toml` with buildpack id:

```text
bs23-buildpacks/sonarqube
```

- [ ] Create `package.toml` for packaging with `pack buildpack package`.
- [ ] Add executable permissions for:
  - [ ] `bin/detect`
  - [ ] `bin/build`
- [ ] Add initial README with supported env vars and behavior.

---

## Phase 2: Implement Detect Logic

- [ ] Implement `bin/detect`.
- [ ] Add `BP_SONARQUBE_ENABLED` handling:
  - [ ] `false`, unset, `0`, `no` -> exit `100`
  - [ ] `true`, `1`, `yes` -> continue detection
  - [ ] invalid value -> fail with exit `1`
- [ ] Validate required variables when enabled:
  - [ ] `BP_SONARQUBE_URL` (from params)
  - [ ] `BP_SONARQUBE_APIKEY`
  - [ ] `BP_SONARQUBE_REPO_NAME`
  - [ ] `BP_SONARQUBE_REPO_BRANCH`
- [ ] Ensure missing required variables fail only when `BP_SONARQUBE_ENABLED=true`.
- [ ] Ensure disabled mode exits `100` so optional buildpack does not block normal builds.
- [ ] Ensure detect logs do not print token values.

---

## Phase 3: Implement Java/Maven Inline Build Logic MVP

- [ ] Implement `bin/build` for Maven inline mode.
- [ ] Detect Maven project using `pom.xml`.
- [ ] Automatically detect Maven projects using `pom.xml`; do not require `BP_SONARQUBE_SCANNER_MODE`.
- [ ] Format `BP_SONARQUBE_REPO_NAME` and `BP_SONARQUBE_REPO_BRANCH` to lowercase letters, numbers, and dashes only.
- [ ] Generate project name/key as `<formatted-repo-name>-<formatted-repo-branch>` when overrides are empty.
- [ ] Use the same effective value for SonarQube project name and project key.
- [ ] For Maven projects, do not execute Maven from the SonarQube buildpack.
- [ ] Read existing `BP_MAVEN_BUILD_ARGUMENTS`.
- [ ] Preserve existing Maven args exactly where possible.
- [ ] Append `sonar:sonar` only if not already present.
- [ ] Preserve `-Dmaven.test.skip=true` if already present.
- [ ] Do not add `verify`.
- [ ] Do not add test execution goals.
- [ ] Do not add coverage generation goals.
- [ ] Append non-secret Sonar properties:
  - [ ] `-Dsonar.host.url=...`
  - [ ] `-Dsonar.projectKey=...`
  - [ ] `-Dsonar.projectName=...`, if provided
  - [ ] `-Dsonar.qualitygate.wait=...`
  - [ ] extra args from `BP_SONARQUBE_EXTRA_ARGS`, if provided
- [ ] Community mode: do **not** append `-Dsonar.branch.name` (no branch/PR support).
- [ ] Map `BP_SONARQUBE_STRICT=true` to `sonar.qualitygate.wait=true`.
- [ ] Map `BP_SONARQUBE_STRICT=false` or unset to `sonar.qualitygate.wait=false`.
- [ ] Export token as build-time `SONAR_TOKEN`.
- [ ] Avoid putting token into `BP_MAVEN_BUILD_ARGUMENTS`.
- [ ] Write a build-only CNB layer that overrides/sets env for later buildpacks:
  - [ ] `BP_MAVEN_BUILD_ARGUMENTS.override`
  - [ ] `SONAR_TOKEN.override`
  - [ ] `SONAR_HOST_URL.override`, if useful
- [ ] Mark the layer:
  - [ ] `build = true`
  - [ ] `launch = false`
  - [ ] `cache = false`
- [ ] Ensure logs show selected mode and project key.
- [ ] Ensure logs never show API key/token.

---

## Phase 4: Implement SonarQube Project Auto-Creation

- [ ] Add support for `BP_SONARQUBE_AUTO_CREATE_PROJECT`.
- [ ] Default `BP_SONARQUBE_AUTO_CREATE_PROJECT=true`.
- [ ] Query SonarQube project existence using API.
- [ ] Create project if missing and auto-create is enabled.
- [ ] Use the effective project name as the SonarQube project key.
- [ ] Keep `BP_SONARQUBE_PROJECT_NAME` and `BP_SONARQUBE_PROJECT_KEY` optional overrides; generate from repo name/branch when empty.
- [ ] Fail build if project creation fails while auto-create is enabled.
- [ ] Fail or controlled no-op if project missing and auto-create is disabled.
- [ ] Ensure API calls do not print Authorization headers or token.

---

## Phase 5: Package Buildpack Image

- [ ] Package buildpack locally using `pack buildpack package`.
- [ ] Tag initial image:

```text
harbor.local.fintech23.xyz/buildpacks/sonarqube-cnb:0.1.0
```

- [ ] Push image to Harbor.
- [ ] Verify kpack service account can pull the buildpack image.
- [ ] Verify image is compatible with current kpack/lifecycle version.

---

## Phase 6: Local Validation with `pack build`

- [ ] Create or select a sample Maven project.
- [ ] Run local `pack build` with Java builder.
- [ ] Pass required env vars:
  - [ ] `BP_SONARQUBE_ENABLED=true`
  - [ ] `BP_SONARQUBE_URL`
  - [ ] `BP_SONARQUBE_APIKEY`
  - [ ] `BP_SONARQUBE_PROJECT_KEY`
  - [ ] `BP_SONARQUBE_STRICT=false`
  - [ ] `BP_MAVEN_BUILD_ARGUMENTS="--batch-mode -Dmaven.test.skip=true package"`
- [ ] Verify Maven runs only once.
- [ ] Verify Maven tests are skipped.
- [ ] Verify final Maven command includes `package sonar:sonar`.
- [ ] Verify analysis appears in SonarQube.
- [ ] Verify token is not printed in logs.
- [ ] Test disabled behavior with `BP_SONARQUBE_ENABLED=false`.
- [ ] Test strict mode with `BP_SONARQUBE_STRICT=true`.

---

## Phase 7: kpack ClusterStore Integration

- [ ] Update:

```text
/home/noman637/Projects/BS23/fintech-dev-cluster-revamped/deployments/infrastructure/argo/kpack/clusterstore-default.yaml
```

- [ ] Add buildpack image source:

```yaml
- image: harbor.local.fintech23.xyz/buildpacks/sonarqube-cnb:0.1.0
```

- [ ] Apply through ArgoCD/dev environment.
- [ ] Verify kpack ClusterStore status is ready.
- [ ] Verify buildpack id `bs23-buildpacks/sonarqube` is visible to kpack.

---

## Phase 8: Java Builder Integration

- [ ] Update Java base builder:

```text
/home/noman637/Projects/BS23/fintech-dev-cluster-revamped/deployments/infrastructure/argo/kpack/java-app-builder-jammy-base-default.yaml
```

- [ ] Change order to put SonarQube before Java:

```yaml
order:
- group:
  - id: bs23-buildpacks/sonarqube
    optional: true
  - id: paketo-buildpacks/java
  - id: paketo-buildpacks/opentelemetry
```

- [ ] Update Java full builder:

```text
/home/noman637/Projects/BS23/fintech-dev-cluster-revamped/deployments/infrastructure/argo/kpack/java-app-builder-jammy-full-default.yaml
```

- [ ] Apply through ArgoCD/dev environment.
- [ ] Verify both ClusterBuilders become ready.
- [ ] Verify normal Java builds still work when `BP_SONARQUBE_ENABLED=false` or unset.

---

## Phase 9: Secret Injection Support

- [ ] Create/maintain one global CI token value for SonarQube across environments.
- [ ] Provision Secret(s) that hold:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: sonarqube-credentials
  namespace: <application-build-namespace>
type: Opaque
stringData:
  token: <replace-with-global-ci-token>
```

- [ ] Ensure namespaces where kpack `Image` resources are created have access to the token.
- [ ] Update:

```text
/home/noman637/Projects/BS23/fintech-dev-cluster-revamped/deployments/infrastructure/argo/workflow-templates/generate-kpack-manifest-template.yaml
```

- [ ] Add logic to inject `BP_SONARQUBE_APIKEY` from Secret when SonarQube is enabled.
- [ ] Prevent `BP_SONARQUBE_APIKEY` from being copied from ConfigMap data.
- [ ] Keep non-secret SonarQube values in ConfigMap.
- [ ] Consider removing or reducing `set -x` in the manifest generation script.
- [ ] Ensure generated manifest output does not expose sensitive values.
- [ ] Verify generated kpack `Image` contains:

```yaml
- name: BP_SONARQUBE_APIKEY
  valueFrom:
    secretKeyRef:
      name: sonarqube-credentials
      key: token
```

---

## Phase 10: Service-Level Configuration

- [ ] For first pilot Java service, update its build ConfigMap with:

```yaml
BP_SONARQUBE_ENABLED: "true"
BP_SONARQUBE_URL: "https://sonarqube.example.com"
BP_SONARQUBE_REPO_NAME: "<repo-name>"
BP_SONARQUBE_REPO_BRANCH: "<repo-branch>"
BP_SONARQUBE_STRICT: "false"
BP_SONARQUBE_AUTO_CREATE_PROJECT: "true"
```

- [ ] **Do not** rely on branch-specific sonar args for Community (no branch/PR support).
- [ ] Keep existing Maven args unchanged except for current service requirements:

```yaml
BP_MAVEN_BUILD_ARGUMENTS: "--batch-mode -Dmaven.test.skip=true -X package"
```

- [ ] Ensure `BP_SONARQUBE_APIKEY` is not present in the ConfigMap.
- [ ] Trigger kpack build for the pilot service.
- [ ] Verify image build succeeds.
- [ ] Verify tests did not run.
- [ ] Verify SonarQube project was created if missing.
- [ ] Verify analysis uploaded successfully.

---

## Phase 11: Strict Mode Validation

- [ ] Enable strict mode in a non-critical test service:

```yaml
BP_SONARQUBE_STRICT: "true"
```

- [ ] Verify `sonar.qualitygate.wait=true` is passed.
- [ ] Verify build succeeds when quality gate passes.
- [ ] Verify build fails when quality gate fails.
- [ ] Confirm failed quality gate blocks image publishing.
- [ ] Document strict mode behavior for application teams.

---

## Phase 12: Observability and Logging Validation

- [ ] Review kpack build logs.
- [ ] Confirm logs include:
  - [ ] SonarQube enabled/disabled status
  - [ ] selected scanner mode
  - [ ] project key
  - [ ] strict mode status
  - [ ] project creation result
- [ ] Confirm logs do not include:
  - [ ] `BP_SONARQUBE_APIKEY` value
  - [ ] `SONAR_TOKEN` value
  - [ ] `sonar.token=<token>`
  - [ ] Authorization headers
- [ ] Confirm token is not persisted in final image environment.
- [ ] Confirm no SonarQube runtime/launch layer is added.

---

## Phase 13: Documentation for App Teams

- [ ] Document required service ConfigMap variables.
- [ ] Document required Secret setup using one global CI token.
- [ ] Document default behavior when disabled.
- [ ] Document strict mode behavior.
- [ ] Document Java-specific behavior:
  - [ ] SonarQube runs inside Maven build.
  - [ ] Tests are not run.
  - [ ] Coverage is not generated by kpack.
- [ ] Document that SonarQube Community does not support branch/PR analysis.
- [ ] Document troubleshooting steps:
  - [ ] missing token
  - [ ] missing project key
  - [ ] SonarQube network failure
  - [ ] Maven plugin resolution failure
  - [ ] quality gate failure

---

## Phase 14: Non-Java CLI Support Later

- [ ] Vendor SonarScanner CLI with embedded JRE under `vendor/sonar-scanner/`.
- [ ] Add CLI scanner mode.
- [ ] Add project detection for:
  - [ ] `sonar-project.properties`
  - [ ] `package.json`
  - [ ] `requirements.txt`
  - [ ] `pyproject.toml`
  - [ ] `composer.json`
- [ ] Add scanner cache layer if useful:
  - [ ] `build = true`
  - [ ] `launch = false`
  - [ ] `cache = true`
- [ ] Ensure cache does not store tokens.
- [ ] Test Node.js project.
- [ ] Test Python project.
- [ ] Test PHP project.
- [ ] Add buildpack to non-Java builders only after successful validation.

---

## Phase 15: Gradle Support Later

- [ ] Detect Gradle projects:
  - [ ] `build.gradle`
  - [ ] `build.gradle.kts`
  - [ ] `gradlew`
- [ ] Detect whether SonarQube Gradle plugin is configured.
- [ ] Use `./gradlew sonar` only when plugin exists.
- [ ] Fallback to CLI scanner or fail based on config.
- [ ] Ensure token is passed securely via environment.
- [ ] Validate no unnecessary test execution happens unless explicitly configured by project.

---

## Phase 16: Production Rollout

- [ ] Roll out buildpack to Java base and full builders.
- [ ] Keep `BP_SONARQUBE_ENABLED=false` by default.
- [ ] Enable SonarQube per service through ConfigMap only when needed.
- [ ] Start pilot services with:

```yaml
BP_SONARQUBE_STRICT: "false"
```

- [ ] Monitor build time impact.
- [ ] Monitor SonarQube server load.
- [ ] Monitor Maven dependency/plugin resolution failures.
- [ ] Monitor quality gate results.
- [ ] Gradually enable strict mode for selected services.
- [ ] Prepare rollback plan:
  - [ ] set `BP_SONARQUBE_ENABLED=false`, or
  - [ ] remove SonarQube buildpack from builder order, or
  - [ ] rollback ClusterBuilder/ClusterStore version.

---

## Acceptance Criteria

- [ ] Normal Java app builds work when SonarQube is disabled.
- [ ] SonarQube runs only when `BP_SONARQUBE_ENABLED=true`.
- [ ] Java/Maven builds run Maven only once.
- [ ] Maven tests remain skipped.
- [ ] `BP_MAVEN_BUILD_ARGUMENTS` is preserved and extended correctly.
- [ ] SonarQube project is automatically created when configured.
- [ ] Analysis is uploaded to SonarQube.
- [ ] `BP_SONARQUBE_STRICT=false` does not block image publishing on quality gate.
- [ ] `BP_SONARQUBE_STRICT=true` blocks image publishing when quality gate fails.
- [ ] SonarQube token is never printed or stored in final image.
- [ ] Buildpack does not add runtime/launch layers.
- [ ] No branch/PR-specific logic is used (Community compatibility confirmed).
