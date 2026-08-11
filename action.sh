#!/bin/sh
# action.sh — add supply-chain review to a GitHub repository.
#
#   cd your-repo
#   curl -fsSL https://install.atomdrift.org/action.sh | sh
#
# Writes one workflow file and nothing else — never git state. Re-running is a
# no-op. Committing it is yours to do, once you have read it.
#
# POSIX sh only — no bashisms, no `local`, no arrays.

set -eu

ACTION="atomdrift-project/isomer-action"
VERSION="v0.1.0"
WORKFLOW=".github/workflows/supply-chain.yml"

FORCE=0
DRY_RUN=0
SOURCE_ONLY=0

usage() {
    cat <<EOF
isomer-action — add supply-chain review to this repository.

usage: action.sh [options]

      --source-only Audit the source only; skip the build-output comparison.
      --force       Replace an existing $WORKFLOW that differs.
      --dry-run     Print the workflow instead of writing it.
  -h, --help        This.
EOF
}

die() { printf 'isomer-action: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --source-only) SOURCE_ONLY=1; shift ;;
        --force) FORCE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

command -v git >/dev/null 2>&1 || die "git is not installed"
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) \
    || die "not inside a git repository — cd to the repository you want to protect"
cd "$ROOT" || die "cannot enter $ROOT"

STACK=none
if [ "$SOURCE_ONLY" = 0 ]; then
    if [ -f package.json ]; then STACK=node
    elif [ -f Cargo.toml ]; then STACK=rust
    elif [ -f go.mod ]; then STACK=go
    elif [ -f pyproject.toml ] || [ -f setup.py ]; then STACK=python
    fi
fi

DEFAULT_BRANCH=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
[ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo main)

# Every stack publishes into dist/, so the rest of the workflow is identical.
build_block() {
    case "$STACK" in
        node)
            cat <<'EOF'
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: npm
      - run: npm ci
      - run: npm run build
EOF
            ;;
        rust)
            cat <<'EOF'
      - run: cargo build --release --locked
      # Binaries only: target/release also holds build intermediates, and
      # everything under ARTIFACTS is cached per commit.
      - run: |
          mkdir -p dist
          find target/release -maxdepth 1 -type f -perm -u+x -exec cp {} dist/ \;
EOF
            ;;
        go)
            cat <<'EOF'
      - uses: actions/setup-go@v5
        with:
          go-version: stable
      - run: go build -o dist/ ./...
EOF
            ;;
        python)
            cat <<'EOF'
      - uses: actions/setup-python@v5
        with:
          python-version: '3.x'
      - run: python -m pip install --upgrade build
      - run: python -m build
EOF
            ;;
    esac
}

source_only_workflow() {
    cat <<EOF
# Supply-chain review: judges what this change does that the code before it
# didn't. Added by https://install.atomdrift.org/action.sh
#
# No build step was detected here. To also compare build output, see
# https://github.com/$ACTION/blob/$VERSION/examples/build-comparison.yml
name: supply-chain

on: pull_request

permissions:
  contents: read
  pull-requests: write    # sticky comment      (optional)
  security-events: write  # inline annotations  (optional)

jobs:
  isomer:
    name: isomer · source
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: $ACTION@$VERSION
EOF
}

