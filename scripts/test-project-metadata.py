#!/usr/bin/env python3
"""Validate OSS metadata, local links, and immutable network dependencies."""
from __future__ import print_function

import os
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REQUIRED = [
    "LICENSE", "NOTICE", "README.md", "README.zh-CN.md", "VERSION",
    "CHANGELOG.md", "CONTRIBUTING.md", "SECURITY.md", "CODE_OF_CONDUCT.md",
    "SUPPORT.md", "docs/architecture.md", "docs/compatibility.md",
    "docs/threat-model.md", "docs/adopters.md", "docs/codex-workflow.md",
    "docs/README.md", "docs/offline-deployment.md", "docs/troubleshooting.md",
    ".github/pull_request_template.md",
    ".github/ISSUE_TEMPLATE/bug.yml",
    ".github/ISSUE_TEMPLATE/feature.yml",
    ".github/ISSUE_TEMPLATE/compatibility.yml",
    ".github/ISSUE_TEMPLATE/config.yml", ".github/dependabot.yml",
    ".github/workflows/ci.yml", ".github/workflows/release.yml",
]


def fail(message):
    print("❌ " + message)
    return 1


def main():
    failures = 0
    for relative in REQUIRED:
        if not (ROOT / relative).is_file():
            failures += fail("missing required project file: %s" % relative)

    version = (ROOT / "VERSION").read_text().strip()
    if not re.match(r"^[0-9]+\.[0-9]+\.[0-9]+$", version):
        failures += fail("VERSION is not semantic versioning: %r" % version)

    if not os.access(str(ROOT / "scripts" / "codex-review.sh"), os.X_OK):
        failures += fail("scripts/codex-review.sh is documented as a direct command but is not executable")

    markdown_files = list(ROOT.glob("*.md")) + list((ROOT / "docs").glob("*.md"))
    link_pattern = re.compile(r"\[[^]]+\]\(([^)]+)\)")
    for document in markdown_files:
        for target in link_pattern.findall(document.read_text()):
            clean = target.split("#", 1)[0].strip()
            if not clean or clean.startswith(("http://", "https://", "mailto:")):
                continue
            linked = (document.parent / clean).resolve()
            if not linked.exists():
                failures += fail("broken local link in %s: %s" %
                                 (document.relative_to(ROOT), target))

    readme = (ROOT / "README.md").read_text()
    readme_zh = (ROOT / "README.zh-CN.md").read_text()
    required_readme_targets = [
        "docs/README.md", "docs/architecture.md", "docs/compatibility.md",
        "docs/offline-deployment.md", "docs/troubleshooting.md",
        "docs/threat-model.md", "docs/codex-workflow.md",
    ]
    for target in required_readme_targets:
        for name, content in (("README.md", readme), ("README.zh-CN.md", readme_zh)):
            if "](%s)" % target not in content:
                failures += fail("%s does not link to %s" % (name, target))

    if "README.zh-CN.md" not in readme or "README.md" not in readme_zh:
        failures += fail("README language switch is incomplete")

    readme_commands = (
        "lc init", "lc up", "lc test", "lc code", "lc doctor", "lc e2e",
        "lc export", "lc version",
    )
    for command in readme_commands:
        if command not in readme or command not in readme_zh:
            failures += fail("bilingual READMEs do not both document %s" % command)

    # This is a coarse drift guard; translated headings cannot be compared verbatim.
    english_sections = re.findall(r"^## .+$", readme, re.MULTILINE)
    chinese_sections = re.findall(r"^## .+$", readme_zh, re.MULTILINE)
    if len(english_sections) != len(chinese_sections):
        failures += fail("bilingual README section counts differ: %d != %d" %
                         (len(english_sections), len(chinese_sections)))

    command_row = "| `lc "
    if readme.count(command_row) != readme_zh.count(command_row):
        failures += fail("bilingual README command tables have different row counts")

    action_pattern = re.compile(r"^\s*-\s+uses:\s+[^\s]+@([^\s#]+)", re.MULTILINE)
    sha_pattern = re.compile(r"^[0-9a-f]{40}$")
    for workflow in (ROOT / ".github" / "workflows").glob("*.yml"):
        for ref in action_pattern.findall(workflow.read_text()):
            if not sha_pattern.match(ref):
                failures += fail("GitHub Action is not pinned to a commit in %s: %s" %
                                 (workflow.name, ref))

    dockerfile = (ROOT / "docker" / "Dockerfile").read_text()
    if not re.search(r"^FROM\s+[^\s]+@sha256:[0-9a-f]{64}$", dockerfile, re.MULTILINE):
        failures += fail("Dockerfile base image is not pinned by digest")
    compose = (ROOT / "docker-compose.yml").read_text()
    if not re.search(r"image:\s+[^\s]+@sha256:[0-9a-f]{64}", compose):
        failures += fail("LiteLLM image is not pinned by digest")

    if failures:
        raise SystemExit(1)
    print("✅ OSS metadata, local links, Actions pins, and image digests passed")


if __name__ == "__main__":
    main()
