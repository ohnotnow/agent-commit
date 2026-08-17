#!/bin/bash
# Test battery for agent-github. All git repositories are created under a
# temporary directory and GitHub is represented by a deliberately tiny fake
# `gh` executable. No network calls or real GitHub changes are made.

HERE=$(cd "$(dirname "$0")" && pwd)
AG="$HERE/agent-github"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/agent-github-tests.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
FAKE_BIN="$WORK/bin"
AG_FAKE_LOG="$WORK/gh-create.log"
FAILS=0
REPO_N=0

[ -x "$AG" ] || { echo "no executable agent-github next to this script"; exit 1; }
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/gh" <<'EOF'
#!/bin/bash
case "${1:-} ${2:-}" in
    'api user')
        printf '%s\n' "${AG_FAKE_USER:-test-user}"
        exit 0
        ;;
    'api user/memberships/orgs')
        printf '%s\n' 'test-org' 'another-org'
        exit 0
        ;;
    'repo view')
        if [ "${AG_FAKE_EXISTING:-0}" = "1" ]; then
            printf '%s\n' "$3"
            exit 0
        fi
        exit 1
        ;;
    'repo create')
        target=$3
        shift 3
        printf '%s' "$target" >> "$AG_FAKE_LOG"
        source_dir=""
        remote_name=""
        while [ $# -gt 0 ]; do
            printf ' <%s>' "$1" >> "$AG_FAKE_LOG"
            case "$1" in
                --source)
                    shift
                    source_dir=$1
                    printf ' <%s>' "$1" >> "$AG_FAKE_LOG"
                    ;;
                --remote)
                    shift
                    remote_name=$1
                    printf ' <%s>' "$1" >> "$AG_FAKE_LOG"
                    ;;
            esac
            shift
        done
        printf '\n' >> "$AG_FAKE_LOG"
        if [ "${AG_FAKE_CREATE_FAIL:-0}" = "1" ]; then
            exit 1
        fi
        git -C "$source_dir" remote add "$remote_name" "https://github.com/$target.git"
        printf 'https://github.com/%s\n' "$target"
        exit 0
        ;;
esac
printf 'unexpected fake gh invocation: %s\n' "$*" >&2
exit 90
EOF
chmod +x "$FAKE_BIN/gh"
export PATH="$FAKE_BIN:$PATH"
export AG_FAKE_LOG

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILS=$((FAILS + 1)); }

check() {
    if [ "$2" = "$3" ]; then pass "$1 (exit $3)"; else fail "$1 (wanted exit $2, got $3)"; fi
}

contains() {
    case "$2" in
        *"$3"*) pass "$1" ;;
        *) fail "$1 — output missing: $3" ;;
    esac
}

not_contains() {
    case "$2" in
        *"$3"*) fail "$1 — output unexpectedly has: $3" ;;
        *) pass "$1" ;;
    esac
}

new_repo() {
    REPO_N=$((REPO_N + 1))
    REPO="$WORK/repo-$REPO_N"
    mkdir -p "$REPO"
    git -C "$REPO" init -q
    git -C "$REPO" config user.email test@example.com
    git -C "$REPO" config user.name 'agent-github tests'
    printf 'hello\n' > "$REPO/README.md"
    git -C "$REPO" add README.md
    git -C "$REPO" commit -qm 'Initial commit'
}

run_publish() {
    OUT=$(cd "$REPO" && "$AG" publish --repo test-user/safe-project --public \
        --description 'A carefully published test project' "$@" 2>&1)
    RC=$?
}

# -------------------------------------------------------------- owners
OUT=$("$AG" owners 2>&1); RC=$?
check "owners succeeds" 0 "$RC"
contains "owners shows authenticated login" "$OUT" "test-user"
contains "owners shows first organisation" "$OUT" "test-org"
contains "owners shows second organisation" "$OUT" "another-org"
not_contains "owners does not expose profile fields" "$OUT" "email"

# -------------------------------------------------------------- preview
new_repo
: > "$AG_FAKE_LOG"
run_publish
check "publish previews" 0 "$RC"
contains "preview says nothing published" "$OUT" "nothing published yet"
contains "preview shows exact target" "$OUT" "https://github.com/test-user/safe-project"
contains "preview shows authenticated account" "$OUT" "authenticated account:"
contains "preview makes public visibility loud" "$OUT" "PUBLIC — visible to everyone"
contains "preview shows branch and commit" "$OUT" "branch and commit"
contains "preview shows history size" "$OUT" "1 commit(s), 1 tracked file(s)"
TOKEN=$(printf '%s\n' "$OUT" | sed -n 's/.*--yes \([0-9a-f]\{8\}\)$/\1/p')
if [ -n "$TOKEN" ]; then pass "preview prints a token ($TOKEN)"; else fail "preview did not print a token"; fi
if [ ! -s "$AG_FAKE_LOG" ]; then pass "preview did not create a GitHub repository"; else fail "preview called gh repo create"; fi
if [ -z "$(git -C "$REPO" remote)" ]; then pass "preview did not add a remote"; else fail "preview added a remote"; fi

# ---------------------------------------------------------- confirmation
run_publish --yes deadbeef
check "wrong token is refused" 2 "$RC"
contains "wrong token explains mismatch" "$OUT" "token mismatch"
if [ ! -s "$AG_FAKE_LOG" ]; then pass "wrong token did not create a repository"; else fail "wrong token called gh repo create"; fi

OUT=$(cd "$REPO" && "$AG" publish --repo test-user/safe-project --private \
    --description 'A carefully published test project' --yes "$TOKEN" 2>&1); RC=$?
check "token is bound to visibility" 2 "$RC"

