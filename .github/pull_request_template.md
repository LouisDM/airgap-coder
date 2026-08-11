## What changed

<!-- Describe the user-visible result and why this approach was chosen. -->

## Security and compatibility

- [ ] I did not commit `.env`, credentials, private endpoints, generated Codex/LiteLLM config, or local session data.
- [ ] I considered the effect on the secret boundary and offline export.
- [ ] I updated compatibility documentation for version or protocol changes.
- [ ] New dependencies and workflow changes are pinned and explained.

## Verification

- [ ] `python3 -m py_compile bin/lc scripts/*.py`
- [ ] `bash -n scripts/*.sh docker/entrypoint.sh`
- [ ] `python3 scripts/test-project-metadata.py`
- [ ] `bash scripts/test-version.sh`
- [ ] `bash scripts/test-entrypoint.sh`
- [ ] `bash scripts/test-codex-review-script.sh`
- [ ] `bash scripts/test-doctor-probe.sh`
- [ ] `bash scripts/test-export.sh`
- [ ] `bash scripts/test-lc-secrets.sh`
- [ ] `bash scripts/test-litellm-bridge.sh` (requires Docker)
- [ ] `git diff --check`

<!-- Paste additional model, Docker, integration, or Codex review evidence here. -->
