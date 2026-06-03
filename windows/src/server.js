'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { spawn, execFile } = require('node:child_process');

const PORT = Number(process.env.OCKEY_PORT || 8789);
const HOST = process.env.OCKEY_HOST || '127.0.0.1';
const BASE_URL = `http://${HOST}:${PORT}`;
const OPENAI_BASE_URL = `${BASE_URL}/v1`;
const DEFAULT_MODEL = 'opencode/minimax-m2.5-free';
const OPENCODE_CLI_NAMES = ['opencode-cli.exe', 'opencode.exe', 'opencode.cmd', 'opencode'];

function appDataRoot() {
  const root = process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming');
  return path.join(root, 'OCKey');
}

function bundledRuntimeRoot() {
  if (process.resourcesPath) {
    return path.join(process.resourcesPath, 'runtime', 'bin');
  }
  return path.resolve(__dirname, '..', 'resources', 'runtime', 'bin');
}

class Store {
  constructor() {
    this.supportRoot = appDataRoot();
    this.dataRoot = path.join(this.supportRoot, 'data');
    this.logsRoot = path.join(this.supportRoot, 'logs');
    this.runtimeBin = path.join(this.supportRoot, 'runtime', 'bin');
    this.keysPath = path.join(this.dataRoot, 'keys.json');
    this.visibleKeysPath = path.join(this.dataRoot, 'visible-keys.json');
    this.healthPath = path.join(this.dataRoot, 'key-health.json');
    this.usagePath = path.join(this.dataRoot, 'usage.json');
    this.settingsPath = path.join(this.dataRoot, 'settings.json');
    this.auditPath = path.join(this.logsRoot, 'audit.jsonl');
    // 优先使用环境变量 OCKEY_OPENCODE_PATH 指定的已安装 OpenCode CLI；
    // 否则自动探测常见安装位置；都没有再回退到打包目录。
    const candidates = [
      process.env.OCKEY_OPENCODE_PATH,
      process.env.LOCALAPPDATA && path.join(process.env.LOCALAPPDATA, 'OpenCode', 'opencode-cli.exe'),
      process.env.LOCALAPPDATA && path.join(process.env.LOCALAPPDATA, 'OpenCode', 'opencode.exe'),
      path.join(os.homedir(), 'AppData', 'Local', 'OpenCode', 'opencode-cli.exe')
    ].filter(Boolean);
    const found = candidates.find((p) => fs.existsSync(p));
    this.externalOpencode = !!found;
    this.opencodePath = found || path.join(this.runtimeBin, 'opencode-cli.exe');
    this.ensure();
  }

  ensure() {
    fs.mkdirSync(this.dataRoot, { recursive: true });
    fs.mkdirSync(this.logsRoot, { recursive: true });
    fs.mkdirSync(this.runtimeBin, { recursive: true });
    this.ensureJson(this.keysPath, []);
    this.ensureJson(this.visibleKeysPath, []);
    this.ensureJson(this.healthPath, {});
    this.ensureJson(this.usagePath, []);
    this.ensureJson(this.settingsPath, { defaultModel: DEFAULT_MODEL, includeExperimentalModels: false });
    this.syncBundledRuntime();
  }

  ensureJson(filePath, value) {
    if (!fs.existsSync(filePath)) {
      fs.writeFileSync(filePath, JSON.stringify(value, null, 2), { mode: 0o600 });
    }
  }

  syncBundledRuntime() {
    if (this.externalOpencode) return; // 使用已安装的 CLI，无需复制
    const candidates = OPENCODE_CLI_NAMES.map((name) => path.join(bundledRuntimeRoot(), name));
    const source = candidates.find((candidate) => fs.existsSync(candidate));
    if (!source) return;
    const destination = this.opencodePath;
    const sourceStat = fs.statSync(source);
    const destinationStat = fs.existsSync(destination) ? fs.statSync(destination) : undefined;
    if (destinationStat && destinationStat.size === sourceStat.size) return;
    fs.copyFileSync(source, destination);
  }

  readJson(filePath, fallback) {
    try {
      return JSON.parse(fs.readFileSync(filePath, 'utf8'));
    } catch {
      return fallback;
    }
  }

