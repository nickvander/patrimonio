#!/usr/bin/env bash
# Pre-merge / pre-commit gate. Runs the backend test suite AND
# `flutter analyze` on the frontend. Both must pass for this script
# to exit 0. Treat as the canonical "is this branch shippable?" check.
#
# Why this exists: two recent sprints shipped frontend bugs that
# `cargo test` couldn't have caught — code that compiled under the
# IDE's incremental analyzer but failed the release dart2js build.
# (Examples: `await onUpdate(id, {...map})` against a callback that
# takes named args; a `'\x00'` sentinel literal that turned the file
# into git-binary.) Running `flutter analyze` alongside `cargo test`
# catches both classes before they hit `git push`.
#
# Usage:
#   ./scripts/check.sh                 # full sweep
#   ./scripts/check.sh --skip-backend  # frontend only (fast iteration)
#   ./scripts/check.sh --skip-frontend # backend only
#
# Wire as pre-commit hook (opt-in — not enabled by default because
# the backend test suite takes ~2 min):
#
#   ln -s ../../scripts/check.sh .git/hooks/pre-commit
#
# Or call from CI directly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SKIP_BACKEND=false
SKIP_FRONTEND=false
for arg in "$@"; do
    case "$arg" in
        --skip-backend) SKIP_BACKEND=true ;;
        --skip-frontend) SKIP_FRONTEND=true ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "error: unknown flag '$arg' (try --help)" >&2
            exit 2
            ;;
    esac
done

# Pretty section header so the user can tell which step failed.
section() {
    printf '\n\033[1;36m━━━ %s ━━━\033[0m\n\n' "$*"
}

ok() { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m✗ %s\033[0m\n' "$*"; }

if [[ "$SKIP_BACKEND" == "false" ]]; then
    section "Backend — cargo test"
    if ! "$SCRIPT_DIR/test.sh"; then
        fail "backend tests failed — fix before committing"
        exit 1
    fi
    ok "backend tests"
else
    echo "(skipped backend per --skip-backend)"
fi

if [[ "$SKIP_FRONTEND" == "false" ]]; then
    section "Frontend — flutter analyze (errors + warnings are fatal)"
    # Reuse the cirruslabs/flutter image rather than baking our own —
    # the frontend Dockerfile already pulls a Flutter image during
    # builds, so this is the same artefact size on disk.
    FLUTTER_IMAGE="${FLUTTER_IMAGE:-ghcr.io/cirruslabs/flutter:stable}"
    if ! docker image inspect "$FLUTTER_IMAGE" >/dev/null 2>&1; then
        echo "→ pulling $FLUTTER_IMAGE (one-time)"
        docker pull -q "$FLUTTER_IMAGE"
    fi
    # Flutter's exit-code semantics for `--fatal-warnings` are version-
    # dependent — some Flutter versions exit non-zero for any issue
    # including info. We side-step that by capturing the output and
    # grep-counting `error •` and `warning •` lines ourselves. Info
    # diagnostics still surface in the log (useful for follow-ups) but
    # don't fail the gate.
    ANALYZER_LOG="$(mktemp)"
    trap 'rm -f "$ANALYZER_LOG"' EXIT
    docker run --rm \
            -v "${REPO_ROOT}/frontend:/app" \
            -w /app \
            "$FLUTTER_IMAGE" \
            bash -lc 'flutter pub get >/dev/null 2>&1 && flutter analyze 2>&1' \
            | tee "$ANALYZER_LOG" || true
    # Count true severities. The leading whitespace in the analyzer's
    # output is "   info" / "  warning" / "  error" (varying indents)
    # so we anchor on the bullet to be format-agnostic.
    errors=$(grep -cE "^[[:space:]]*error • " "$ANALYZER_LOG" || true)
    warnings=$(grep -cE "^[[:space:]]*warning • " "$ANALYZER_LOG" || true)
    if [[ "$errors" -gt 0 || "$warnings" -gt 0 ]]; then
        fail "flutter analyze: $errors error(s), $warnings warning(s) — fix before committing"
        exit 1
    fi
    ok "flutter analyze ($errors errors, $warnings warnings)"
else
    echo "(skipped frontend per --skip-frontend)"
fi

section "All checks passed"
ok "ready to commit"
