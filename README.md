# SonarQube Buildpack (CNB for Paketo Java flow)

A Cloud Native Buildpack (`noman5237-buildpacks/sonarqube`) that runs alongside Paketo Java in a kpack builder. When enabled, it does **not** execute Maven or Gradle itself — it mutates `BP_MAVEN_ADDITIONAL_BUILD_ARGUMENTS` (Maven) or `BP_GRADLE_ADDITIONAL_BUILD_ARGUMENTS` (Gradle) so the downstream Paketo buildpack runs the SonarQube analysis in a single build invocation. This avoids a second compile and keeps build time close to baseline.

This file is the single source of truth for the buildpack. Operational checklists live in [`tasks.md`](./tasks.md).

---

## Platform assumptions

- **Target:** Java on `linux/amd64`
- **SonarQube edition:** Community
  - No native branch analysis, no PR decoration
  - Branch isolation is achieved by generating a per-branch project name/key
- **Token source:** Kubernetes Secret (never ConfigMap)
- **Buildpack API:** `0.10`
- **Maven:** Sonar Maven plugin must be reachable from the build pod (direct or via internal Nexus/Artifactory mirror)
- **Gradle:** Project must have the `org.sonarqube` plugin applied (e.g., via `fintech-psp-conventions`). Plugin version 7.x is required for Gradle 9 compatibility.

---

## How it integrates with Paketo

The buildpack runs **before** `paketo-buildpacks/java` in the builder group:

```yaml
order:
- group:
  - id: noman5237-buildpacks/sonarqube
    optional: true
  - id: paketo-buildpacks/java
  - id: paketo-buildpacks/opentelemetry
```

Because buildpacks execute in order, this one contributes a **build-only layer** (`sonarqube-env`) whose `env/*.override` files are picked up by the subsequent Paketo Java buildpack in the same build:

| Layer env file | Project type | Effect |
|---|---|---|
| `BP_MAVEN_ADDITIONAL_BUILD_ARGUMENTS.override` | Maven | appends `sonar:sonar` + Sonar properties to Paketo Maven's extra args |
| `BP_GRADLE_ADDITIONAL_BUILD_ARGUMENTS.override` | Gradle | appends `sonar` + Sonar properties to Paketo Gradle's extra args |

Layer metadata: `build = true`, `launch = false`, `cache = false` — none of these values reach the runtime image.

---

## Behavior

### `bin/detect`

- Reads `BP_SONARQUBE_ENABLED`:
  - `false`/unset → exit `100` (optional skip)
  - `true` → continue
  - invalid → exit `1`
- Requires `BP_SONARQUBE_URL` and `BP_SONARQUBE_APIKEY`
- Requires either (`BP_SONARQUBE_PROJECT_NAME` + `BP_SONARQUBE_PROJECT_KEY`) or (`BP_SONARQUBE_REPO_NAME` + `BP_SONARQUBE_REPO_BRANCH`)
- Slugifies repo name + branch (lowercase, non-`[a-z0-9]` → `-`); each must contain at least one alphanumeric
- Requires `pom.xml` (Maven) or `build.gradle`/`build.gradle.kts` (Gradle) in the source root — neither found → exit `100`

### `bin/build`

1. Detects project type from `pom.xml` → `maven`, `build.gradle`/`build.gradle.kts` → `gradle`. No match → `exit 0`.
2. Resolves the effective **project name** (and uses the same value as **project key**):
   - Explicit: `BP_SONARQUBE_PROJECT_NAME` + `BP_SONARQUBE_PROJECT_KEY`
   - Generated: `<repo-name-slug>-<repo-branch-slug>` from `BP_SONARQUBE_REPO_NAME` + `BP_SONARQUBE_REPO_BRANCH`
3. Calls `GET /api/projects/search?projects=<key>`; if missing and `BP_SONARQUBE_AUTO_CREATE_PROJECT=true`, calls `POST /api/projects/create`. Failure → fail build.
4. Assembles Sonar properties:
   - `-Dsonar.host.url`, `-Dsonar.token`, `-Dsonar.projectKey`, `-Dsonar.projectName`, `-Dsonar.qualitygate.wait`
   - `-Dsonar.projectVersion` if `BP_SONARQUBE_PROJECT_VERSION` is set
   - `BP_SONARQUBE_EXTRA_ARGS` appended verbatim if set
