const fs = require('fs');
const path = require('path');

function parse(src) {
  const result = {};
  src.split(/\r?\n/).forEach((line) => {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) {
      return;
    }
    const eqIndex = trimmed.indexOf('=');
    if (eqIndex === -1) {
      return;
    }
    const key = trimmed.slice(0, eqIndex).trim();
    const value = trimmed.slice(eqIndex + 1).trim();
    result[key] = value;
  });
  return result;
}

function config(options = {}) {
  const cwd = options.cwd || process.cwd();
  const envPath = options.path || path.join(cwd, '.env');
  if (!fs.existsSync(envPath)) {
    return { parsed: {} };
  }
  const parsed = parse(fs.readFileSync(envPath, 'utf8'));
  Object.entries(parsed).forEach(([key, value]) => {
    if (process.env[key] === undefined) {
      process.env[key] = value;
    }
  });
  return { parsed };
}

module.exports = { config, parse };
