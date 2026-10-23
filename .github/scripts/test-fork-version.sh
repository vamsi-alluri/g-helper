#!/usr/bin/env bash
# Tests for fork-version.sh.
#
# The script decides whether upstream has published a new *stable* release
# and, if so, what version the fork should publish. Both of its inputs are
# injected here (UPSTREAM_STABLE, FORK_LATEST, FORK_TAGS) so the decision
# logic is tested without reaching the network; in the workflow those come
# from `gh` and `git ls-remote`.
#
# Note on the failure cases: asserting only "exits non-zero" is not enough,
# because a missing script also exits non-zero. Each failure case asserts the
# specific diagnostic, so the test can tell "script refused correctly" from
# "script is not there".
set -u

SCRIPT="$(cd "$(dirname "$0")" && pwd)/fork-version.sh"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name — expected '$expected', got '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

check_contains() {
  local name="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*)
      echo "PASS: $name"
      PASS=$((PASS + 1))
      ;;
    *)
      echo "FAIL: $name — expected stderr containing '$needle', got '$haystack'"
      FAIL=$((FAIL + 1))
      ;;
  esac
}

# run <upstream> <fork_latest> <tags>  -> stdout
run() { UPSTREAM_STABLE="$1" FORK_LATEST="$2" FORK_TAGS="$3" bash "$SCRIPT" 2>/dev/null; }
# err <upstream> <fork_latest> <tags>  -> stderr
err() { UPSTREAM_STABLE="$1" FORK_LATEST="$2" FORK_TAGS="$3" bash "$SCRIPT" 2>&1 >/dev/null; }
# rc <upstream> <fork_latest> <tags>   -> "nonzero" | "zero"
rc() {
  local r=0
  UPSTREAM_STABLE="$1" FORK_LATEST="$2" FORK_TAGS="$3" bash "$SCRIPT" >/dev/null 2>&1 || r=$?
  if [ "$r" -ne 0 ]; then echo nonzero; else echo zero; fi
}
# code <upstream> <fork_latest> <tags> -> the exact exit status
code() {
  local r=0
  UPSTREAM_STABLE="$1" FORK_LATEST="$2" FORK_TAGS="$3" bash "$SCRIPT" >/dev/null 2>&1 || r=$?
  echo "$r"
}

# 1. The whole point of the change: a newer upstream stable release releases,
#    and the patch restarts at 1 instead of continuing a global commit count.
check "new upstream stable starts at .1"      "0.290.1" "$(run v0.290 v0.289.31 '')"
check "patch resets across an upstream bump"  "0.291.1" "$(run v0.291 v0.290.7  '')"

# 2. The case that stops the daily release: upstream has published nothing
#    newer than what the fork already shipped.
check "same upstream version does not release" "nonzero" "$(rc  v0.289 v0.289.31 '')"
check "same upstream version prints nothing"   ""        "$(run v0.289 v0.289.31 '')"
check_contains "same upstream version explains why" \
  "no new upstream stable release" "$(err v0.289 v0.289.31 '')"

# 3. Today's real state, pinned: upstream stable is 0.288 while the fork has
#    already shipped 0.289.31 off upstream's prerelease line. Must refuse
#    rather than emit 0.288.x, which would lose to the installed build and
#    silently stop every client from updating again.
check "older upstream stable does not release" "nonzero" "$(rc  v0.288 v0.289.31 '')"
check_contains "older upstream stable explains why" \
  "no new upstream stable release" "$(err v0.288 v0.289.31 '')"

# 4. A fork with no releases yet must still start at .1, not .0.
check "no fork releases yet" "0.288.1" "$(run v0.288 '' '')"

# 5. Recovery. A previous run pushed the tag but the release never published,
#    so the fork's releases/latest still reads the old version. The existing
#    tag must be reused, not skipped past — skipping leaves an orphan tag and
#    a permanent gap in the version line.
check "reuses an unreleased tag" "0.290.1" \
  "$(run v0.290 v0.289.31 'refs/tags/v0.290.1')"
check "reuses the highest unreleased tag" "0.290.2" \
  "$(run v0.290 v0.289.31 'refs/tags/v0.290.1
refs/tags/v0.290.2')"
# Lexical max would pick v0.290.9 over v0.290.10 and reuse a live tag.
check "tag scan compares numerically, not lexically" "0.290.10" \
  "$(run v0.290 v0.289.31 'refs/tags/v0.290.9
refs/tags/v0.290.10')"
# Inherited upstream tags share the namespace; only <upstream>.<patch> counts.
check "ignores tags for other upstream versions" "0.290.1" \
  "$(run v0.290 v0.289.31 'refs/tags/v0.289.31
refs/tags/v0.9.1
refs/tags/v0.290')"

