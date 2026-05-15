'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

process.env.OCKEY_PORT = process.env.OCKEY_PORT || '9799';
process.env.APPDATA = fs.mkdtempSync(path.join(os.tmpdir(), 'ockey-win-smoke-'));

const { OCKeyServer, constants } = require('../src/server');

async function main() {
  const server = new OCKeyServer();
  await server.start();
  try {
    const health = await fetch(`http://127.0.0.1:${process.env.OCKEY_PORT}/health`).then((res) => res.json());
    assert(health.ok === true, 'health should be ok');

    const unauth = await fetch(`http://127.0.0.1:${process.env.OCKEY_PORT}/v1/models`);
    assert(unauth.status === 401, 'v1/models should require a key');

    const created = await fetch(`http://127.0.0.1:${process.env.OCKEY_PORT}/admin/keys`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ name: 'Smoke Channel' })
    }).then((res) => res.json());
    assert(created.ok === true, 'key creation should succeed');
    assert(String(created.key || '').startsWith('ockey_'), 'key should use ockey_ prefix');

    const ui = await fetch(`http://127.0.0.1:${process.env.OCKEY_PORT}/admin/ui`).then((res) => res.text());
    assert(ui.includes('OCKey Windows'), 'admin UI should render');

    console.log(JSON.stringify({
      ok: true,
      baseUrl: constants.OPENAI_BASE_URL.replace(':8789', `:${process.env.OCKEY_PORT}`),
      appData: process.env.APPDATA
    }, null, 2));
  } finally {
    await server.stop();
  }
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
