#!/usr/bin/env bash
# Test of the multi-semantic-release action without GitHub: installs its release tooling, then releases a
# throwaway monorepo (two packages, local bare remote) with the default config minus the GitHub plugin.
# Checks: one tag <package>@<version> and one CHANGELOG.md per package, release commits pushed, that a later
# commit releases only the package whose directory it touches, and that a repository config can use
# @semantic-release/exec (shipped with the action) and a custom tagFormat (.multi-releaserc.json, e.g. helm-charts).
set -euo pipefail

action=$(cd "$(dirname "$0")/../../multi-semantic-release" && pwd)
npm ci --ignore-scripts --no-audit --no-fund --prefix "${action}"

# A real release (not a dry run) needs a CI environment for env-ci; the generic CI=true takes branch and commit
# from git. GitHub's variables are removed – on pull requests env-ci would take the PR ref as the branch.
msr() {
  env -u GITHUB_ACTIONS -u GITHUB_REF -u GITHUB_HEAD_REF -u GITHUB_EVENT_NAME -u GITHUB_EVENT_PATH \
    -u GITHUB_OUTPUT CI=true GITHUB_OUTPUT="${work}/output" node "${action}/run.mjs"
}

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
git init --quiet --bare --initial-branch=main "${work}/remote.git"
git init --quiet --initial-branch=main "${work}/repo"
cd "${work}/repo"
git config user.name test
git config user.email test@example.com
git remote add origin "file://${work}/remote.git"
cat > package.json <<'JSON'
{ "name": "monorepo", "private": true, "workspaces": ["modules/*"] }
JSON
for p in alpha beta; do
  mkdir -p "modules/${p}"
  echo "{ \"name\": \"${p}\", \"version\": \"0.0.0\" }" > "modules/${p}/package.json"
  echo "# ${p}" > "modules/${p}/main.tf"
done
# default config of the action without @semantic-release/github (needs a GitHub repository URL and token)
cat > release.config.cjs <<JS
const base = require('${action}/release.config.cjs');
module.exports = { ...base, plugins: base.plugins.filter((p) => (Array.isArray(p) ? p[0] : p) !== '@semantic-release/github') };
JS
git add -A
git commit --quiet -m "feat: initial modules"
git push --quiet origin main

check() { grep -q "$1" <<<"$2" || { echo "${out}"; echo "::error::$3"; exit 1; }; }

out=$(msr 2>&1) || { echo "${out}"; exit 1; }
tags=$(git ls-remote --tags origin)
check 'refs/tags/alpha@1.0.0' "${tags}" "tag alpha@1.0.0 missing"
check 'refs/tags/beta@1.0.0' "${tags}" "tag beta@1.0.0 missing"
git pull --quiet origin main
for p in alpha beta; do
  [ -f "modules/${p}/CHANGELOG.md" ] || { echo "${out}"; echo "::error::modules/${p}/CHANGELOG.md missing"; exit 1; }
  check '# Changelog' "$(cat "modules/${p}/CHANGELOG.md")" "changelog title missing in ${p}"
done
check 'chore(release): alpha@1.0.0' "$(git log --format=%s)" "release commit of alpha missing"
check 'alpha@1.0.0' "$(cat "${work}/output")" "output released/tags without alpha@1.0.0"

# a fix in alpha releases alpha only
echo "# fix" >> modules/alpha/main.tf
git commit --quiet -am "fix(alpha): something"
git push --quiet origin main
: > "${work}/output"
out=$(msr 2>&1) || { echo "${out}"; exit 1; }
tags=$(git ls-remote --tags origin)
check 'refs/tags/alpha@1.0.1' "${tags}" "tag alpha@1.0.1 missing"
if grep -q 'beta@1.0.1' <<<"${tags}"; then echo "${out}"; echo "::error::beta released without changes"; exit 1; fi
check '"tag":"alpha@1.0.1"' "$(cat "${work}/output")" "output without alpha@1.0.1"

# a repository config with @semantic-release/exec (prepareCmd runs in the package directory, its output is
# committed) and the tag format <package>-<version> from .multi-releaserc.json, like dreitier/helm-charts
cat > release.config.cjs <<JS
const base = require('${action}/release.config.cjs');
const plugins = base.plugins.filter((p) => !['@semantic-release/github', '@semantic-release/git'].includes(Array.isArray(p) ? p[0] : p));
module.exports = {
  ...base,
  plugins: [
    ...plugins,
    ['@semantic-release/exec', { prepareCmd: 'echo \${nextRelease.version} > VERSION' }],
    ['@semantic-release/git', { assets: ['CHANGELOG.md', 'VERSION'], message: 'chore(release): \${nextRelease.gitTag} [skip ci]' }],
  ],
};
JS
echo '{ "tagFormat": "${name}-${version}" }' > .multi-releaserc.json
# the tag format changes, so the history above doesn't count: a new first release per package
git add -A
git commit --quiet -m "feat(beta): exec and tag format"
git push --quiet origin main
out=$(msr 2>&1) || { echo "${out}"; exit 1; }
tags=$(git ls-remote --tags origin)
check 'refs/tags/beta-1.0.0' "${tags}" "tag beta-1.0.0 (tagFormat from .multi-releaserc.json) missing"
git pull --quiet origin main
check '1.0.0' "$(cat modules/beta/VERSION 2>/dev/null)" "modules/beta/VERSION from @semantic-release/exec not committed"
rm .multi-releaserc.json

# the full default config the way the action passes it (no config in the repository, "extends" to the action's
# config): it must get as far as @semantic-release/github, which stops without a GitHub URL/token – expected.
# (multi-semantic-release swallows the "Loaded plugin" lines, so the github plugin's error is the evidence.)
rm release.config.cjs
git commit --quiet -am "chore: drop test config"
out=$(msr 2>&1) || true
check 'ENOGHTOKEN' "${out}" "default config of the action not applied (no @semantic-release/github)"

echo "multi-semantic-release action test ok"
