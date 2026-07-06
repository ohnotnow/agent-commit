#!/bin/bash
# Test battery for agent-commit. Tests the agent-commit script sitting
# NEXT TO this file (the repo copy, not the installed one), inside a
# throwaway git repo created under mktemp and removed on exit. Prints
# PASS/FAIL per case, non-zero exit if anything failed. Uses git
# add/commit ONLY inside the throwaway repo.
#
# History: written alongside the original tool (July 2026, quality-gate
# session). Extended in the follow-up review with regressions for the
# rename both-sides rule, the full multi-line-message preview, and
# committing paths that no longer exist on disk.

HERE=$(cd "$(dirname "$0")" && pwd)
AC="$HERE/agent-commit"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/agent-commit-tests.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
FAILS=0

[ -x "$AC" ] || { echo "no executable agent-commit next to this script"; exit 1; }

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAILS=$((FAILS + 1)); }

check() { # check <desc> <expected-exit> <actual-exit>
    if [ "$2" = "$3" ]; then pass "$1 (exit $3)"; else fail "$1 (wanted exit $2, got $3)"; fi
}

contains() { # contains <desc> <haystack> <needle>
    case "$2" in
        *"$3"*) pass "$1" ;;
        *)      fail "$1 — output missing: $3" ;;
    esac
}

not_contains() {
    case "$2" in
        *"$3"*) fail "$1 — output unexpectedly has: $3" ;;
        *)      pass "$1" ;;
    esac
}

# ------------------------------------------------------------------ setup
mkdir -p "$REPO"
cd "$REPO" || exit 1
git init -q .
git config user.email test@example.com
git config user.name "agent-commit tests"
printf 'one\n' > a.txt
printf 'three\n' > c.txt
printf 'other\n' > other.txt
printf 'spaced\n' > 'spaced name.txt'
git add .
git commit -qm 'base'

printf 'one CHANGED\n' > a.txt                  # modified, named
printf 'brand new\n' > b.txt                    # untracked, named
rm c.txt                                        # deleted, named
printf 'spaced CHANGED\n' > 'spaced name.txt'   # modified, named
printf 'temporary junk\n' > stray.tmp           # untracked, NOT named
printf 'other CHANGED\n' > other.txt
git add other.txt                               # pre-staged, NOT named
mkdir subdir && printf 'x\n' > subdir/inner.txt # directory-refusal fodder
echo "--- setup complete ---"

MSG='fix(test): exercise agent-commit end to end'
NAMED=(a.txt b.txt c.txt 'spaced name.txt')

# ---------------------------------------------------------------- preview
BEFORE=$(git rev-parse HEAD)
OUT=$("$AC" -m "$MSG" "${NAMED[@]}" 2>&1); RC=$?
check    "preview exits 0" 0 "$RC"
contains "preview says nothing committed" "$OUT" "nothing committed yet"
contains "preview lists modified a.txt" "$OUT" "modified  a.txt"
contains "preview lists new b.txt" "$OUT" "new       b.txt"
contains "preview lists deleted c.txt" "$OUT" "deleted   c.txt"
contains "preview lists spaced file" "$OUT" "spaced name.txt"
contains "preview shows leftovers stray.tmp" "$OUT" "stray.tmp"
contains "preview shows leftovers other.txt" "$OUT" "other.txt"
TOKEN=$(printf '%s\n' "$OUT" | sed -n 's/.*--yes \([0-9a-f]\{8\}\)$/\1/p')
if [ -n "$TOKEN" ]; then pass "preview printed a token ($TOKEN)"; else fail "no token found in preview"; fi
AFTER=$(git rev-parse HEAD)
if [ "$BEFORE" = "$AFTER" ]; then pass "preview made no commit"; else fail "preview COMMITTED SOMETHING"; fi

# ------------------------------------------------------------ wrong token
OUT=$("$AC" -m "$MSG" --yes deadbeef "${NAMED[@]}" 2>&1); RC=$?
check    "wrong token refused" 2 "$RC"
contains "wrong token message" "$OUT" "token mismatch"
[ "$(git rev-parse HEAD)" = "$BEFORE" ] && pass "wrong token: no commit" || fail "wrong token: COMMITTED"

# ------------------------------------------------------------------ drift
printf 'one CHANGED AGAIN\n' > a.txt
OUT=$("$AC" -m "$MSG" --yes "$TOKEN" "${NAMED[@]}" 2>&1); RC=$?
check    "stale token after drift refused" 2 "$RC"
[ "$(git rev-parse HEAD)" = "$BEFORE" ] && pass "drift: no commit" || fail "drift: COMMITTED"
OUT=$("$AC" -m "$MSG" "${NAMED[@]}" 2>&1)
TOKEN2=$(printf '%s\n' "$OUT" | sed -n 's/.*--yes \([0-9a-f]\{8\}\)$/\1/p')
if [ -n "$TOKEN2" ] && [ "$TOKEN2" != "$TOKEN" ]; then
    pass "token changed after drift ($TOKEN -> $TOKEN2)"
