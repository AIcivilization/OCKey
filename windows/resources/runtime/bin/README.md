Put the Windows OpenCode CLI runtime here before packaging:

```text
opencode-cli.exe
```

Run `npm run prepare:runtime` to copy it from `opencode-windows-x64`,
or set `OCKEY_OPENCODE_RUNTIME_SOURCE` to a standalone CLI exe you built
from the OpenCode source tree.

Verify it with `opencode-cli.exe --version` before packaging.

Do not commit account tokens or login state. OCKey only bundles the runtime executable.