5. Writes a single `*.override` file into the build layer:
   - Maven: `BP_MAVEN_ADDITIONAL_BUILD_ARGUMENTS.override` ← `sonar:sonar <sonar-props>`
   - Gradle: `BP_GRADLE_ADDITIONAL_BUILD_ARGUMENTS.override` ← `sonar <sonar-props>`

---

## Environment variables

### Always required when `BP_SONARQUBE_ENABLED=true`

| Name | Notes |
|---|---|
| `BP_SONARQUBE_ENABLED` | `true` to activate; `false`/unset to skip |
| `BP_SONARQUBE_URL` | e.g. `https://sonarqube.example.com` |
| `BP_SONARQUBE_APIKEY` | **must come from a Kubernetes Secret** |

### Project identity — one of the two pairs is required

Either supply an explicit project identity:

| Name | Notes |
|---|---|
| `BP_SONARQUBE_PROJECT_NAME` | SonarQube project name (display) |
| `BP_SONARQUBE_PROJECT_KEY` | SonarQube project key (unique identifier) |

Or let the buildpack generate it from the source coordinates:

| Name | Notes |
|---|---|
| `BP_SONARQUBE_REPO_NAME` | source repo name — slugified to `[a-z0-9-]` |
| `BP_SONARQUBE_REPO_BRANCH` | source branch name — slugified to `[a-z0-9-]` |

When `BP_SONARQUBE_PROJECT_NAME` **and** `BP_SONARQUBE_PROJECT_KEY` are both set they take precedence; `REPO_NAME`/`REPO_BRANCH` are not required. When either project var is absent, `REPO_NAME` + `REPO_BRANCH` are required and the generated key/name will be `<repo-slug>-<branch-slug>` (same value for both).

Slugification: lowercase, all non-`[a-z0-9]` runs replaced with a single `-`, leading/trailing dashes stripped.

### Optional (with defaults)

| Name | Default | Effect |
|---|---|---|
| `BP_SONARQUBE_STRICT` | `false` | `true` → `-Dsonar.qualitygate.wait=true` (build fails on QG failure) |
| `BP_SONARQUBE_AUTO_CREATE_PROJECT` | `true` | `false` → fail when project missing |
| `BP_SONARQUBE_PROJECT_VERSION` | unset | sets `-Dsonar.projectVersion` |
| `BP_SONARQUBE_EXTRA_ARGS` | unset | appended verbatim to the Sonar properties |
| `BP_SONARQUBE_SAMPLER_PROBABILITY` | `0.1` | fraction of builds that run analysis (0 = never, 1 = always, 0.1 = 10%) |

---

## Failure matrix

| Scenario | Outcome |
|---|---|
| `BP_SONARQUBE_ENABLED` unset / `false` | detect `exit 100`; build continues without SonarQube |
| `BP_SONARQUBE_ENABLED=true`, any required var missing | detect fails |
| Enabled but no `pom.xml` or `build.gradle` found | detect `exit 100` |
| Sampler rolls above threshold | detect `exit 100`; build continues without SonarQube |
| `BP_SONARQUBE_SAMPLER_PROBABILITY` not a number or out of 0–1 range | detect fails |
| Project missing, auto-create enabled | project created, build continues |
| Project missing, auto-create disabled | build fails |
| Project create API call fails | build fails |
| Strict mode + quality gate fails | build tool (in next buildpack) fails → image not published |
| Non-strict + quality gate fails | analysis uploaded, image still publishes |
| Invalid boolean value for any `_ENABLED`/`_STRICT`/`_AUTO_CREATE_PROJECT` | build fails |
| Gradle project without `org.sonarqube` plugin applied | Gradle task `sonar` not found → build fails |

---

## Logging and security guarantees

What logs **always show**:

```
sonarqube-buildpack: Detected maven project for SonarQube analysis
sonarqube-buildpack: Repository: <name> -> <slug> / <branch> -> <slug>
sonarqube-buildpack: Generated project name/key: <slug>-<slug>
sonarqube-buildpack: SonarQube project <key> already exists | created
sonarqube-buildpack: SonarQube analysis appended to BP_MAVEN_ADDITIONAL_BUILD_ARGUMENTS (token redacted):
sonarqube-buildpack: sonar:sonar -Dsonar.host.url=... -Dsonar.token=*** ...
```

