#!/usr/bin/env bash
# Test of the semantic-release action without GitHub: installs its release tooling, then runs a dry run of the
# default config (without the GitHub-dependent plugins) in a throwaway repository with a local bare remote.
# Checks that the plugins and the conventionalcommits preset resolve from the action's node_modules while the
# working directory is another repository, and that tag format and version come out as expected.
set -euo pipefail

action=$(cd "$(dirname "$0")/../../semantic-release" && pwd)
npm ci --ignore-scripts --no-audit --no-fund --prefix "${action}"

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
git init --quiet --bare --initial-branch=main "${work}/remote.git"
git init --quiet --initial-branch=main "${work}/repo"
cd "${work}/repo"
git config user.name test
git config user.email test@example.com
git remote add origin "file://${work}/remote.git"
git commit --quiet --allow-empty -m "chore: initial commit"
git commit --quiet --allow-empty -m "feat: something new"
git push --quiet origin main

# every plugin of the default config must resolve from the action
# shellcheck disable=SC2016 # JavaScript, expanded by node
CONFIG="${action}/release.config.cjs" node -e '
  const { createRequire } = require("node:module");
  const req = createRequire(process.argv[1] + "/node_modules/semantic-release/package.json");
  const plugins = require(process.env.CONFIG).plugins.map((p) => (Array.isArray(p) ? p[0] : p));
  for (const name of [...plugins, "conventional-changelog-conventionalcommits"]) {
    console.log(`resolves: ${name} → ${req.resolve(name)}`);
  }
' "${action}"

# dry run: default config, but only analyzer + notes (the GitHub plugin needs a GitHub repository URL)
cat > release.config.cjs <<JS
const base = require('${action}/release.config.cjs');
module.exports = { ...base, plugins: base.plugins.slice(0, 2) };
JS
# shellcheck disable=SC2016 # ${version} is semantic-release's placeholder, not a shell variable
out=$(SHARED_RELEASE_TAG_FORMAT='v${version}' "${action}/node_modules/.bin/semantic-release" \
  --dry-run --no-ci --repository-url "file://${work}/remote.git" 2>&1) || { echo "${out}"; exit 1; }
echo "${out}"
grep -q 'next release version is 1.0.0' <<<"${out}" || { echo "::error::expected version 1.0.0"; exit 1; }
grep -q 'Features' <<<"${out}" || { echo "::error::release notes without the Features section"; exit 1; }
grep -q 'v1.0.0' <<<"${out}" || { echo "::error::tag format v\${version} not applied"; exit 1; }
rm release.config.cjs

# the full default config the way the action passes it (--extends, no config in the repository): every plugin
# must load. It stops afterwards at @semantic-release/github (no GitHub URL/token here) – that is expected.
out=$("${action}/node_modules/.bin/semantic-release" --dry-run --no-ci \
  --extends "${action}/release.config.cjs" --repository-url "file://${work}/remote.git" 2>&1) || true
for plugin in commit-analyzer release-notes-generator changelog git github exec; do
  grep -q "from \"@semantic-release/${plugin}\"" <<<"${out}" \
    || { echo "${out}"; echo "::error::plugin @semantic-release/${plugin} not loaded from the default config"; exit 1; }
done

echo "semantic-release action test ok"
