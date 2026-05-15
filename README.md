# OCKey

OCKey is a tiny macOS menu-bar app that exposes OpenCode models through a local OpenAI-compatible API.

It is designed to be installed as a standalone app. The app bundle includes an OpenCode CLI runtime, starts a local server at `127.0.0.1:8789`, generates local `ockey_...` API keys, and defaults to OpenCode models marked as free.

## Quick Start

1. Install `OCKey.app`.
2. Open OCKey from Applications.
3. Open the menu-bar item and choose `Open Console`.
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