else
    fail "token did not change after drift"
fi

# ---------------------------------------------------------- happy confirm
OUT=$("$AC" -m "$MSG" --yes "$TOKEN2" "${NAMED[@]}" 2>&1); RC=$?
check    "confirm with fresh token commits" 0 "$RC"
contains "confirm reports commit" "$OUT" "committed 4 file(s)"
COMMITTED=$(git show --name-status --format= HEAD | sort)
EXPECTED=$(printf 'A\tb.txt\nD\tc.txt\nM\ta.txt\nM\tspaced name.txt\n' | sort)
if [ "$COMMITTED" = "$EXPECTED" ]; then
    pass "commit contains exactly the 4 named files"
else
    fail "commit contents wrong: $(printf '%s' "$COMMITTED" | tr '\n' '|')"
fi
SUBJECT=$(git log -1 --format=%s)
[ "$SUBJECT" = "$MSG" ] && pass "commit message correct" || fail "commit message wrong: $SUBJECT"
STATUS=$(git status --porcelain)
contains "other.txt still staged, untouched" "$STATUS" "M  other.txt"
contains "stray.tmp still untracked" "$STATUS" "?? stray.tmp"

# -------------------------------------------------------------- refusals
BEFORE=$(git rev-parse HEAD)
r() { # r <desc> <expected-exit> <args...>
    local desc="$1" want="$2"; shift 2
    OUT=$("$AC" "$@" 2>&1); RC=$?
    check "$desc" "$want" "$RC"
    [ "$(git rev-parse HEAD)" = "$BEFORE" ] || fail "$desc: COMMITTED SOMETHING"
}
printf 'again\n' > a.txt   # make a.txt dirty again so only the bad bit fails
r "refuses '.'"                    1 -m 'fix: x' .
r "refuses -A"                     1 -m 'fix: x' -A
r "refuses --all"                  1 -m 'fix: x' --all
r "refuses a directory"            1 -m 'fix: x' subdir
r "refuses trailing-slash dir"     1 -m 'fix: x' subdir/
r "refuses non-conventional msg"   1 -m 'updated some stuff' a.txt
r "refuses missing -m"             1 a.txt
r "refuses empty file list"        1 -m 'fix: x'
r "refuses ../ path"               1 -m 'fix: x' ../escape.txt
r "refuses absolute path"          1 -m 'fix: x' /etc/hosts
r "refuses nonexistent path"       1 -m 'fix: x' no-such-file.txt
r "refuses unchanged tracked file" 1 -m 'fix: x' 'spaced name.txt'
r "refuses dash path after --"     1 -m 'fix: x' -- -rf

# conventional-commit variants that SHOULD pass the message gate
OUT=$("$AC" -m 'feat!: breaking thing' a.txt 2>&1); RC=$?
check "accepts 'feat!:' (preview)" 0 "$RC"
OUT=$("$AC" -m 'chore(deps): bump' a.txt 2>&1); RC=$?
check "accepts 'chore(scope):' (preview)" 0 "$RC"

# ---------------------------------------------------------------- renames
# A staged rename must be committed whole: naming one side used to
# half-commit it, leaving the old path alive in HEAD with no warning.
printf 'rename me\n' > ren-old.txt
git add ren-old.txt
git commit -qm 'base for rename tests'
git mv ren-old.txt ren-new.txt
BEFORE=$(git rev-parse HEAD)

r "rename: refuses naming only the new side" 1 -m 'fix: half a rename' ren-new.txt
contains "rename refusal explains itself" "$OUT" "name both paths"
r "rename: refuses naming only the old side" 1 -m 'fix: half a rename' ren-old.txt

OUT=$("$AC" -m 'fix: unrelated while rename staged' a.txt 2>&1); RC=$?
check    "unrelated preview works with rename staged" 0 "$RC"
contains "rename listed in leftovers" "$OUT" "ren-old.txt -> ren-new.txt"

