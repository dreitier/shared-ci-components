// Runs multi-semantic-release over the npm workspaces of the repository in the current directory and writes the
// released packages to $GITHUB_OUTPUT. Without a semantic-release config of the repository (.releaserc*,
// release.config.*, "release" in package.json) every package gets release.config.cjs of this action.
// Environment: DRY_RUN ('true'), GITHUB_OUTPUT (optional), GITHUB_TOKEN etc. for the plugins.
import { appendFileSync, existsSync, readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import multiSemanticRelease from '@anolilab/multi-semantic-release';

const actionDir = dirname(fileURLToPath(import.meta.url));
const cwd = process.cwd();

const hasOwnConfig = () => {
  if (readdirSync(cwd).some((f) => f.startsWith('.releaserc') || f.startsWith('release.config.'))) return true;
  const pkg = JSON.parse(readFileSync(join(cwd, 'package.json'), 'utf8'));
  return Object.hasOwn(pkg, 'release');
};

if (!existsSync(join(cwd, 'package.json'))) {
  console.error('::error::multi-semantic-release needs a package.json with "workspaces" in the repository root');
  process.exit(1);
}

// inputOptions go to semantic-release's getConfig of every package; an absolute path in "extends" resolves from
// any package directory
const inputOptions = hasOwnConfig() ? {} : { extends: join(actionDir, 'release.config.cjs') };
const flags = { dryRun: process.env.DRY_RUN === 'true' };

const packages = await multiSemanticRelease(null, inputOptions, { cwd, env: process.env }, flags);

const released = packages
  .filter((p) => p.result && p.result.nextRelease)
  .map((p) => ({ name: p.name, version: p.result.nextRelease.version, tag: p.result.nextRelease.gitTag }));

console.log(`released: ${released.length ? released.map((r) => r.tag).join(', ') : 'nothing'}`);
if (process.env.GITHUB_OUTPUT) {
  appendFileSync(
    process.env.GITHUB_OUTPUT,
    `released=${JSON.stringify(released)}\ntags=${released.map((r) => r.tag).join(' ')}\n`,
  );
}