What logs **never show**:

- `BP_SONARQUBE_APIKEY` value
- `Authorization` header contents
- The actual token value (replaced with `***` in the logged command line)

Implementation choices that enforce this:

- No `set -x` in `bin/detect` or `bin/build`
- Token is injected as `-Dsonar.token=<value>` in the `*.override` env file inside a **build-only** layer; the log line redacts it to `***`
- Layer metadata `launch = false` keeps the token out of the runtime image

---

## kpack integration

### 1. Add the buildpack to the ClusterStore

```yaml
spec:
  sources:
  - image: harbor.local.fintech23.xyz/buildpacks/sonarqube-cnb:0.1.0
  # ...existing Paketo images
```

### 2. Add the buildpack to Java builder order

Both base and full Java builders should be updated to:

```yaml
order:
- group:
  - id: noman5237-buildpacks/sonarqube
    optional: true
  - id: paketo-buildpacks/java
  - id: paketo-buildpacks/opentelemetry
```

### 3. Inject the token from a Kubernetes Secret

Manifest generation must inject `BP_SONARQUBE_APIKEY` via `valueFrom.secretKeyRef`, not from a ConfigMap:

```yaml
env:
- name: BP_SONARQUBE_ENABLED
  value: "true"
- name: BP_SONARQUBE_URL
  value: "https://sonarqube.example.com"
- name: BP_SONARQUBE_REPO_NAME
  value: "<repo-name>"
- name: BP_SONARQUBE_REPO_BRANCH
  value: "<branch>"
- name: BP_SONARQUBE_STRICT
  value: "false"
- name: BP_SONARQUBE_APIKEY
  valueFrom:
    secretKeyRef:
      name: sonarqube-credentials
      key: token
```

The Secret must exist in each namespace where kpack `Image` resources are created. The token needs at least `Execute Analysis` and (if auto-create is on) `Create Projects` permissions.

---

## Packaging

```bash
./scripts/package.sh harbor.local.fintech23.xyz/buildpacks/sonarqube-cnb:0.1.0
docker push harbor.local.fintech23.xyz/buildpacks/sonarqube-cnb:0.1.0
```

The script wraps `pack buildpack package` against `package.toml`.

---

## Local testing

### Unit / integration tests

[`tests/pack.test.sh`](./tests/pack.test.sh) runs the detect and build scripts against fixture inputs using `pack`:

```bash
./tests/pack.test.sh
```

### Benchmarking

[`tests/benchmark.sh`](./tests/benchmark.sh) drives three back-to-back `pack build` runs against a real project and reports wall-clock timing for each scenario:

| Scenario | Typical wall time |
|---|---|
| SonarQube disabled | ~170 s |
| Enabled, strict=false | ~216 s |
| Enabled, strict=true | ~225 s |

```bash
export BP_SONARQUBE_URL=https://sonarqube.example.com
export BP_SONARQUBE_APIKEY=...
export BP_SONARQUBE_REPO_NAME=test-app
export BP_SONARQUBE_REPO_BRANCH=main
./tests/benchmark.sh
```

Expected for an enabled run:

- Build tool runs once, with `sonar:sonar` (Maven) or `sonar` (Gradle) appended to its args
- SonarQube project is created if missing
- Token never appears unredacted in `pack` output
- Build only fails on quality gate when `BP_SONARQUBE_STRICT=true`

---

## Current scope and future work

Implemented:

- Maven inline analysis via `BP_MAVEN_ADDITIONAL_BUILD_ARGUMENTS` env override
- Gradle inline analysis via `BP_GRADLE_ADDITIONAL_BUILD_ARGUMENTS` env override (requires `org.sonarqube` plugin on the project — provided by `fintech-psp-conventions`)
- SonarQube project auto-create
- Build-only layer that keeps token out of the runtime image

Not yet implemented (see [`tasks.md`](./tasks.md)):

- Vendored SonarScanner CLI for non-Java projects (Node/Python/PHP)
- Production rollout to non-Java builders