OUT=$("$AC" -m 'refactor: rename ren-old to ren-new' ren-old.txt ren-new.txt 2>&1); RC=$?
check "rename: both sides named previews" 0 "$RC"
RTOKEN=$(printf '%s\n' "$OUT" | sed -n 's/.*--yes \([0-9a-f]\{8\}\)$/\1/p')
OUT=$("$AC" -m 'refactor: rename ren-old to ren-new' --yes "$RTOKEN" ren-old.txt ren-new.txt 2>&1); RC=$?
check    "rename: both sides named commits" 0 "$RC"
contains "rename commit reports both files" "$OUT" "committed 2 file(s)"
TREE=$(git ls-tree -r --name-only HEAD)
contains     "rename: new path in HEAD" "$TREE" "ren-new.txt"
not_contains "rename: old path gone from HEAD" "$TREE" "ren-old.txt"
not_contains "rename: nothing of it left in status" "$(git status --porcelain)" "ren-"

# ------------------------------------------------------ multi-line message
# The preview must show the WHOLE message, not just the first line, and
# the commit must carry the body through intact.
MLMSG='feat(preview): summary line

body line one
body line two'
printf 'multi\n' > ml.txt
OUT=$("$AC" -m "$MLMSG" ml.txt 2>&1); RC=$?
check    "multi-line message previews" 0 "$RC"
contains "preview shows body line one" "$OUT" "body line one"
contains "preview shows body line two" "$OUT" "body line two"
MTOKEN=$(printf '%s\n' "$OUT" | sed -n 's/.*--yes \([0-9a-f]\{8\}\)$/\1/p')
OUT=$("$AC" -m "$MLMSG" --yes "$MTOKEN" ml.txt 2>&1); RC=$?
check "multi-line message commits" 0 "$RC"
BODY=$(git log -1 --format=%B)
[ "$BODY" = "$MLMSG" ] && pass "full message committed intact" || fail "message mangled: $BODY"

# ------------------------------------------------------- message from file
# -m @path reads the message from a file (curl-style), dodging the
# shell-escaping dance for multi-line messages. The token digests the
# message text itself, so editing the file between preview and confirm
# must be refused as drift.
FMSG='feat(msgfile): summary from a file

body with $dollar and `backticks` kept literal
second body line'
MSGFILE="$WORK/commit-msg.txt"
printf '%s\n' "$FMSG" > "$MSGFILE"
printf 'from file\n' > mf.txt
BEFORE=$(git rev-parse HEAD)
OUT=$("$AC" -m "@$MSGFILE" mf.txt 2>&1); RC=$?
check    "message-from-file previews" 0 "$RC"
contains "preview shows body from file" "$OUT" 'body with $dollar'
FTOKEN=$(printf '%s\n' "$OUT" | sed -n 's/.*--yes \([0-9a-f]\{8\}\)$/\1/p')

printf '%s\n' "$FMSG" 'sneaky extra line' > "$MSGFILE"
OUT=$("$AC" -m "@$MSGFILE" --yes "$FTOKEN" mf.txt 2>&1); RC=$?
check "edited message file refused as drift" 2 "$RC"
[ "$(git rev-parse HEAD)" = "$BEFORE" ] && pass "message drift: no commit" || fail "message drift: COMMITTED"

printf '%s\n' "$FMSG" > "$MSGFILE"
OUT=$("$AC" -m "@$MSGFILE" --yes "$FTOKEN" mf.txt 2>&1); RC=$?
check "message-from-file commits once restored" 0 "$RC"
BODY=$(git log -1 --format=%B)
[ "$BODY" = "$FMSG" ] && pass "file message committed intact" || fail "file message mangled: $BODY"

BEFORE=$(git rev-parse HEAD)
printf 'again\n' >> mf.txt   # dirty file so only the message part can fail
r "refuses missing message file" 1 -m "@$WORK/no-such-msg.txt" mf.txt
: > "$WORK/empty-msg.txt"
r "refuses empty message file"   1 -m "@$WORK/empty-msg.txt" mf.txt
printf 'updated some stuff\n' > "$WORK/plain-msg.txt"
r "file message still needs conventional first line" 1 -m "@$WORK/plain-msg.txt" mf.txt

# --------------------------------------------------------- SAFETY_MODE off
YOLO="$WORK/agent-commit-yolo"
sed 's/^SAFETY_MODE="on"/SAFETY_MODE="off"/' "$AC" > "$YOLO" && chmod +x "$YOLO"
OUT=$("$YOLO" -m 'fix: safety off commits straight away' a.txt 2>&1); RC=$?
check    "SAFETY_MODE=off commits immediately" 0 "$RC"
contains "SAFETY_MODE=off announces itself" "$OUT" "SAFETY_MODE is off"
NEWSUBJ=$(git log -1 --format=%s)
[ "$NEWSUBJ" = "fix: safety off commits straight away" ] && pass "safety-off commit landed" || fail "safety-off commit missing"

# ------------------------------------------------------------------ result
echo
if [ $FAILS -eq 0 ]; then
    echo "ALL TESTS PASSED"
else
    echo "$FAILS TEST(S) FAILED"
    exit 1
fi