OUT=$(cd "$REPO" && "$AG" publish --repo test-user/safe-project --public \
    --description 'A changed description' --yes "$TOKEN" 2>&1); RC=$?
check "token is bound to description" 2 "$RC"

printf 'second\n' > "$REPO/SECOND.md"
git -C "$REPO" add SECOND.md
git -C "$REPO" commit -qm 'Add second file'
run_publish --yes "$TOKEN"
check "token is bound to HEAD" 2 "$RC"

run_publish
FRESH_TOKEN=$(printf '%s\n' "$OUT" | sed -n 's/.*--yes \([0-9a-f]\{8\}\)$/\1/p')

ORG_OUT=$(cd "$REPO" && "$AG" publish --repo test-org/safe-project --public \
    --description 'A carefully published test project' 2>&1)
ORG_TOKEN=$(printf '%s\n' "$ORG_OUT" | sed -n 's/.*--yes \([0-9a-f]\{8\}\)$/\1/p')
OUT=$(cd "$REPO" && AG_FAKE_USER=other-user "$AG" publish --repo test-org/safe-project --public \
    --description 'A carefully published test project' --yes "$ORG_TOKEN" 2>&1); RC=$?
check "token is bound to authenticated account" 2 "$RC"

run_publish --yes "$FRESH_TOKEN"
check "fresh token publishes" 0 "$RC"
contains "publish reports repository URL" "$OUT" "https://github.com/test-user/safe-project"
contains "gh receives exact target" "$(cat "$AG_FAKE_LOG")" "test-user/safe-project"
contains "gh receives public visibility" "$(cat "$AG_FAKE_LOG")" "<--public>"
contains "gh receives description" "$(cat "$AG_FAKE_LOG")" "<--description> <A carefully published test project>"
contains "gh receives fixed origin name" "$(cat "$AG_FAKE_LOG")" "<--remote> <origin>"
contains "gh receives push flag" "$(cat "$AG_FAKE_LOG")" "<--push>"
if [ "$(git -C "$REPO" remote)" = "origin" ]; then pass "successful publish adds only origin"; else fail "successful publish remote is wrong"; fi

# ------------------------------------------------------------- refusals
new_repo
printf 'dirty\n' >> "$REPO/README.md"
run_publish
check "refuses a dirty tracked file" 1 "$RC"
contains "dirty refusal is actionable" "$OUT" "working tree is not clean"

new_repo
printf 'untracked\n' > "$REPO/notes.tmp"
run_publish
check "refuses an untracked file" 1 "$RC"

new_repo
git -C "$REPO" remote add upstream https://github.com/example/existing.git
run_publish
check "refuses any existing remote" 1 "$RC"
contains "remote refusal explains new-only scope" "$OUT" "new remote repository"

new_repo
git -C "$REPO" checkout -q --detach
run_publish
check "refuses detached HEAD" 1 "$RC"

REPO="$WORK/no-commits"
mkdir -p "$REPO"
git -C "$REPO" init -q
run_publish
check "refuses repository with no commits" 1 "$RC"

new_repo
OUT=$(cd "$REPO" && "$AG" publish --repo stranger/project --public --description 'Safe description' 2>&1); RC=$?
check "refuses unknown owner" 1 "$RC"
contains "unknown owner refusal explains allowed scope" "$OUT" "authenticated account or an available organisation"

OUT=$(cd "$REPO" && AG_FAKE_EXISTING=1 "$AG" publish --repo test-org/existing --private --description 'Safe description' 2>&1); RC=$?
check "refuses an existing GitHub repository" 1 "$RC"

OUT=$(cd "$REPO" && "$AG" publish --repo test-user/bad/name --public --description 'Safe description' 2>&1); RC=$?
check "refuses target with extra path component" 1 "$RC"

OUT=$(cd "$REPO" && "$AG" publish --repo 'test-user/bad name' --public --description 'Safe description' 2>&1); RC=$?
check "refuses invalid repository name" 1 "$RC"

OUT=$(cd "$REPO" && "$AG" publish --repo test-user/project --description 'Safe description' 2>&1); RC=$?
check "requires explicit visibility" 1 "$RC"

OUT=$(cd "$REPO" && "$AG" publish --repo test-user/project --public --private --description 'Safe description' 2>&1); RC=$?
check "refuses conflicting visibility" 1 "$RC"

OUT=$(cd "$REPO" && "$AG" publish --repo test-user/project --public --description $'line one\nline two' 2>&1); RC=$?
check "refuses newline in description" 1 "$RC"

LONG_DESC=$(printf '%0100d' 0)
OUT=$(cd "$REPO" && "$AG" publish --repo test-user/project --public --description "$LONG_DESC" 2>&1); RC=$?
check "enforces short description" 1 "$RC"

OUT=$(cd "$REPO" && "$AG" publish --repo test-user/project --public --description 'Safe description' --delete 2>&1); RC=$?
check "refuses arbitrary gh-like options" 1 "$RC"

# ------------------------------------------------------ partial failure
new_repo
run_publish
FAIL_TOKEN=$(printf '%s\n' "$OUT" | sed -n 's/.*--yes \([0-9a-f]\{8\}\)$/\1/p')
OUT=$(cd "$REPO" && AG_FAKE_CREATE_FAIL=1 "$AG" publish --repo test-user/safe-project --public \
    --description 'A carefully published test project' --yes "$FAIL_TOKEN" 2>&1); RC=$?
check "reports create/push failure" 1 "$RC"
contains "failure warns about partial creation" "$OUT" "may now exist"

echo
if [ $FAILS -eq 0 ]; then
    echo "ALL TESTS PASSED"
else
    echo "$FAILS TEST(S) FAILED"
    exit 1
fi
