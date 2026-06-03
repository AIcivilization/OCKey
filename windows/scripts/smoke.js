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

    const state = await fetch(`http://127.0.0.1:${process.env.OCKEY_PORT}/admin/state`).then((res) => res.json());
    assert(state.keys?.[0]?.key === created.key, 'admin state should expose visible keys to same-origin UI');

    const sanitizedHealth = await fetch(`http://127.0.0.1:${process.env.OCKEY_PORT}/health`).then((res) => res.json());
    assert(!('keys' in sanitizedHealth), 'health should not expose keys');
    assert(JSON.stringify(sanitizedHealth).includes(created.key) === false, 'health should not leak created key');

    const blockedAdmin = await fetch(`http://127.0.0.1:${process.env.OCKEY_PORT}/admin/state`, {
      headers: { origin: 'https://example.invalid' }
    });
    assert(blockedAdmin.status === 403, 'cross-origin admin reads should be rejected');

    const blockedAdminPost = await fetch(`http://127.0.0.1:${process.env.OCKEY_PORT}/admin/keys`, {
      method: 'POST',
      headers: { origin: 'https://example.invalid', 'content-type': 'application/json' },
      body: JSON.stringify({ name: 'Blocked Channel' })
    });
    assert(blockedAdminPost.status === 403, 'cross-origin admin writes should be rejected');

    const apiPreflight = await fetch(`http://127.0.0.1:${process.env.OCKEY_PORT}/v1/models`, { method: 'OPTIONS' });
    assert(apiPreflight.status === 204, 'v1 preflight should be allowed');
    assert(apiPreflight.headers.get('access-control-allow-origin') === '*', 'v1 should keep CORS enabled');

    const adminPreflight = await fetch(`http://127.0.0.1:${process.env.OCKEY_PORT}/admin/state`, { method: 'OPTIONS' });
    assert(adminPreflight.status === 403, 'admin preflight should be rejected');

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