  writeJson(filePath, value) {
    const tmp = `${filePath}.${crypto.randomUUID()}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(value, null, 2), { mode: 0o600 });
    fs.renameSync(tmp, filePath);
  }

  keys() { return this.readJson(this.keysPath, []); }
  writeKeys(value) { this.writeJson(this.keysPath, value); }
  visibleKeys() { return this.readJson(this.visibleKeysPath, []); }
  writeVisibleKeys(value) { this.writeJson(this.visibleKeysPath, value); }
  health() { return this.readJson(this.healthPath, {}); }
  writeHealth(value) { this.writeJson(this.healthPath, value); }
  usage() { return this.readJson(this.usagePath, []); }
  writeUsage(value) { this.writeJson(this.usagePath, value); }
  settings() { return this.readJson(this.settingsPath, { defaultModel: DEFAULT_MODEL, includeExperimentalModels: false }); }
  writeSettings(value) { this.writeJson(this.settingsPath, value); }

  createKey(name, assignedModel) {
    const key = `ockey_${crypto.randomBytes(24).toString('base64url')}`;
    const record = {
      id: crypto.randomUUID(),
      name: cleanName(name) || 'OCKey Channel',
      keyHash: sha256(key),
      enabled: true,
      assignedModel: assignedModel || undefined,
      createdAt: new Date().toISOString(),
      lastUsedAt: undefined
    };
    const keys = this.keys();
    keys.push(record);
    this.writeKeys(keys);
    const visible = this.visibleKeys();
    visible.push({ keyId: record.id, name: record.name, key, createdAt: record.createdAt });
    this.writeVisibleKeys(visible);
    return { key, record };
  }

  deleteKey(keyId) {
    this.writeKeys(this.keys().filter((key) => key.id !== keyId));
    this.writeVisibleKeys(this.visibleKeys().filter((key) => key.keyId !== keyId));
    const health = this.health();
    delete health[keyId];
    this.writeHealth(health);
  }

  setKeyModel(keyId, model) {
    const keys = this.keys();
    const index = keys.findIndex((key) => key.id === keyId);
    if (index < 0) return;
    keys[index].assignedModel = model || undefined;
    this.writeKeys(keys);
  }

  authenticate(header) {
    const token = bearerToken(header);
    if (!token) return undefined;
    const keys = this.keys();
    const index = keys.findIndex((key) => key.enabled && key.keyHash === sha256(token));
    if (index < 0) return undefined;
    keys[index].lastUsedAt = new Date().toISOString();
    const record = keys[index];
    this.writeKeys(keys);
    return record;
  }

  visibleKey(keyId) {
    return this.visibleKeys().find((key) => key.keyId === keyId)?.key;
  }

  consumeUsage(keyId) {
    const today = new Date().toISOString().slice(0, 10);
    const usage = this.usage();
    const index = usage.findIndex((row) => row.date === today && row.keyId === keyId);
    if (index >= 0) usage[index].count += 1;
    else usage.push({ date: today, keyId, count: 1 });
    this.writeUsage(usage);
  }

  audit(item) {
    fs.appendFile(this.auditPath, `${JSON.stringify(item)}\n`, () => undefined);
  }
}

class OpenCodeRuntime {
  constructor(store) {
    this.store = store;
    this.modelCache = undefined;
  }

  status() {
    const exists = fs.existsSync(this.store.opencodePath);
    let version = '';
    let authenticated = false;
    let error;
    try {
      version = this.runSync(['--version'], 5000).trim();
      authenticated = this.listModels(false).length > 0;
    } catch (caught) {
      error = caught.message;
    }
    return {
      available: exists,
      path: this.store.opencodePath,
      version,
      authenticated,
      error
    };
  }

  listModels(force = false) {
    const now = Date.now();
    if (!force && this.modelCache && this.modelCache.expiresAt > now && !this.modelCache.error) {
      return this.modelCache.models;
    }
    const settings = this.store.settings();
    try {
      const output = this.runSync(['models', 'opencode'], 20_000);
      const includeExperimental = settings.includeExperimentalModels === true;
      const ids = output
        .split(/\r?\n/)
        .map((line) => line.trim())
        .filter((line) => line.startsWith('opencode/'));
      if (ids.length === 0) {
        this.modelCache = { expiresAt: now + 60_000, models: [] };
        return [];
      }
      let models = ids
        .map((id) => ({
          id,
          displayName: shortModelName(id),
          free: isFreeModel(id),
          experimental: isExperimentalModel(id)
        }))
        .filter((model) => model.free || (includeExperimental && model.experimental));
      if (models.length === 0) {
        models = [{ id: DEFAULT_MODEL, displayName: shortModelName(DEFAULT_MODEL), free: true, experimental: false }];
      }
      models.sort((left, right) => left.id.localeCompare(right.id, undefined, { numeric: true }));
      this.modelCache = { expiresAt: now + 300_000, models };
      return models;
    } catch (caught) {
      if (this.modelCache?.models?.length) {
        this.modelCache = { expiresAt: now + 60_000, models: this.modelCache.models, error: caught.message };
        return this.modelCache.models;
      }
      throw caught;
    }
  }

  refreshModels() {
    this.modelCache = undefined;
    return this.listModels(true);
  }

  async generate(model, messages, timeoutMs = 180_000) {
    const prompt = messages.map((message) => {
      const role = message.role || 'user';
      const content = normalizeContent(message.content);
      if (role === 'system') return `System:\n${content}`;
      if (role === 'assistant') return `Assistant:\n${content}`;
      return content;
    }).join('\n\n');
    const output = await this.run(['run', '--model', model, '--format', 'json', prompt], timeoutMs);
    const text = extractOpenCodeText(output);
    if (!text.trim()) throw new Error('OpenCode returned no assistant content');
    return text;
  }

  startLogin() {
    if (!fs.existsSync(this.store.opencodePath)) {
      throw new Error('Bundled OpenCode CLI runtime is missing. Run npm run prepare:runtime before packaging.');
    }
    const command = `start "OCKey OpenCode Login" cmd /k ""${this.store.opencodePath}" auth login"`;
    spawn('cmd.exe', ['/d', '/s', '/c', command], {
      detached: true,
      stdio: 'ignore',
      windowsHide: false
    }).unref();
  }

  checkUpdate() {
    let version = 'unknown';
    try { version = this.runSync(['--version'], 5000).trim(); } catch {}
    return {
      currentVersion: version,
      message: 'Windows 版不会静默更新内置 OpenCode。请通过新版 OCKey 安装包更新运行时。'
    };
  }

  runSync(args, timeout) {
    if (!fs.existsSync(this.store.opencodePath)) {
      throw new Error('Bundled OpenCode runtime is missing');
    }
    return require('node:child_process').execFileSync(this.store.opencodePath, args, {
      cwd: os.homedir(),
      env: opencodeEnv(this.store.opencodePath),
      timeout,
      encoding: 'utf8',
      maxBuffer: 16 * 1024 * 1024,
      windowsHide: true
    });
  }

  run(args, timeoutMs) {
    if (!fs.existsSync(this.store.opencodePath)) {
      return Promise.reject(new Error('Bundled OpenCode runtime is missing'));
    }
    return new Promise((resolve, reject) => {
      const child = execFile(this.store.opencodePath, args, {
        cwd: os.homedir(),
        env: opencodeEnv(this.store.opencodePath),
        timeout: timeoutMs,
        maxBuffer: 64 * 1024 * 1024,
        windowsHide: true
      }, (error, stdout, stderr) => {
        if (error) {
          reject(new Error(`OpenCode failed: ${preview(stderr || stdout || error.message)}`));
          return;
        }
        resolve(stdout);
      });
      child.on('error', reject);
    });
  }
}

class OCKeyServer {
  constructor(store = new Store(), runtime = new OpenCodeRuntime(store)) {
    this.store = store;
    this.runtime = runtime;
    this.server = undefined;
  }

  start() {
    if (this.server) return Promise.resolve();
    this.server = http.createServer((req, res) => {
      this.route(req, res).catch((error) => {
        const pathname = safe(() => new URL(req.url || '/', BASE_URL).pathname, '');
        this.jsonError(res, 500, 'internal_error', error.message, pathname.startsWith('/v1/'));
      });
    });
    return new Promise((resolve, reject) => {
      this.server.once('error', reject);
      this.server.listen(PORT, HOST, () => {
        this.server.off('error', reject);
        resolve();
      });
    });
  }

  stop() {
    return new Promise((resolve) => {
      if (!this.server) { resolve(); return; }
      this.server.close(() => resolve());
      this.server = undefined;
    });
  }

  state() {
    const models = safe(() => this.runtime.listModels(false), []);
    const keys = this.publicKeys();
    const health = this.store.health();
    const recommended = keys
      .map((key) => ({ key, health: health[key.id] }))
      .filter((item) => healthLevel(item.health) === 'ok')
      .sort((left, right) => (left.health?.durationMs ?? Number.MAX_SAFE_INTEGER) - (right.health?.durationMs ?? Number.MAX_SAFE_INTEGER))[0];
    return {
      ok: true,
      service: 'OCKey',
      baseUrl: BASE_URL,
      openAIBaseUrl: OPENAI_BASE_URL,
      defaultModel: this.currentDefaultModel(models),
      models,
      availableModels: models.map((model) => model.id),
      opencodeStatus: this.runtime.status(),
      keys,
      keyHealth: Object.fromEntries(Object.entries(health).map(([id, item]) => [id, healthObject(item)])),
      recommendedKey: recommended ? {
        id: recommended.key.id,
        name: recommended.key.name,
        durationMs: recommended.health.durationMs,
        model: recommended.health.model
      } : undefined,
      settings: this.store.settings(),
      dataDir: this.store.dataRoot,
      runtimePath: this.store.opencodePath
    };
  }

  publicHealth() {
    const state = this.state();
    const channelHealth = { total: state.keys.length, ok: 0, warn: 0, bad: 0, unknown: 0 };
    for (const key of state.keys) {
      const level = state.keyHealth[key.id]?.level || 'unknown';
      channelHealth[level] = (channelHealth[level] || 0) + 1;
    }
    return {
      ok: state.ok,
      service: state.service,
      baseUrl: state.baseUrl,
      openAIBaseUrl: state.openAIBaseUrl,
      defaultModel: state.defaultModel,
      models: state.models,
      availableModels: state.availableModels,
      opencodeStatus: state.opencodeStatus,
      channelHealth,
      settings: state.settings,
      dataDir: state.dataDir,
      runtimePath: state.runtimePath
    };
  }

  async route(req, res) {
    const url = new URL(req.url || '/', BASE_URL);
    const method = req.method || 'GET';
    const allowApiCors = url.pathname.startsWith('/v1/');
    if (method === 'OPTIONS') { this.empty(res, allowApiCors ? 204 : 403, allowApiCors); return; }
    if (isAdminPath(url.pathname) && !isAllowedLocalAdminRequest(req)) {
      this.jsonError(res, 403, 'forbidden', 'Cross-origin admin requests are not allowed');
      return;
    }
    if (method === 'GET' && url.pathname === '/') { this.redirect(res, '/admin/ui'); return; }
    if (method === 'GET' && url.pathname === '/admin/ui') { this.html(res, adminHtml()); return; }
    if (method === 'GET' && url.pathname === '/health') { this.json(res, this.publicHealth()); return; }
    if (method === 'GET' && url.pathname === '/admin/state') { this.json(res, this.state()); return; }
    if (method === 'POST' && url.pathname === '/admin/keys') { this.createKey(res, await readJsonBody(req)); return; }
    if (method === 'POST' && url.pathname === '/admin/delete-key') { this.deleteKey(res, await readJsonBody(req)); return; }
    if (method === 'POST' && url.pathname === '/admin/key-model') { this.setKeyModel(res, await readJsonBody(req)); return; }
    if (method === 'POST' && url.pathname === '/admin/health/test') { await this.testKey(res, await readJsonBody(req), false); return; }
    if (method === 'POST' && url.pathname === '/admin/health/test-all') { await this.testKey(res, await readJsonBody(req), true); return; }
    if (method === 'POST' && url.pathname === '/admin/opencode/login') { this.runtime.startLogin(); this.json(res, { ok: true }); return; }
    if (method === 'POST' && url.pathname === '/admin/opencode/refresh-models') { this.json(res, { ok: true, models: this.runtime.refreshModels(), state: this.state() }); return; }
    if (method === 'POST' && url.pathname === '/admin/opencode/check-update') { this.json(res, { ok: true, update: this.runtime.checkUpdate() }); return; }
    if (method === 'POST' && url.pathname === '/admin/settings') { this.updateSettings(res, await readJsonBody(req)); return; }
    if (method === 'GET' && url.pathname === '/v1/models') { this.v1Models(req, res); return; }
    if (method === 'POST' && url.pathname === '/v1/chat/completions') { await this.chatCompletions(req, res); return; }
    if (method === 'POST' && url.pathname === '/v1/responses') { await this.responses(req, res); return; }
    this.jsonError(res, 404, 'not_found', `No route for ${method} ${url.pathname}`, allowApiCors);
  }

  createKey(res, body) {
    const { key } = this.store.createKey(body.name, body.assignedModel);
    this.json(res, { ok: true, key, state: this.state() });
  }

  deleteKey(res, body) {
    this.store.deleteKey(body.keyId || '');
    this.json(res, { ok: true, state: this.state() });
  }

  setKeyModel(res, body) {
    this.store.setKeyModel(body.keyId || '', body.clear ? undefined : body.model);
    this.json(res, { ok: true, state: this.state() });
  }

  updateSettings(res, body) {
    const settings = this.store.settings();
    if (typeof body.includeExperimentalModels === 'boolean') settings.includeExperimentalModels = body.includeExperimentalModels;
    if (typeof body.defaultModel === 'string' && body.defaultModel.trim()) settings.defaultModel = body.defaultModel.trim();
    this.store.writeSettings(settings);
    safe(() => this.runtime.refreshModels(), []);
    this.json(res, { ok: true, state: this.state() });
  }

  async testKey(res, body, all) {
    const keys = this.store.keys();
    const targets = all ? keys : keys.filter((key) => key.id === (body.keyId || ''));
    if (targets.length === 0) { this.jsonError(res, 404, 'key_not_found', 'Key not found'); return; }
    const results = [];
    for (const key of targets) {
      // Sequential on purpose: this avoids hammering membership quota.
      results.push(await this.testOne(key));
    }
    this.json(res, { ok: true, results, state: this.state() });
  }

  async testOne(key) {
    const health = this.store.health();
    const previous = health[key.id];
    const started = Date.now();
    const model = this.selectedModel(key);
    let record;
    try {
      const output = await this.runtime.generate(model, [{ role: 'user', content: 'Reply OK only.' }], 60_000);
      if (!output.trim()) throw new Error('Empty response');
      record = {
        keyId: key.id,
        status: 'ok',
        lastTestAt: new Date().toISOString(),
        durationMs: Date.now() - started,
        model,
        successCount: (previous?.successCount || 0) + 1,
        failureCount: previous?.failureCount || 0
      };
    } catch (caught) {
      record = {
        keyId: key.id,
        status: 'error',
        lastTestAt: new Date().toISOString(),
        durationMs: Date.now() - started,
        model,
        errorMessage: preview(caught.message),
        successCount: previous?.successCount || 0,
        failureCount: (previous?.failureCount || 0) + 1
      };
    }
    health[key.id] = record;
    this.store.writeHealth(health);
    this.store.audit({ timestamp: record.lastTestAt, route: '/admin/health/test', keyId: key.id, model, ok: record.status === 'ok', durationMs: record.durationMs, error: record.errorMessage });
    return healthObject(record);
  }

  v1Models(req, res) {
    if (!this.store.authenticate(req.headers.authorization)) { this.jsonError(res, 401, 'unauthorized', 'Missing or invalid API key', true); return; }
    const models = this.runtime.listModels(false);
    this.json(res, {
      object: 'list',
      data: models.map((model) => ({ id: model.id, object: 'model', created: 0, owned_by: 'opencode' }))
    }, true);
  }

  async chatCompletions(req, res) {
    const key = this.store.authenticate(req.headers.authorization);
    if (!key) { this.jsonError(res, 401, 'unauthorized', 'Missing or invalid API key', true); return; }
    const body = await readJsonBody(req);
    if (body.stream === true) { this.jsonError(res, 400, 'stream_not_supported', 'stream=true is not supported in OCKey 1.0', true); return; }
    const model = this.selectedModel(key, body.model);
    const messages = Array.isArray(body.messages) ? body.messages : [{ role: 'user', content: '' }];
    const started = Date.now();
    const content = await this.runtime.generate(model, messages);
    this.store.consumeUsage(key.id);
    this.store.audit({ timestamp: new Date().toISOString(), route: '/v1/chat/completions', keyId: key.id, model, ok: true, durationMs: Date.now() - started });
    this.json(res, {
      id: `chatcmpl-${crypto.randomUUID()}`,
      object: 'chat.completion',
      created: Math.floor(Date.now() / 1000),
      model,
      choices: [{ index: 0, message: { role: 'assistant', content }, finish_reason: 'stop' }],
      usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 }
    }, true);
  }

  async responses(req, res) {
    const key = this.store.authenticate(req.headers.authorization);
    if (!key) { this.jsonError(res, 401, 'unauthorized', 'Missing or invalid API key', true); return; }
    const body = await readJsonBody(req);
    const model = this.selectedModel(key, body.model);
    const input = normalizeContent(body.input);
    const started = Date.now();
    const content = await this.runtime.generate(model, [{ role: 'user', content: input }]);
    this.store.consumeUsage(key.id);
    this.store.audit({ timestamp: new Date().toISOString(), route: '/v1/responses', keyId: key.id, model, ok: true, durationMs: Date.now() - started });
    this.json(res, {
      id: `resp-${crypto.randomUUID()}`,
      object: 'response',
      created_at: Math.floor(Date.now() / 1000),
      status: 'completed',
      model,
      output: [{ id: `msg-${crypto.randomUUID()}`, type: 'message', status: 'completed', role: 'assistant', content: [{ type: 'output_text', text: content }] }],
      output_text: content,
      usage: { input_tokens: 0, output_tokens: 0, total_tokens: 0 }
    }, true);
  }

  selectedModel(key, requested) {
    return key.assignedModel || requested || this.currentDefaultModel(this.runtime.listModels(false));
  }

  currentDefaultModel(models) {
    const configured = this.store.settings().defaultModel || DEFAULT_MODEL;
    if (models.some((model) => model.id === configured)) return configured;
    return models[0]?.id || DEFAULT_MODEL;
  }

  publicKeys() {
    const visibleById = new Map(this.store.visibleKeys().map((key) => [key.keyId, key.key]));
    const usage = this.store.usage();
    const today = new Date().toISOString().slice(0, 10);
    return this.store.keys().map((key) => ({
      id: key.id,
      name: key.name,
      enabled: key.enabled,
      assignedModel: key.assignedModel,
      createdAt: key.createdAt,
      lastUsedAt: key.lastUsedAt,
      key: visibleById.get(key.id),
      todayUsage: usage.find((row) => row.date === today && row.keyId === key.id)?.count || 0
    }));
  }

  writeHeaders(res, status, contentType = 'application/json; charset=utf-8', cors = false) {
    const headers = {
      'content-type': contentType,
    };
    if (cors) {
      headers['access-control-allow-origin'] = '*';
      headers['access-control-allow-headers'] = 'authorization,content-type';
      headers['access-control-allow-methods'] = 'GET,POST,OPTIONS';
    }
    res.writeHead(status, headers);
  }

  json(res, value, cors = false) {
    this.writeHeaders(res, 200, 'application/json; charset=utf-8', cors);
    res.end(JSON.stringify(value, null, 2));
  }

  jsonError(res, status, code, message, cors = false) {
    this.writeHeaders(res, status, 'application/json; charset=utf-8', cors);
    res.end(JSON.stringify({ error: { code, message } }, null, 2));
  }

  html(res, value) {
    this.writeHeaders(res, 200, 'text/html; charset=utf-8');
    res.end(value);
  }

  redirect(res, location) {
    res.writeHead(302, { location });
    res.end();
  }

  empty(res, status, cors = false) {
    this.writeHeaders(res, status, 'application/json; charset=utf-8', cors);
    res.end();
  }
}

function adminHtml() {
  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>OCKey Windows</title>
  <style>
    :root { color-scheme: light dark; font-family: "Segoe UI", system-ui, sans-serif; }
    * { box-sizing: border-box; }
    body { margin: 0; background: Canvas; color: CanvasText; }
    main { max-width: 1100px; margin: 0 auto; padding: 22px 16px 56px; }
    header { display: flex; justify-content: space-between; gap: 12px; align-items: center; border-bottom: 1px solid color-mix(in srgb, CanvasText 14%, transparent); padding-bottom: 12px; }
    h1 { margin: 0; font-size: 26px; }
    h2 { margin: 0; font-size: 17px; }
    .muted, .meta { color: color-mix(in srgb, CanvasText 62%, transparent); }
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 10px; margin: 16px 0; }
    .card, .row { border: 1px solid color-mix(in srgb, CanvasText 15%, transparent); border-radius: 8px; background: color-mix(in srgb, Canvas 94%, CanvasText 6%); padding: 10px; }
    .card { display: grid; gap: 3px; }
    .dot { width: 10px; height: 10px; border-radius: 50%; display: inline-block; background: #8a8f98; margin-right: 6px; }
    .ok .dot { background: #12805c; } .bad .dot { background: #b42318; } .warn .dot { background: #b7791f; }
    .section { padding: 18px 0; border-bottom: 1px solid color-mix(in srgb, CanvasText 10%, transparent); }
    .head, .connection, .actions { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
    .head { justify-content: space-between; margin-bottom: 12px; }
    .connection { display: grid; grid-template-columns: auto minmax(260px, 1fr) minmax(230px, .8fr) auto; }
    input, select, button { min-height: 34px; border: 1px solid color-mix(in srgb, CanvasText 22%, transparent); border-radius: 6px; background: Canvas; color: CanvasText; padding: 6px 9px; font: inherit; }
    button { cursor: pointer; }
    button:hover { background: color-mix(in srgb, CanvasText 8%, Canvas); }
    ul { list-style: none; padding: 0; margin: 0; display: grid; gap: 8px; }
    .row { display: grid; grid-template-columns: minmax(220px, 1.1fr) minmax(150px, .7fr) minmax(360px, 1.6fr); gap: 10px; align-items: center; }
    .title { font-weight: 700; overflow-wrap: anywhere; }
    .metrics { display: grid; grid-template-columns: repeat(4, auto); gap: 8px; white-space: nowrap; color: color-mix(in srgb, CanvasText 65%, transparent); }
    .key { font-family: ui-monospace, Consolas, monospace; font-size: 12px; overflow-wrap: anywhere; color: color-mix(in srgb, CanvasText 58%, transparent); }
    details { padding: 18px 0; border-bottom: 1px solid color-mix(in srgb, CanvasText 10%, transparent); }
    summary { cursor: pointer; font-weight: 700; font-size: 17px; }
    details > *:not(summary) { margin-top: 12px; }
    .error { color: #b42318; font-size: 12px; overflow-wrap: anywhere; }
    @media (max-width: 780px) { .connection, .row { grid-template-columns: 1fr; } .metrics { grid-template-columns: repeat(2, auto); justify-content: start; } }
  </style>
</head>
<body>
  <main>
    <header>
      <div><h1>OCKey Windows</h1><div class="muted">OpenCode 免费模型 Key 网关</div></div>
      <div class="actions"><button id="refresh">刷新</button><button id="login">开始登录</button></div>
    </header>
    <section class="grid" id="status"></section>
    <section class="section">
      <div class="connection">
        <h2>连接</h2>
        <input id="baseUrl" readonly>
        <input id="defaultModel" readonly>
        <button id="copyBase">复制 Base URL</button>
      </div>
    </section>
    <section class="section">
      <div class="head">
        <h2>通道管理</h2>
        <div class="actions">
          <input id="newName" placeholder="通道名称">
          <select id="newModel"></select>
          <button id="createKey">生成新通道</button>
          <button id="testAll">测试全部通道</button>
        </div>
      </div>
      <ul id="keys"></ul>
    </section>
    <details>
      <summary>OpenCode 运行时</summary>
      <div class="meta" id="runtime"></div>
      <div class="actions">
        <button id="refreshModels">刷新模型</button>
        <button id="checkUpdate">检查更新</button>
        <label><input id="includeExperimental" type="checkbox"> 包含实验模型</label>
      </div>
    </details>
    <details>
      <summary>模型列表</summary>
      <ul id="models"></ul>
    </details>
  </main>
  <script>
    let state = {};
    const $ = id => document.getElementById(id);
    const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
    async function api(path, options = {}) {
      const res = await fetch(path, { ...options, headers: { 'content-type': 'application/json', ...(options.headers || {}) } });
      const body = await res.json();
      if (!res.ok) throw new Error(body.error?.message || res.statusText);
      return body;
    }
    async function refresh() {
      state = await api('/admin/state');
      $('baseUrl').value = state.openAIBaseUrl || '';
      $('defaultModel').value = state.defaultModel || '';
      $('includeExperimental').checked = state.settings?.includeExperimentalModels === true;
      renderStatus(); renderModels(); renderKeys(); renderRuntime();
    }
    function level(h) {
      if (!h) return 'unknown';
      if (h.status !== 'ok') return 'bad';
      if ((h.successRate ?? 1) < .8 || (h.durationMs ?? 0) >= 15000) return 'warn';
      return 'ok';
    }
    function levelText(l) { return l === 'ok' ? '可用' : l === 'warn' ? '不稳定' : l === 'bad' ? '异常' : '未知'; }
    function speed(ms) { return ms ? (ms / 1000).toFixed(ms >= 10000 ? 1 : 2) + 's' : '-'; }
    function renderStatus() {
      const keys = state.keys || [];
      const health = state.keyHealth || {};
      const ok = keys.filter(k => level(health[k.id]) === 'ok').length;
      const unstable = keys.filter(k => level(health[k.id]) === 'warn').length;
      const op = state.opencodeStatus || {};
      const cards = [
        ['OCKey', '运行中', true],
        ['OpenCode', op.authenticated ? '已登录' : '需要登录', op.authenticated],
        ['模型', (state.models || []).length + ' 个', (state.models || []).length > 0],
        ['通道', ok + '/' + keys.length + ' 可用' + (unstable ? ' · ' + unstable + ' 不稳定' : ''), keys.length === 0 || ok > 0]
      ];
      $('status').innerHTML = cards.map(c => '<div class="card '+(c[2]?'ok':'bad')+'"><b><span class="dot"></span>'+esc(c[0])+'</b><span class="meta">'+esc(c[1])+'</span></div>').join('');
    }
    function modelOptions(selected) {
      return '<option value="">默认模型</option>' + (state.models || []).map(m => '<option value="'+esc(m.id)+'" '+(m.id===selected?'selected':'')+'>'+esc(m.displayName || m.id)+(m.free?' · 免费':'')+'</option>').join('');
    }
    function renderKeys() {
      const health = state.keyHealth || {};
      $('newModel').innerHTML = modelOptions('');
      $('keys').innerHTML = (state.keys || []).map(k => {
        const h = health[k.id];
        const l = level(h);
        return '<li class="row '+l+'"><div><div class="title"><span class="dot"></span>'+esc(k.name)+'</div><div class="meta">'+esc(k.assignedModel || state.defaultModel || '默认模型')+'</div><div class="key">'+esc(k.key || '')+'</div>'+(h?.errorMessage?'<div class="error">'+esc(h.errorMessage)+'</div>':'')+'</div><div class="metrics"><b>'+levelText(l)+'</b><span>'+speed(h?.durationMs)+'</span><span>'+((h?.successRate==null)?'-':Math.round(h.successRate*100)+'%')+'</span><span>今日 '+esc(k.todayUsage || 0)+'</span></div><div class="actions"><select data-model="'+esc(k.id)+'">'+modelOptions(k.assignedModel)+'</select><button data-test="'+esc(k.id)+'">测试</button><button data-copy="'+esc(k.id)+'">复制 Key + URL</button><button data-del="'+esc(k.id)+'">删除</button></div></li>';
      }).join('') || '<li class="meta">还没有通道，先生成一个。</li>';
      document.querySelectorAll('[data-model]').forEach(el => el.onchange = () => setModel(el.dataset.model, el.value));
      document.querySelectorAll('[data-test]').forEach(el => el.onclick = () => testKey(el.dataset.test, el));
      document.querySelectorAll('[data-copy]').forEach(el => el.onclick = () => copyKey(el.dataset.copy));
      document.querySelectorAll('[data-del]').forEach(el => el.onclick = () => deleteKey(el.dataset.del));
    }
    function renderModels() {
      $('models').innerHTML = (state.models || []).map(m => '<li class="row"><div><div class="title">'+esc(m.displayName || m.id)+'</div><div class="meta">'+esc(m.id)+'</div></div><div class="metrics"><span>'+(m.free?'免费':'实验')+'</span></div></li>').join('') || '<li class="meta">暂无模型。请先登录 OpenCode。</li>';
    }
    function renderRuntime() {
      const op = state.opencodeStatus || {};
      $('runtime').textContent = '路径：' + (op.path || '-') + ' · 版本：' + (op.version || '-') + (op.error ? ' · ' + op.error : '');
    }
    async function setModel(id, model) { const r = await api('/admin/key-model', { method:'POST', body: JSON.stringify({ keyId:id, model, clear: !model }) }); state = r.state; renderKeys(); }
    async function testKey(id, button) { const old=button.textContent; button.disabled=true; button.textContent='测试中'; try { const r = await api('/admin/health/test', { method:'POST', body: JSON.stringify({ keyId:id }) }); state=r.state; renderStatus(); renderKeys(); } finally { button.disabled=false; button.textContent=old; } }
    async function deleteKey(id) { if (!confirm('删除这个通道？')) return; const r = await api('/admin/delete-key', { method:'POST', body: JSON.stringify({ keyId:id }) }); state=r.state; renderStatus(); renderKeys(); }
    function copyKey(id) { const k = (state.keys || []).find(x => x.id === id); navigator.clipboard.writeText('OPENAI_BASE_URL='+(state.openAIBaseUrl||'')+'\\nOPENAI_API_KEY='+(k?.key||'')); }
    $('refresh').onclick = () => refresh().catch(e => alert(e.message));
    $('copyBase').onclick = () => navigator.clipboard.writeText(state.openAIBaseUrl || '');
    $('login').onclick = () => api('/admin/opencode/login', { method:'POST' }).then(() => alert('已打开 OpenCode 登录窗口，完成后回到这里刷新。')).catch(e => alert(e.message));
    $('createKey').onclick = () => api('/admin/keys', { method:'POST', body: JSON.stringify({ name:$('newName').value || 'OCKey Channel', assignedModel:$('newModel').value || undefined }) }).then(r => { state=r.state; navigator.clipboard.writeText('OPENAI_BASE_URL='+(state.openAIBaseUrl||'')+'\\nOPENAI_API_KEY='+r.key); renderStatus(); renderKeys(); alert('已生成并复制 Key + URL'); }).catch(e => alert(e.message));
    $('testAll').onclick = () => { if (!confirm('测试全部通道会调用模型，可能消耗额度。继续吗？')) return; api('/admin/health/test-all', { method:'POST', body:'{}' }).then(r => { state=r.state; renderStatus(); renderKeys(); }).catch(e => alert(e.message)); };
    $('refreshModels').onclick = () => api('/admin/opencode/refresh-models', { method:'POST' }).then(r => { state=r.state; renderModels(); renderKeys(); renderStatus(); }).catch(e => alert(e.message));
    $('checkUpdate').onclick = () => api('/admin/opencode/check-update', { method:'POST' }).then(r => alert(r.update?.message || '当前版本：' + r.update?.currentVersion)).catch(e => alert(e.message));
    $('includeExperimental').onchange = () => api('/admin/settings', { method:'POST', body: JSON.stringify({ includeExperimentalModels:$('includeExperimental').checked }) }).then(r => { state=r.state; renderModels(); renderKeys(); }).catch(e => alert(e.message));
    refresh().catch(e => alert(e.message));
  </script>
</body>
</html>`;
}

function isAdminPath(pathname) {
  return pathname === '/admin/ui' || pathname.startsWith('/admin/');
}

function isAllowedLocalAdminRequest(req) {
  const fetchSite = String(req.headers['sec-fetch-site'] || '').toLowerCase();
  if (fetchSite && fetchSite !== 'same-origin' && fetchSite !== 'none') return false;

  const origin = req.headers.origin;
  if (!origin) return true;

  const host = req.headers.host || `${HOST}:${PORT}`;
  return new Set([
    BASE_URL,
    `http://${host}`,
    `http://${HOST}:${PORT}`,
    `http://127.0.0.1:${PORT}`,
    `http://localhost:${PORT}`
  ]).has(origin);
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('error', reject);
    req.on('end', () => {
      const text = Buffer.concat(chunks).toString('utf8');
      if (!text.trim()) { resolve({}); return; }
      try { resolve(JSON.parse(text)); } catch { resolve({}); }
    });
  });
}

