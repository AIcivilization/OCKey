# OCKey

OCKey is a tiny local app that exposes OpenCode models through a local OpenAI-compatible API.

It is designed to be installed as a standalone app. The app bundle includes an OpenCode CLI runtime, starts a local server at `127.0.0.1:8789`, generates local `ockey_...` API keys, and defaults to OpenCode models marked as free.

The macOS menu-bar version lives in [`app/`](app/). The Windows tray version lives in [`windows/`](windows/).

## Windows Build

The Windows tray version uses the same local API shape, port, and `ockey_...` key format, but is packaged with Electron for Windows.

Before building the Windows package, run:

```powershell
cd windows
npm install
npm run build
```

The Windows build copies only the standalone OpenCode CLI from the `opencode-windows-x64` npm package into `windows/resources/runtime/bin/opencode-cli.exe`. It does not bundle the OpenCode desktop app.

## Quick Start

1. Install `OCKey.app` on macOS, or run the Windows setup/portable executable.
2. Open OCKey.
3. Open the menu-bar/tray item and choose the console.
4. If OpenCode is not logged in, click `Start Login`.
5. Generate a channel and copy `Key + URL`.

Use the copied values in other products:

```bash
OPENAI_BASE_URL=http://127.0.0.1:8789/v1
OPENAI_API_KEY=ockey_xxx
```

## API

- `GET /health`
- `GET /v1/models`
- `POST /v1/chat/completions`
- `POST /v1/responses`

`/v1/*` endpoints require `Authorization: Bearer ockey_...`.

## Data

OCKey stores local product keys and health data in:

```text
~/Library/Application Support/OCKey/data
```

The bundled OpenCode runtime is copied to:

```text
~/Library/Application Support/OCKey/runtime/bin/opencode
```

OCKey does not bundle or copy your OpenCode login credentials. Login is performed through the bundled OpenCode CLI using OpenCode's official authentication flow.

## OpenCode

OCKey includes an OpenCode CLI binary for convenience. OpenCode is an open-source project. See the OpenCode project and license for details:

- https://opencode.ai
- https://github.com/opencode-ai/opencode

OCKey is a local wrapper around the OpenCode CLI. It does not bypass OpenCode accounts, authentication, subscriptions, or service rules.
