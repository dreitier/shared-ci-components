# shared-ci-components

Composite GitHub Actions shared by the dreitier repositories: semantic-release (single and monorepo) with the release bot, SBOM,
Trivy scan, Dependency-Track upload and keyless cosign signatures. Each repository keeps its own release workflow and calls these actions as steps.

Composite actions, not reusable workflows, on purpose: they run inside the caller's job, so the keyless
signing identity stays the caller's workflow
(`https://github.com/dreitier/<repo>/.github/workflows/release.yml@refs/heads/main`) and the caller keeps
control over permissions and secrets.

Exception: [`conventional-pr-title`](.github/workflows/conventional-pr-title.yml) is a reusable workflow – it
signs nothing and is a job of its own anyway (required status check).

## Actions

| Action | What | Caller needs |
| --- | --- | --- |
| [`semantic-release`](semantic-release/action.yml) | Checkout (full history), semantic-release as dreitier-release-bot (CHANGELOG.md, tag, GitHub release), output `version`. semantic-release and plugins come with the action | variable `RELEASE_APP_CLIENT_ID`, secret `RELEASE_APP_PRIVATE_KEY` (org level for public, repository level for private repositories); bot installed on the repository |
| [`multi-semantic-release`](multi-semantic-release/action.yml) | Monorepo variant: every npm workspace package released on its own (tag `<package>@<version>`, CHANGELOG.md per package, GitHub release per tag), output `released`/`tags` | like `semantic-release`; root `package.json` with `workspaces`, one non-private `package.json` per package |
| [`sbom`](sbom/action.yml) | CycloneDX SBOM (JSON) of an image with Trivy, components only | registry login for remote images |
| [`trivy-scan`](trivy-scan/action.yml) | Vulnerability scan (SARIF), optional upload to code scanning | `security-events: write` for the upload (private repos: no code scanning on GitHub Free → `upload-sarif: 'false'`) |
| [`dependency-track-upload`](dependency-track-upload/action.yml) | Uploads the SBOM to Dependency-Track, project auto-created | secret `DEPENDENCYTRACK_API_KEY` (team with BOM_UPLOAD + PROJECT_CREATION_UPLOAD) |
| [`cosign-sign`](cosign-sign/action.yml) | Keyless cosign signature of a digest, optional SLSA v1 provenance (`cosign attest`) | `id-token: write`, registry login |

## Usage

### semantic-release

```yaml
jobs:
  semantic-release:
    runs-on: ubuntu-latest
    permissions:
      contents: read         # all writes use the release bot's token
    outputs:
      version: ${{ steps.release.outputs.version }}
    steps:
      - id: release
        uses: dreitier/shared-ci-components/semantic-release@<sha> # v1.1.0
        with:
          app-client-id: ${{ vars.RELEASE_APP_CLIENT_ID }}
          app-private-key: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
          # tag-format: 'v${version}'           # default '${version}'
          # changelog-title: "# Changelog\n\n…"  # default: standard text
```

The action checks out the repository itself. No `package.json`, `package-lock.json` or `.releaserc.json` in the
calling repository: the default config ([`release.config.cjs`](semantic-release/release.config.cjs)) releases from
`main` with Conventional Commits (`feat` → minor, `fix`/`perf`/`build(deps)` → patch), commits `CHANGELOG.md`
(`chore(release): x.y.z [skip ci]`) and creates the GitHub release without PR comments or labels. A repository
config of its own (`.releaserc*`, `release.config.*`) takes precedence; it must write `version=…` to
`$GITHUB_OUTPUT` (`@semantic-release/exec`, see the default config).

Migrating a repository: set `changelog-title` to the **exact** current header of its `CHANGELOG.md` (everything
above the first `## ` entry, `\n` for line breaks) – the changelog plugin only replaces a header that matches,
any other title ends up on top of the old one. Then delete `package.json`, `package-lock.json`, `.releaserc.json`
and the npm entry of Dependabot/Renovate.

### multi-semantic-release (monorepo)

