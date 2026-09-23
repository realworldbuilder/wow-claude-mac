'use strict';
// Builds the macOS capture helper (capture-mac.swift -> bin/wowclaude-capture).
// Used by setup.js and by tests/codec_test.js; `node bridge/build-capture.js` by hand.
// Needs Apple's Command Line Tools (xcode-select --install); full Xcode also works.

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const HERE = __dirname;
const SOURCE = path.join(HERE, 'capture-mac.swift');
const BINARY = path.join(HERE, 'bin', 'wowclaude-capture');
const MIN_MACOS = '14.2'; // SCScreenshotManager (14.0) + includeChildWindows (14.2)

function isBuilt() {
  try {
    return fs.statSync(BINARY).mtimeMs >= fs.statSync(SOURCE).mtimeMs;
  } catch { return false; }
}

// Returns { ok, message }. ok is true when the binary is current (built now or before).
function build({ force = false, log = () => {} } = {}) {
  if (process.platform !== 'darwin') return { ok: false, message: 'the capture helper is macOS only' };
  if (!force && isBuilt()) return { ok: true, message: `${BINARY} is up to date` };
  const found = spawnSync('xcrun', ['--find', 'swiftc'], { encoding: 'utf8' });
  if (found.status !== 0) {
    return { ok: false, message: 'swiftc not found. Install Apple\'s Command Line Tools with: xcode-select --install  (then re-run: node setup.js)' };
  }
  const arch = process.arch === 'arm64' ? 'arm64' : 'x86_64';
  const args = ['-sdk', 'macosx', 'swiftc', '-O', '-swift-version', '5', '-target', `${arch}-apple-macos${MIN_MACOS}`,
    '-o', BINARY, SOURCE];
  log(`building capture helper: xcrun ${args.join(' ')}`);
  fs.mkdirSync(path.dirname(BINARY), { recursive: true });
  const r = spawnSync('xcrun', args, { encoding: 'utf8' });
  if (r.status !== 0) {
    return { ok: false, message: `swiftc failed:\n${(r.stderr || r.stdout || '').trim().slice(0, 2000)}` };
  }
  return { ok: true, message: `built ${BINARY}` };
}

module.exports = { build, isBuilt, BINARY, SOURCE };

if (require.main === module) {
  const r = build({ force: process.argv.includes('--force'), log: console.log });
  console.log(r.message);
  process.exit(r.ok ? 0 : 1);
}
