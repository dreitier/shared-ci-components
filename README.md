# shared-ci-components

Composite GitHub Actions shared by the dreitier repositories: SBOM, Trivy scan, Dependency-Track upload and
keyless cosign signatures. Each repository keeps its own release workflow and calls these actions as steps.

Composite actions, not reusable workflows, on purpose: they run inside the caller's job, so the keyless
signing identity stays the caller's workflow
(`https://github.com/dreitier/<repo>/.github/workflows/release.yml@refs/heads/main`) and the caller keeps
control over permissions and secrets.

## Actions

| Action | What | Caller needs |
| --- | --- | --- |
| [`sbom`](sbom/action.yml) | CycloneDX SBOM (JSON) of an image with Trivy, components only | registry login for remote images |
| [`trivy-scan`](trivy-scan/action.yml) | Vulnerability scan (SARIF), optional upload to code scanning | `security-events: write` for the upload (private repos: no code scanning on GitHub Free → `upload-sarif: 'false'`) |
| [`dependency-track-upload`](dependency-track-upload/action.yml) | Uploads the SBOM to Dependency-Track, project auto-created | secret `DEPENDENCYTRACK_API_KEY` (team with BOM_UPLOAD + PROJECT_CREATION_UPLOAD) |
| [`cosign-sign`](cosign-sign/action.yml) | Keyless cosign signature of a digest, optional SLSA v1 provenance (`cosign attest`) | `id-token: write`, registry login |

## Usage

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

## Development

- `pre-commit install` – actionlint, shellcheck, file checks. CI additionally shellchecks the `run` scripts
  of the actions (`.github/scripts/shellcheck-actions.py`) – values go into scripts via `env`, never as
  `${{ }}` expressions (script injection).
- CI tests `sbom` and `trivy-scan` against a local test image (`.github/test/Dockerfile`).
- PR titles are Conventional Commits; semantic-release tags `vX.Y.Z` on main. `build(deps)` (actions used
  inside the composite actions) releases a patch, `ci(deps)` doesn't.