One version per package instead of one per repository, e.g. the OpenTofu modules in `dreitier/tofu-modules`.
[multi-semantic-release](https://github.com/anolilab/semantic-release/tree/main/packages/multi-semantic-release)
analyzes only the commits that touch a package's directory and releases the packages one after another.

```yaml
jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: read         # all writes use the release bot's token
    outputs:
      released: ${{ steps.release.outputs.released }}   # [{"name","version","tag"}]
    steps:
      - id: release
        uses: dreitier/shared-ci-components/multi-semantic-release@<sha> # v1.3.0
        with:
          app-client-id: ${{ vars.RELEASE_APP_CLIENT_ID }}
          app-private-key: ${{ secrets.RELEASE_APP_PRIVATE_KEY }}
          # changelog-title: "# Changelog\n\n…"  # default: standard text, same for every package
```

The calling repository needs a root `package.json` (`"private": true`, `"workspaces": ["modules/*"]`) and a
`package.json` per package with `name` and `"version": "0.0.0"` – the version in it is never bumped (no npm
publish), the tags are the truth. Private packages are skipped. The default config
([`release.config.cjs`](multi-semantic-release/release.config.cjs)) equals the single-repository one but commits
`<package>/CHANGELOG.md` (`chore(release): <package>@x.y.z [skip ci]`) and creates one GitHub release per tag. A
semantic-release config of the repository (`.releaserc*`, `release.config.*`) replaces it; multi-semantic-release
options (`ignorePackages`, `tagFormat`, …) go into `.multi-releaserc.json`. `dry-run` still verifies the GitHub
token (the GitHub plugin's verify step). Note: a first run releases every package (1.0.0) – one commit, tag and
GitHub release each.

### Image actions

Pin by commit SHA with the version as a comment; Dependabot/Renovate update it.

```yaml
jobs:
  image:
    permissions:
      contents: read
      packages: write
      id-token: write        # cosign-sign
    steps:
      # ... build and push, step id "build" with output "digest" ...

      - uses: dreitier/shared-ci-components/cosign-sign@<sha> # v1.0.0
        with:
          images: |
            index.docker.io/dreitier/example
            ghcr.io/dreitier/example
          digest: ${{ steps.build.outputs.digest }}
          provenance: 'true'   # private repositories; public ones use actions/attest-build-provenance
          version: ${{ env.VERSION }}

      - id: sbom
        uses: dreitier/shared-ci-components/sbom@<sha> # v1.0.0
        with:
          image: ghcr.io/dreitier/example@${{ steps.build.outputs.digest }}

      - uses: dreitier/shared-ci-components/dependency-track-upload@<sha> # v1.0.0
        with:
          api-key: ${{ secrets.DEPENDENCYTRACK_API_KEY }}
          bom: ${{ steps.sbom.outputs.file }}
          project-name: example
          project-version: ${{ env.VERSION }}
```

`DEPENDENCYTRACK_API_KEY` is an organization secret for public repositories; private repositories need it as a
repository secret (GitHub Free). Dependency-Track: only `/api/v1/bom` and `/api/version` are public at
`https://dependency-track.dreitier.com`.

### PR title (reusable workflow)

Checks that the PR title is a Conventional Commit
([`amannn/action-semantic-pull-request`](https://github.com/amannn/action-semantic-pull-request)). Together
with squash merges whose commit title is the PR title, everything on `main` is a Conventional Commit.

`.github/workflows/pr-title.yml` in the calling repository:

```yaml
name: PR title

on:
  pull_request:
    types: [opened, edited, synchronize, reopened]

permissions:
  pull-requests: read        # the called job can only narrow this

jobs:
  pr-title:
    uses: dreitier/shared-ci-components/.github/workflows/conventional-pr-title.yml@<sha> # v1.2.0
    # with:
    #   types: |             # default: Conventional Commits types
    #     feat
    #     fix
    #   scopes: ''           # regex per line, default: any
    #   require-scope: false
    #   validate-single-commit: false  # only without "Default to pull request title"
```

Repository settings (once, UI or REST API):

```bash
gh api -X PATCH repos/dreitier/<repo> \
  -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false \
  -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY
```

The check is called `pr-title / Conventional Commit`. Make it a required status check in a ruleset on the
default branch (with *Require a pull request before merging*). GitHub Free: rulesets only for public
repositories – in private ones the check runs but doesn't block the merge.

Dependabot bumps the action pinned in the reusable workflow as `ci(deps)` (directory `/`), which doesn't release.
Retitle that PR to `build(deps): …` before merging so callers get the update as a patch release.

## Development

- `pre-commit install` – actionlint, shellcheck, file checks. CI additionally shellchecks the `run` scripts
  of the actions (`.github/scripts/shellcheck-actions.py`) – values go into scripts via `env`, never as
  `${{ }}` expressions (script injection).
- CI tests `sbom` and `trivy-scan` against a local test image (`.github/test/Dockerfile`), the
  `semantic-release` action with a dry run of its default config in a throwaway repository
  (`.github/scripts/test-semantic-release.sh`) and `multi-semantic-release` with real releases of a throwaway
  monorepo (`.github/scripts/test-multi-semantic-release.sh`). This repository releases itself with `./semantic-release`.
- PR titles are Conventional Commits; semantic-release tags `vX.Y.Z` on main. `build(deps)` (actions and npm
  packages used inside the composite actions) releases a patch, `ci(deps)` doesn't.
