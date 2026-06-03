'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const runtimeDir = path.join(root, 'resources', 'runtime', 'bin');
const destination = path.join(runtimeDir, 'opencode-cli.exe');

const candidates = [
  process.env.OCKEY_OPENCODE_RUNTIME_SOURCE,
  path.join(root, 'node_modules', 'opencode-windows-x64', 'bin', 'opencode.exe'),
  process.env.LOCALAPPDATA && path.join(process.env.LOCALAPPDATA, 'OpenCode', 'opencode-cli.exe'),
  process.env.LOCALAPPDATA && path.join(process.env.LOCALAPPDATA, 'OpenCode', 'opencode.exe')
].filter(Boolean);

const source = candidates.find((candidate) => fs.existsSync(candidate));

if (!source) {
  console.error('No OpenCode CLI runtime found.');
  console.error('Install optional dependency opencode-windows-x64, or set OCKEY_OPENCODE_RUNTIME_SOURCE to a CLI exe.');
  process.exit(1);
}

let version = '';
try {
  version = execFileSync(source, ['--version'], {
    encoding: 'utf8',
    timeout: 20_000,
    windowsHide: true
  }).trim();
} catch (error) {
  console.error(`OpenCode CLI runtime failed --version: ${source}`);
  console.error(error.stderr?.toString() || error.stdout?.toString() || error.message);
  process.exit(1);
}

if (!version) {
  console.error(`OpenCode CLI runtime did not print a version: ${source}`);
  process.exit(1);
}

fs.mkdirSync(runtimeDir, { recursive: true });

const sourceStat = fs.statSync(source);
const destinationStat = fs.existsSync(destination) ? fs.statSync(destination) : undefined;
if (!destinationStat || destinationStat.size !== sourceStat.size) {
  fs.copyFileSync(source, destination);
}

const sizeMb = (fs.statSync(destination).size / 1024 / 1024).toFixed(1);
console.log(`Prepared OpenCode CLI ${version} (${sizeMb} MB)`);
console.log(`Source: ${source}`);
console.log(`Runtime: ${destination}`);