function healthObject(health) {
  const total = (health.successCount || 0) + (health.failureCount || 0);
  return {
    ...health,
    level: healthLevel(health),
    successRate: total > 0 ? (health.successCount || 0) / total : undefined
  };
}

function healthLevel(health) {
  if (!health) return 'unknown';
  if (health.status !== 'ok') return 'bad';
  const total = (health.successCount || 0) + (health.failureCount || 0);
  const rate = total > 0 ? (health.successCount || 0) / total : 1;
  if (rate < 0.8 || (health.durationMs || 0) >= 15_000) return 'warn';
  return 'ok';
}

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function cleanName(value) {
  return String(value || '').trim();
}

function bearerToken(value) {
  const match = String(value || '').match(/^Bearer\s+(.+)$/i);
  return match?.[1];
}

function isFreeModel(id) {
  return id.toLowerCase().includes('free');
}

function isExperimentalModel(id) {
  return id === 'opencode/gpt-5-nano';
}

function shortModelName(id) {
  return id.replace(/^opencode\//, '');
}

function normalizeContent(value) {
  if (typeof value === 'string') return value;
  if (Array.isArray(value)) {
    return value.map((part) => typeof part?.text === 'string' ? part.text : JSON.stringify(part)).join('\n');
  }
  if (value == null) return '';
  return String(value);
}

function extractOpenCodeText(output) {
  const trimmed = output.trim();
  try {
    const json = JSON.parse(trimmed);
    const text = collectText(json).trim();
    if (text) return text;
  } catch {}
  const chunks = [];
  for (const line of output.split(/\r?\n/)) {
    const clean = stripAnsi(line.trim());
    if (!clean) continue;
    try {
      const text = collectText(JSON.parse(clean));
      if (text) chunks.push(text);
    } catch {
      chunks.push(clean);
    }
  }
  return chunks.join('\n').trim();
}

function collectText(value) {
  if (typeof value === 'string') return '';
  if (Array.isArray(value)) return value.map(collectText).join('');
  if (value && typeof value === 'object') {
    const parts = [];
    for (const key of ['content', 'text', 'delta', 'output']) {
      if (typeof value[key] === 'string') parts.push(value[key]);
    }
    for (const key of ['message', 'part']) {
      if (value[key]) parts.push(collectText(value[key]));
    }
    return parts.join('');
  }
  return '';
}

function stripAnsi(value) {
  return value.replace(/\u001B\[[0-9;]*m/g, '');
}

function preview(value, limit = 500) {
  const text = String(value || '');
  return text.length > limit ? `${text.slice(0, limit)}...` : text;
}

function opencodeEnv(cliPath) {
  const env = { ...process.env };
  const cliDir = path.dirname(cliPath);
  env.PATH = [cliDir, env.PATH, 'C:\\Windows\\System32', 'C:\\Windows'].filter(Boolean).join(path.delimiter);
  env.HOME = env.USERPROFILE || os.homedir();
  env.USERPROFILE = env.USERPROFILE || os.homedir();
  env.TERM = env.TERM || 'dumb';
  return env;
}

function safe(fn, fallback) {
  try { return fn(); } catch { return fallback; }
}

if (require.main === module) {
  const server = new OCKeyServer();
  server.start().then(() => {
    console.log(`OCKey Windows server running at ${BASE_URL}`);
  }).catch((error) => {
    console.error(error);
    process.exit(1);
  });
}

module.exports = {
  OCKeyServer,
  Store,
  OpenCodeRuntime,
  constants: { PORT, HOST, BASE_URL, OPENAI_BASE_URL, DEFAULT_MODEL }
};
