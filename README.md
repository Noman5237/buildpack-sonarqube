# SonarQube Buildpack (CNB for Paketo Java flow)

A Cloud Native Buildpack (`bs23-buildpacks/sonarqube`) that runs alongside Paketo Java in a kpack builder. When enabled, it does **not** execute Maven itself — it mutates `BP_MAVEN_BUILD_ARGUMENTS` so the downstream Paketo Maven buildpack runs `package sonar:sonar` in a single Maven invocation. This avoids a second compile and keeps build time close to baseline.

This file is the single source of truth for the buildpack. Operational checklists live in [`tasks.md`](./tasks.md).

---

## Platform assumptions

- **Target:** Java on `linux/amd64`
- **SonarQube edition:** Community
  - No native branch analysis, no PR decoration
  - Branch isolation is achieved by generating a per-branch project name/key
- **Token source:** Kubernetes Secret (never ConfigMap)
- **Buildpack API:** `0.10`
- **Maven plugin resolution:** Sonar Maven plugin must be reachable from the build pod (direct or via internal Nexus/Artifactory mirror)

---

## How it integrates with Paketo

The buildpack runs **before** `paketo-buildpacks/java` in the builder group:

```yaml
order:
- group:
  - id: bs23-buildpacks/sonarqube
    optional: true
  - id: paketo-buildpacks/java
  - id: paketo-buildpacks/opentelemetry
```

Because buildpacks execute in order, this one contributes a **build-only layer** (`sonarqube-env`) whose `env/*.override` files are picked up by the subsequent Paketo Java buildpack in the same build:

| Layer env file | Effect |
|---|---|
| `BP_MAVEN_BUILD_ARGUMENTS.override` | replaces Maven args used by Paketo Maven |
| `SONAR_TOKEN.override` | exposes the Sonar token to the Maven plugin at build time |
| `SONAR_HOST_URL.override` | exposes the SonarQube URL at build time |

Layer metadata: `build = true`, `launch = false`, `cache = false` — none of these values reach the runtime image.

---

## Behavior

### `bin/detect`

- Reads `BP_SONARQUBE_ENABLED`:
  - `false`/unset → exit `100` (optional skip)
  - `true` → continue
  - invalid → exit `1`
- Requires `BP_SONARQUBE_URL`, `BP_SONARQUBE_APIKEY`, `BP_SONARQUBE_REPO_NAME`, `BP_SONARQUBE_REPO_BRANCH`
- Slugifies repo name + branch (lowercase, non-`[a-z0-9]` → `-`); each must contain at least one alphanumeric
- Requires a `pom.xml` in the source root — no `pom.xml` → exit `100`
- Writes a minimal plan with `[[provides]] name = "sonarqube"`

### `bin/build`

1. Re-validates enabled state and required env (no-op `exit 0` if disabled or no `pom.xml`).
2. Resolves the effective **project name** (and uses the same value as **project key**):
   - `BP_SONARQUBE_PROJECT_NAME` → `BP_SONARQUBE_PROJECT_KEY` → `<repo-name-slug>-<repo-branch-slug>`
3. Calls `GET /api/projects/search?projects=<key>`; if missing and `BP_SONARQUBE_AUTO_CREATE_PROJECT=true`, calls `POST /api/projects/create`. Failure → fail build.
4. Mutates Maven args:
   - Starts from `BP_MAVEN_BUILD_ARGUMENTS` or default `--batch-mode -Dmaven.test.skip=true package`
   - Appends `sonar:sonar` if absent
   - Appends `-Dsonar.host.url`, `-Dsonar.projectKey`, `-Dsonar.projectName`, `-Dsonar.qualitygate.wait` (only if not already present)
   - Appends `BP_SONARQUBE_EXTRA_ARGS` verbatim if set
   - Never appends `-Dsonar.token=...` — token flows via `SONAR_TOKEN` env
   - Never appends `sonar.branch.name` (Community edition has no branch analysis)
5. Writes the three `*.override` files and the layer TOML.

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
| `BP_SONARQUBE_EXTRA_ARGS` | unset | appended verbatim to Maven args |
| `BP_MAVEN_BUILD_ARGUMENTS` | `--batch-mode -Dmaven.test.skip=true package` | application-supplied args are preserved |

---

## Failure matrix

| Scenario | Outcome |
|---|---|
| `BP_SONARQUBE_ENABLED` unset / `false` | detect `exit 100`; build continues without SonarQube |
| `BP_SONARQUBE_ENABLED=true`, any required var missing | detect/build fails |
| Enabled but no `pom.xml` | detect `exit 100` (this MVP is Maven-only) |
| Project missing, auto-create enabled | project created, build continues |
| Project missing, auto-create disabled | build fails |
| Project create API call fails | build fails |
| Strict mode + quality gate fails | Maven (in next buildpack) fails → image not published |
| Non-strict + quality gate fails | analysis uploaded, image still publishes |
| Invalid boolean value for any `_ENABLED`/`_STRICT`/`_AUTO_CREATE_PROJECT` | build fails |

---

## Logging and security guarantees

What logs **always show**:

```
sonarqube-buildpack: Detected Maven project for SonarQube analysis
sonarqube-buildpack: Repository name / branch / slugged values
sonarqube-buildpack: Project name/key: <resolved>
sonarqube-buildpack: SonarQube project <key> already exists | created
sonarqube-buildpack: Prepared Maven args for downstream buildpacks: ...
```

What logs **never show**:

- `BP_SONARQUBE_APIKEY` / `SONAR_TOKEN` values
- `Authorization` headers
- `sonar.token=...` (token is never placed on the Maven command line)

Implementation choices that enforce this:

- No `set -x` in `bin/detect` or `bin/build`
- Token only ever written to the `SONAR_TOKEN.override` file inside a build-only layer
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
  - id: bs23-buildpacks/sonarqube
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

[`tests/test-local.sh`](./tests/test-local.sh) drives a `pack build` against a sample Maven app:

```bash
export BP_SONARQUBE_URL=https://sonarqube.example.com
export BP_SONARQUBE_APIKEY=...
export BP_SONARQUBE_REPO_NAME=test-app
export BP_SONARQUBE_REPO_BRANCH=main
./tests/test-local.sh
```

Expected:

- Maven runs once, with `package sonar:sonar`
- Tests stay skipped (`-Dmaven.test.skip=true` preserved)
- SonarQube project is created if missing
- Token never appears in `pack` output
- Build only fails on quality gate when `BP_SONARQUBE_STRICT=true`

---

## Current scope and future work

Implemented (MVP):

- Java/Maven inline analysis via Paketo Java env override
- SonarQube project auto-create
- Build-only layer that keeps token out of the runtime image

Not yet implemented (see [`tasks.md`](./tasks.md)):

- Vendored SonarScanner CLI for non-Java projects (Node/Python/PHP)
- Gradle plugin detection and `./gradlew sonar`
- Production rollout to non-Java builders
