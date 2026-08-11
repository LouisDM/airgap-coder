# Local Codex workflow

The repository supports a local Codex review path that does not require an `OPENAI_API_KEY`. It uses the developer's existing Codex CLI login, including ChatGPT sign-in, and keeps the session ephemeral.

```bash
codex login status
scripts/codex-review.sh --base main
```

For unstaged work only:

```bash
scripts/codex-review.sh --uncommitted
```

The wrapper forces a read-only sandbox and `approval_policy="never"`, adds `--ignore-user-config` so user-configured MCP servers and hooks cannot create external side effects, uses Codex's built-in repository review target, and writes only the final report into ignored `.codex-review/`. Authentication is still loaded by Codex, but the wrapper does not read, copy, print, or commit authentication files. Codex CLI 0.145 does not allow a custom prompt together with `review --base` or `review --uncommitted`, so the project-specific checklist remains documented for maintainer review rather than being passed as a conflicting argument.

## Why this is local

ChatGPT sign-in is appropriate for an interactive developer machine. GitHub-hosted automation is programmatic and requires a provider API key or another explicitly supported CI credential. Do not upload a local ChatGPT/Codex authentication file to Actions secrets and do not attempt to replay local login state in CI.

CI therefore validates all deterministic behavior without OpenAI access: syntax, generated configuration, secret invariants, offline bundle contents, the mock Responses-to-Chat-Completions bridge, and container startup. A cloud Codex review workflow can be added later if the project receives an API grant and the maintainer approves its permissions and cost controls.

Local Codex review is advisory. The maintainer remains responsible for checking the diff, test evidence, workflow permissions, release contents, and compatibility claims.