full_workflow() {
    cat <<EOF
# Supply-chain review: judges what this change does that the code before it
# didn't — in the source, and in what the source builds into.
# Added by https://install.atomdrift.org/action.sh
#
# The source is audited before anything is built, because building a pull
# request executes it. The build's output is then compared against the base
# branch's build, because a backdoor injected during the build is in neither
# commit and nothing reading the diff alone can see it.
#
# Cost: one build in the common case — the base branch's output is cached under
# the commit that produced it — and never extra wall clock, since when both
# sides do build they build in parallel.
name: supply-chain

on:
  pull_request:
  push:
    branches: [$DEFAULT_BRANCH]   # seeds the cache every pull request reads

permissions:
  contents: read

env:
  # What you ship, not the whole build tree: every file here is cached per
  # commit against a 10 GB repository ceiling.
  ARTIFACTS: dist

jobs:
  gate:
    name: isomer · source
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write    # sticky comment      (optional)
      security-events: write  # inline annotations  (optional)
    outputs:
      base-sha: \${{ steps.scan.outputs.base-sha }}
      sides: \${{ steps.plan.outputs.sides }}
    steps:
      - uses: actions/checkout@v4
      - id: scan
        uses: $ACTION@$VERSION
      - id: cached
        if: github.event_name == 'pull_request'
        uses: $ACTION/artifacts@$VERSION
        with:
          path: .isomer/baseline
          sha: \${{ steps.scan.outputs.base-sha }}
          mode: probe
      - id: plan
        shell: bash
        env:
          HIT: \${{ steps.cached.outputs.cache-hit }}
        run: |
          if [ "\$GITHUB_EVENT_NAME" = "push" ] || [ "\$HIT" = "true" ]; then
            echo 'sides=["head"]'
          else
            echo 'sides=["base","head"]'
          fi >> "\$GITHUB_OUTPUT"

  build:
    needs: gate
    runs-on: ubuntu-latest
    # Runs the pull request's own code, so it holds no write permission.
    strategy:
      fail-fast: false
      matrix:
        side: \${{ fromJSON(needs.gate.outputs.sides) }}
    # A base commit that no longer builds is not this pull request's fault.
    continue-on-error: \${{ matrix.side == 'base' }}
    steps:
      - uses: actions/checkout@v4
        with:
          ref: \${{ matrix.side == 'base' && needs.gate.outputs.base-sha || '' }}

      # ─────────────────────── your build starts here ───────────────────────
$(build_block)
      # ──────────────────────── your build ends here ────────────────────────

      # One fixed path, because a cache entry restores to the path it was saved
      # from rather than the one asked for.
      - shell: bash
        env:
          SIDE: \${{ matrix.side }}
        run: |
          mkdir -p .isomer
          if [ "\$SIDE" = "base" ] || [ "\$GITHUB_EVENT_NAME" = "push" ]; then
            mv "\$ARTIFACTS" .isomer/baseline
          else
            mv "\$ARTIFACTS" .isomer/head
          fi

      - if: matrix.side == 'base'
        uses: $ACTION/artifacts@$VERSION
        with:
          path: .isomer/baseline
          sha: \${{ needs.gate.outputs.base-sha }}
          mode: save

      # Caches made on the default branch are readable from every branch; a
      # pull request's own are visible only to itself.
      - if: github.event_name == 'push'
        uses: $ACTION/artifacts@$VERSION
        with:
          path: .isomer/baseline
          sha: \${{ github.sha }}
          mode: save

      - if: matrix.side == 'head' && github.event_name == 'pull_request'
        uses: actions/upload-artifact@v4
        with:
          name: isomer-head
          path: .isomer/head
          retention-days: 1

  compare:
    name: isomer · source + build output
    if: \${{ !cancelled() && github.event_name == 'pull_request' }}
    needs: [gate, build]
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
      security-events: write
    steps:
      - uses: actions/checkout@v4
      # A cache miss is not an error: isomer reports that the build comparison
      # did not run rather than passing a source-only scan off as the whole.
      - uses: $ACTION/artifacts@$VERSION
        with:
          path: .isomer/baseline
          sha: \${{ needs.gate.outputs.base-sha }}
      - uses: actions/download-artifact@v4
        with:
          name: isomer-head
          path: .isomer/head
      - uses: $ACTION@$VERSION
        with:
          base-artifacts: .isomer/baseline
          head-artifacts: .isomer/head
EOF
}

render() {
    if [ "$STACK" = none ]; then source_only_workflow; else full_workflow; fi
}

if [ "$DRY_RUN" = 1 ]; then
    render
    exit 0
fi

NEW=$(render)
if [ -f "$WORKFLOW" ] && [ "$NEW" = "$(cat "$WORKFLOW")" ]; then
    printf 'isomer-action: %s is already current\n' "$WORKFLOW"
    exit 0
fi
if [ -f "$WORKFLOW" ] && [ "$FORCE" = 0 ]; then
    die "$WORKFLOW exists and differs — re-run with --force to replace it, or --dry-run to preview"
fi

mkdir -p "$(dirname "$WORKFLOW")" || die "cannot create $(dirname "$WORKFLOW")"
printf '%s\n' "$NEW" > "$WORKFLOW" || die "could not write $WORKFLOW"

case "$STACK" in
    none) DETECTED="no build detected — auditing the source only" ;;
    *) DETECTED="detected a $STACK build publishing to dist/ (the ARTIFACTS setting)" ;;
esac

cat <<EOF
isomer-action: wrote $WORKFLOW
  $DETECTED

Review it first — the build block is a guess, and only you know whether it
produces what you actually ship. Then:

    git add $WORKFLOW
    git commit -m 'ci: add isomer supply-chain review'
EOF
