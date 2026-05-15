'use strict';

const { app, Tray, Menu, shell, clipboard, dialog, nativeImage } = require('electron');
const path = require('node:path');
const { OCKeyServer, Store, OpenCodeRuntime, constants } = require('./server');

let tray;
let store;
let runtime;
let server;
let lastState = {};

function trayIcon() {
  const svg = encodeURIComponent(`
    <svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32">
      <rect width="32" height="32" rx="7" fill="#1f6feb"/>
      <circle cx="12" cy="14" r="5" fill="#fff"/>
      <path d="M16 14h10v4h-3v3h-4v-3h-3z" fill="#fff"/>
    </svg>
  `);
  return nativeImage.createFromDataURL(`data:image/svg+xml;charset=utf-8,${svg}`);
}

async function bootstrap() {
  app.setAppUserModelId('local.ockey.windows');
  await app.whenReady();

  store = new Store();
  runtime = new OpenCodeRuntime(store);
  server = new OCKeyServer(store, runtime);

  try {
    await server.start();
  } catch (error) {
    dialog.showErrorBox('OCKey failed to start', error.message);
  }

  tray = new Tray(trayIcon());
  tray.setToolTip('OCKey');
  refresh();
  setInterval(refresh, 5000).unref?.();
}

function refresh() {
  try {
    lastState = server.state();
  } catch (error) {
    lastState = { ok: false, error: error.message, keys: [], keyHealth: {}, opencodeStatus: {} };
  }
  rebuildMenu();
}

function rebuildMenu() {
  if (!tray) return;
  const keys = lastState.keys || [];
  const health = lastState.keyHealth || {};
  const opencode = lastState.opencodeStatus || {};
  const okCount = keys.filter((key) => health[key.id]?.level === 'ok').length;
  const unstableCount = keys.filter((key) => health[key.id]?.level === 'warn').length;
  const title = opencode.authenticated
    ? `● OCKey 运行中 · ${okCount} 可用${unstableCount ? ` · ${unstableCount} 不稳定` : ''}`
    : '● OCKey 需处理 · OpenCode 未登录';

  tray.setToolTip(title);
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: title, enabled: false },
    { label: recommendedText(), enabled: false },
    { type: 'separator' },
    { label: '打开控制台', click: openConsole },
    { label: '复制 Base URL', click: copyBaseURL },
    { label: '生成新通道', click: generateKey },
    { label: '刷新状态', click: refresh },
    { type: 'separator' },
    {
      label: '全部通道',
      submenu: channelMenu(keys, health)
    },
    { type: 'separator' },
    { label: '开始登录 OpenCode', click: startLogin },
    { label: '刷新模型', click: refreshModels },
    { label: '检查 OpenCode 更新', click: checkUpdate },
    { type: 'separator' },
    { label: '打开数据目录', click: () => shell.openPath(store.dataRoot) },
    { label: '打开日志目录', click: () => shell.openPath(store.logsRoot) },
    { type: 'separator' },
    { label: '退出', click: () => app.quit() }
  ]));
}

function channelMenu(keys, health) {
  if (keys.length === 0) {
    return [{ label: '还没有通道，先生成一个', enabled: false }];
  }
  return keys.map((key) => ({
    label: channelTitle(key, health[key.id]),
    submenu: [
      { label: `模型：${key.assignedModel || lastState.defaultModel || '默认模型'}`, enabled: false },
      { label: `今日：${key.todayUsage || 0} 次`, enabled: false },
      { label: `Key：${mask(key.key || '')}`, enabled: false },
      ...(health[key.id]?.errorMessage ? [{ label: `错误：${compact(health[key.id].errorMessage, 80)}`, enabled: false }] : []),
      { type: 'separator' },
      { label: '复制 Key + URL', click: () => copyKeyAndURL(key) },
      { label: '只复制 Key', click: () => clipboard.writeText(key.key || '') },
      { label: '测试此通道', click: () => testKey(key.id) }
    ]
  }));
}

function channelTitle(key, health) {
  const model = String(key.assignedModel || lastState.defaultModel || '默认模型').replace(/^opencode\//, '');
  return `${key.name || 'OCKey Channel'} · ${model} · ${healthText(health)} · ${speedText(health)}`;
}

function healthText(health) {
  if (!health) return '未知';
  if (health.level === 'ok') return '可用';
  if (health.level === 'warn') return '不稳定';
  if (health.level === 'bad') return '异常';
  return '未知';
}

function speedText(health) {
  if (!health?.durationMs) return '-';
  const seconds = health.durationMs / 1000;
  return seconds >= 10 ? `${seconds.toFixed(1)}s` : `${seconds.toFixed(2)}s`;
}

function recommendedText() {
  const rec = lastState.recommendedKey;
  if (!rec?.name) return '推荐：无';
  return `推荐：${rec.name} · ${speedText({ durationMs: rec.durationMs })}`;
}

function openConsole() {
  shell.openExternal(`${constants.BASE_URL}/admin/ui`);
}

function copyBaseURL() {
  clipboard.writeText(constants.OPENAI_BASE_URL);
}

function generateKey() {
  const { key } = store.createKey('OCKey Channel');
  clipboard.writeText(`OPENAI_BASE_URL=${constants.OPENAI_BASE_URL}\nOPENAI_API_KEY=${key}`);
  refresh();
  dialog.showMessageBox({ type: 'info', message: '已生成并复制', detail: 'Key + URL 已复制，可以直接粘贴到产品里。' });
}

function copyKeyAndURL(key) {
  clipboard.writeText(`OPENAI_BASE_URL=${constants.OPENAI_BASE_URL}\nOPENAI_API_KEY=${key.key || ''}`);
}

async function testKey(keyId) {
  const key = store.keys().find((candidate) => candidate.id === keyId);
  if (!key) return;
  await server.testOne(key);
  refresh();
}

function startLogin() {
  try {
    runtime.startLogin();
    dialog.showMessageBox({ type: 'info', message: '已打开 OpenCode 登录窗口', detail: '完成官方登录后，回到 OCKey 点击刷新。' });
  } catch (error) {
    dialog.showErrorBox('无法打开登录', error.message);
  }
}

function refreshModels() {
  try {
    runtime.refreshModels();
    refresh();
  } catch (error) {
    dialog.showErrorBox('刷新模型失败', error.message);
  }
}

function checkUpdate() {
  const update = runtime.checkUpdate();
  dialog.showMessageBox({ type: 'info', message: 'OpenCode 更新', detail: update.message || `当前版本：${update.currentVersion || 'unknown'}` });
}

function mask(key) {
  if (!key || key.length <= 18) return '......';
  return `${key.slice(0, 10)}......${key.slice(-6)}`;
}

function compact(value, maxLength) {
  const text = String(value || '');
  return text.length > maxLength ? `${text.slice(0, maxLength - 1)}…` : text;
}

app.on('window-all-closed', (event) => {
  event.preventDefault();
});

app.on('before-quit', async () => {
  if (server) await server.stop();
});

bootstrap();
