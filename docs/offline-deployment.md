# Offline deployment

This guide covers the complete path from a connected staging machine to an isolated environment. Follow your organization's transfer and software-approval process in addition to these technical checks.

## Understand the two artifact types

airgap-coder publishes two different kinds of artifacts:

- **GitHub release source archives** are reproducible snapshots of the public repository. They include SHA-256 checksums and GitHub build provenance attestations, but not container images or site configuration.
- **`lc export` deployment bundles** are created on your staging machine. They can include the pinned Codex and LiteLLM container images, tracked source, an installer, `MANIFEST.txt`, and `SHA256SUMS`.

Neither artifact contains `.env`, generated Codex state, generated LiteLLM configuration, or `registry.json`.

## 1. Prepare the connected staging machine

Check out a release tag rather than an arbitrary branch, then build and pull the images referenced by that release:

```bash
git clone https://github.com/LouisDM/airgap-coder.git
cd airgap-coder
git checkout v0.1.0

docker build -t airgap-coder:0.145.0 -f docker/Dockerfile .
docker pull ghcr.io/berriai/litellm:main-stable@sha256:90d8de0ea6fbb3cad145d1019d00a0149ae400b1e18e2011a60f1988f143f672
./bin/lc export
```

Use the exact tag and digest from the release you checked out if they differ from this example. A digest, not a mutable tag, identifies the image contents.

If the isolated environment already has both images and only tracked source changed, create a smaller source bundle:

```bash
./bin/lc export --no-images
```

## 2. Inspect the bundle before transfer

The export command prints the output path. Inspect its top-level contents and verify that site-specific files are absent:

```bash
BUNDLE=airgap-coder-0.145.0-YYYYMMDD-HHMMSS.tar.gz
tar tzf "$BUNDLE" | sed -n '1,80p'
```

Expected contents include:

- tracked repository source;
- `install.sh`;
- `MANIFEST.txt`;
- image archives when `--no-images` was not used;
- `SHA256SUMS` for image archives.

The bundle must not contain `.env`, `registry.json`, generated `codex/` or `litellm/` configuration, `.git`, or local Codex state. `registry.json` is excluded because it may contain site-specific model structure even though resolved secrets are forbidden in it. Transfer an approved registry separately or run `lc init` in the isolated environment.

## 3. Transfer and install

After the bundle passes the required organizational review, move it through the approved media or transfer service. In the isolated environment:

```bash
BUNDLE=airgap-coder-0.145.0-YYYYMMDD-HHMMSS.tar.gz
tar xzf "$BUNDLE"
cd airgap-coder-0.145.0-YYYYMMDD-HHMMSS
./install.sh
./bin/lc init
./bin/lc up
./bin/lc doctor
./bin/lc test
```

`install.sh` verifies the image archive checksums before running `docker load`. `lc doctor` then checks the local environment and the configured upstream; `lc test` verifies the gateway path.

## 4. Run the Codex container

Point the container at the internal LiteLLM gateway and mount only the workspace it should access:

```bash
docker run --rm -it -v "$PWD:/workspace" \
  -e GATEWAY_URL=http://gateway.your-intranet.local:4000/v1 \
  -e GATEWAY_KEY=your-gateway-key \
  -e MODEL=your-model \
  airgap-coder:0.145.0 exec "inspect this repository"
```

The mount gives Codex access to the current workspace. Choose the mount and Codex sandbox policy according to the sensitivity of the source and the change being requested.

## Verify a GitHub release source archive

With GitHub CLI installed on a connected verification machine:

```bash
gh release download v0.1.0 --repo LouisDM/airgap-coder
sha256sum -c SHA256SUMS
gh attestation verify airgap-coder-0.1.0.tar.gz --repo LouisDM/airgap-coder
```

Successful verification connects the archive digest to the repository's release workflow and tagged commit. It does not verify a deployment bundle created later on a separate staging machine; validate that bundle through its own manifest, checksums, and approval trail.