# 6. A `v` prefix must be tolerated on either input, since `gh` returns tag
#    names while a hand-run may pass a bare version.
check "accepts a bare upstream version" "0.290.1" "$(run 0.290  0.289.31 '')"
check "accepts a bare fork version"     "0.290.1" "$(run v0.290 0.289.31 '')"

# 7. The version the fork publishes must have exactly four components once
#    .NET parses it, so upstream must contribute exactly two. Upstream has
#    tagged v0.9.9.0 and v.0.10.0 in the past; either would otherwise produce
#    an unparseable version that fails deep inside the release build.
check "four-component upstream refused" "nonzero" "$(rc v0.9.9.0 v0.289.31 '')"
check_contains "four-component upstream explains why" \
  "two components" "$(err v0.9.9.0 v0.289.31 '')"
check "malformed upstream tag refused" "nonzero" "$(rc v.0.10.0 v0.289.31 '')"
check_contains "malformed upstream tag explains why" \
  "not a version" "$(err v.0.10.0 v0.289.31 '')"
check "empty upstream version refused" "nonzero" "$(rc '' v0.289.31 '')"
check_contains "empty upstream version explains why" \
  "no stable release" "$(err '' v0.289.31 '')"

# 8. A fork release that is not <maj>.<min>.<patch> means releases/latest
#    picked up something this scheme did not publish. Guessing a patch from it
#    could re-emit a version that is already live, so refuse.
check "unparseable fork release refused" "nonzero" "$(rc v0.290 not-a-version '')"
check_contains "unparseable fork release explains why" \
  "not a fork version" "$(err v0.290 not-a-version '')"

# 9. The invariant the whole update mechanism rests on: the patch is never 0.
#    <AssemblyVersion>0.288</AssemblyVersion> reports as 0.288.0.0 at runtime,
#    so 0.288.0 would compare *lower* than an installed build.
check_patch_nonzero() {
  local v
  v="$(run "$1" "$2" '')"
  case "$v" in
    ""|*.0) check "patch is never zero ($1 over ${2:-nothing})" "nonzero-patch" "got '$v'" ;;
    *)      check "patch is never zero ($1 over ${2:-nothing})" "nonzero-patch" "nonzero-patch" ;;
  esac
}
check_patch_nonzero v0.288 ''
check_patch_nonzero v0.290 v0.289.31
check_patch_nonzero v0.291 v0.290.7

# 9b. The exit-code split. The caller lets 3 pass as a quiet day and keeps
#     everything else red, so a fault that reports as 3 would stop the fork
#     releasing behind a wall of green runs. Pinned per cause, because this
#     is the one distinction the whole no-silent-failure design rests on.
check "quiet day exits 3 (upstream not newer)" "3" "$(code v0.288  v0.289.31 '')"
check "quiet day exits 3 (upstream equal)"     "3" "$(code v0.289  v0.289.31 '')"
check "bad upstream tag exits 1, not 3"        "1" "$(code v.0.10.0 v0.289.31 '')"
check "overlong upstream tag exits 1, not 3"   "1" "$(code v0.9.9.0 v0.289.31 '')"
check "missing upstream release exits 1, not 3" "1" "$(code ''      v0.289.31 '')"
check "bad fork release exits 1, not 3"        "1" "$(code v0.290 not-a-version '')"

# 10. The ordering the whole version scheme rests on. Pinned here because the
#     comparison is between the tag string and the four-component version the
#     assembly actually reports: <AssemblyVersion>0.288</AssemblyVersion>
#     reports as 0.288.0.0, so a fork's 0.288.N must beat that and lose to a
#     later 0.289.0.0. A `Build` of -1 is a property of a parsed string only
#     and is NOT what the updater compares against.
if command -v pwsh >/dev/null 2>&1; then
  ord="$(pwsh -NoProfile -Command '
    $r = @()
    if (([version]"0.288.9").CompareTo([version]"0.288.0.0") -ne  1) { $r += "fork build must beat installed 0.288.0.0" }
    if (([version]"0.288.9").CompareTo([version]"0.289.0.0") -ne -1) { $r += "upstream bump must beat fork build" }
    if (([version]"0.288.0").CompareTo([version]"0.288.0.0") -ne -1) { $r += "0.288.0 must be lower than 0.288.0.0" }
    if (([version]"0.288.9").CompareTo([version]"0.288.9.0") -ne -1) { $r += "a fork build must not re-offer itself" }
    # New under the stable-only scheme: the patch restarts at 1 on every
    # upstream bump, so a fresh 0.290.1 must still beat a long-running
    # 0.289.31 that accumulated under the old commit-counting scheme.
    if (([version]"0.290.1").CompareTo([version]"0.289.31.0") -ne 1) { $r += "reset patch must beat the old high patch" }
    if ($r.Count -eq 0) { "ok" } else { $r -join "; " }' 2>/dev/null)"
  check "System.Version ordering holds" "ok" "$ord"
else
  echo "SKIP: System.Version ordering (pwsh not available)"
fi

echo "---"
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
