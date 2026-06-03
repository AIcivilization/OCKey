# OCKey Windows

OCKey Windows is a small tray app that exposes bundled OpenCode models through a local OpenAI-compatible API.

It is the Windows sibling of OCKey for macOS. The product goal is the same:

```powershell
$env:OPENAI_BASE_URL="http://127.0.0.1:8789/v1"
$env:OPENAI_API_KEY="ockey_xxx"
```

Use that Base URL and key in other products, while OCKey handles OpenCode locally.

## What It Does

- Starts a local HTTP server on `127.0.0.1:8789`
- Provides `GET /v1/models`
- Provides `POST /v1/chat/completions`
- Provides `POST /v1/responses`
- Generates local `ockey_...` product keys
- Lets each key bind to one OpenCode model
- Shows channel status, speed, success rate, and daily request count
- Copies `OPENAI_BASE_URL` and `OPENAI_API_KEY` together
- Opens OpenCode's official login flow from the tray or web console

## Runtime Rule

OCKey packages only the standalone OpenCode CLI, not the OpenCode desktop app. The build script prepares it at:

```text
resources/runtime/bin/opencode-cli.exe
```

For packaged builds, Electron Builder copies it into the app resources. On first run OCKey copies it to:

```text
%APPDATA%\OCKey\runtime\bin\opencode-cli.exe
```

OCKey does not include or copy your OpenCode login token. Login is performed by the bundled OpenCode CLI through OpenCode's official authentication flow.

Before packaging, prepare and verify the CLI runtime from the project root:

```powershell
npm run prepare:runtime
resources\runtime\bin\opencode-cli.exe --version
```

The default source is the `opencode-windows-x64` npm package. To use a CLI you built from source, set `OCKEY_OPENCODE_RUNTIME_SOURCE` to that exe before running `npm run prepare:runtime`.

## Data

Local product keys, visible key copies, health state, usage counters, and logs are stored under:

```text
%APPDATA%\OCKey
```

## Development

Install dependencies:

```bash
npm install
```

Check syntax:

```bash
npm run check
```

Run the service only:

```bash
npm run start:server
```

Run the tray app:

```bash
npm start
```

Build Windows installers:

```bash
npm run build
```

## Smoke Test

The smoke test uses a temporary `%APPDATA%` and a test port. It does not call OpenCode models.

```bash
npm run smoke
```

## Notes

- First version targets Windows x64.
- `stream=true` is rejected intentionally in 1.0.
- Default model list only exposes models marked `free`.
- `opencode/gpt-5-nano` is treated as experimental and hidden unless the experimental switch is enabled.
- `测试全部通道` calls models sequentially to avoid hammering membership quota.

## OpenCode

OCKey is a local wrapper around OpenCode CLI. It does not bypass OpenCode accounts, authentication, subscriptions, limits, or service rules.

- https://opencode.ai
- https://github.com/opencode-ai/opencode
