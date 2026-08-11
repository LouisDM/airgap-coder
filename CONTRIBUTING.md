# Contributing to airgap-coder

Thank you for helping make Codex usable in restricted networks. Small, reproducible changes are easiest to review.

## Before opening a change

1. Search existing issues and pull requests.
2. For security vulnerabilities, follow [SECURITY.md](SECURITY.md) instead of opening a public issue.
3. For behavior changes, open an issue first when the protocol, secret boundary, sandbox behavior, or offline-bundle format would change.

## Development setup

The management CLI uses Python's standard library only. Local checks need Python 3.9+, Bash, Git, and Docker for image/export tests. A real model is optional.

```bash
git clone https://github.com/LouisDM/airgap-coder.git
cd airgap-coder
python3 bin/lc --help
bash scripts/test-doctor-probe.sh
bash scripts/test-export.sh
bash scripts/test-lc-secrets.sh
```

Never commit `.env`, generated `codex/` profiles, generated `litellm/config.yaml`, local Codex state, credentials, or private endpoint URLs. Use documentation-only hosts such as `example.local` in fixtures.

## Pull requests

- Keep each pull request focused and explain the user-visible effect.
- Add a regression test for behavior changes.
- Preserve Python 3.9 compatibility and the standard-library-only rule for `bin/lc` and `scripts/*.py`.
- Update both READMEs when changing user-facing commands or security behavior.
- Record compatibility claims with the exact Codex, LiteLLM, inference server, model, and result.
- Run the local checks below and paste the results into the pull request template.

```bash
python3 -m py_compile bin/lc scripts/*.py
bash -n scripts/*.sh docker/entrypoint.sh
python3 scripts/test-project-metadata.py
bash scripts/test-version.sh
bash scripts/test-entrypoint.sh
bash scripts/test-codex-review-script.sh
bash scripts/test-doctor-probe.sh
bash scripts/test-export.sh
bash scripts/test-lc-secrets.sh
bash scripts/test-litellm-bridge.sh
git diff --check
```

The LiteLLM bridge test requires Docker and pulls the digest pinned in `docker-compose.yml`. All other listed checks are GPU-free; none requires an OpenAI API key or a real model.

If you use Codex locally, `scripts/codex-review.sh` can perform a read-only review with your existing ChatGPT sign-in. Local sign-in credentials must never be copied into GitHub Actions or committed.

## Commit and review expectations

Use clear imperative commit subjects. Maintainers may ask for changes when a pull request weakens a secret-handling invariant, introduces an unpinned network dependency, changes `.github/` automation, or lacks a test for new behavior.

By submitting a contribution, you agree that it is licensed under Apache-2.0.
