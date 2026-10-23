#!/usr/bin/env bash
# Invariant checks for the fork release pipeline's workflows.
#
# These are static assertions, not a live run: each one pins a property whose
# absence has already cost a wedged pipeline or a silent failure. They exist
# because YAML that parses is not YAML that works — actionlint passes on every
# bug these catch.
set -u

SYNC=".github/workflows/sync-upstream.yml"
REL=".github/workflows/release-fork.yml"
PASS=0
FAIL=0

ok()   { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad()  { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

has() { # name, file, regex
  if grep -qE "$3" "$2"; then ok "$1"; else bad "$1" "no match for /$3/ in $2"; fi
}

# 1. The release gate must verify the managed AssemblyVersion, which is what
#    AutoUpdateControl compares. Verifying only the Win32 FileVersion lets a
#    build ship whose assembly version never moved, producing an update that
#    is offered, downloads, and changes nothing — forever.
# Matched on a non-comment line only: GetAssemblyName currently appears in a
# comment explaining why it fails on the apphost, which would pass vacuously.
if grep -E 'GetAssemblyName' "$REL" | grep -qvE '^\s*#'; then
  ok "release verifies managed AssemblyVersion from GHelper.dll"
else
  bad "release verifies managed AssemblyVersion from GHelper.dll" "GetAssemblyName appears only in comments"
fi
has "release reads the managed dll, not just the apphost" "$REL" \
  'win-x64/GHelper\.dll'

# 2. The shallow guard must sit in front of the behind-count, not only inside
#    fork-version.sh. A shallow checkout makes the count read 0, which exits
#    green, skips everything, and never releases again.
has "sync asserts a full checkout before counting commits" "$SYNC" \
  'is-shallow-repository'

# 3. main must be pushed before the tag is derived and pushed, so the tag can
#    only ever name a commit that is already on the remote. A tag pointing at
#    an unpushed commit publishes a release nobody can check out.
if awk '!p && /git push origin HEAD:main/ {p=NR} p && !d && /fork-version\.sh/ {d=NR} END {exit !(p && d && p < d)}' "$SYNC"; then
  ok "main is pushed before the tag is derived"
else
  bad "main is pushed before the tag is derived" "fork-version.sh appears at or before the main push"
fi

# 3b. Pushing main must NOT depend on a release being due. The whole point of
#     the stable-only scheme is that main keeps absorbing upstream daily while
#     the binary waits; gating the push on the release decision would freeze
#     the fork between upstream releases.
if awk '/^    - name: Push main$/ {p=1} p && /fork-version\.sh/ {exit 1} p && /^    - name: / && !/Push main$/ {exit 0}' "$SYNC"; then
  ok "pushing main does not depend on the release decision"
else
  bad "pushing main does not depend on the release decision" "the push step consults fork-version.sh"
fi

# 3c. The release decision must run on days with no new upstream commits.
#     Those days are precisely when upstream promoting a prerelease to stable
#     gets noticed, and when an unpublished tag gets retried. An `== success`
#     gate here would skip it, because merge and build are *skipped* (not
#     successful) when behind=0 -- the bug that would quietly restore
#     "releases only when upstream commits", which is what this change undoes.
if awk '/id: decide/ {d=1} d && /^      if:/ {print; exit}' "$SYNC" \
   | grep -qE "conflict != 'true'.*build\.outcome != 'failure'"; then
  ok "release decision runs even with no new upstream commits"
else
  bad "release decision runs even with no new upstream commits" \
    "the decide step's if: is not the skip-tolerant != form"
fi

# 4. Overlapping runs both merge the same base and race to push; the loser
#    dies on a rejected push and reports nothing.
has "sync serialises itself with a concurrency group" "$SYNC" \
  '^concurrency:'

# 5. Most of the ways this job can fail skip the conflict/build report step
#    entirely, leaving only a red run nobody is watching.
has "sync reports any other failure to the run summary" "$SYNC" \
  'if: failure\(\)'

# 6. Closing the tracking issue inside the sync job closes it while the
#    release job can still fail.
if grep -qE '^  close-issue:' "$SYNC" && grep -qE 'needs: \[sync, release\]' "$SYNC"; then
  ok "issue close waits on the release job"
else
  bad "issue close waits on the release job" "expected a close-issue job with needs: [sync, release]"
fi
if awk '/^  sync:/{s=1} /^  [a-z-]+:$/ && !/^  sync:/{s=0} s && /gh issue close/{found=1} END{exit found}' "$SYNC"; then
  ok "sync job no longer closes the issue itself"
else
  bad "sync job no longer closes the issue itself" "gh issue close still inside the sync job"
fi

# 7. The gate must build what the release actually publishes. A Debug,
#    RID-less `dotnet build` can pass while the Release single-file publish
#    fails, which wedges the pipeline after main and the tag are pushed.
has "build gate matches the release publish configuration" "$SYNC" \
  'dotnet publish app/GHelper\.sln --configuration Release --runtime win-x64 -p:PublishSingleFile=true'
if grep -qE 'run: dotnet build app/GHelper\.sln\s*$' "$SYNC"; then
  bad "build gate is not a bare Debug dotnet build" "gate still runs 'dotnet build app/GHelper.sln'"
else
  ok "build gate is not a bare Debug dotnet build"
fi

# 8. Recovery: if a previous run pushed a tag but the release never
#    published, a later run must reuse that tag. Stepping past it to the next
#    patch orphans the tag and leaves a permanent gap in the version line;
#    skipping the version entirely wedges the pipeline and installed clients
#    never update again.
has "sync reuses a tag that has no release" "$SYNC" \
  'tag v\$version already exists with no release; reusing it'
if awk '/id: decide/ {d=1} d && /released=false/ {f=1} d && /git tag/ {t=1} END {exit !(f && t)}' "$SYNC"; then
  ok "the decide step both refuses and tags from one place"
else
  bad "the decide step both refuses and tags from one place" \
    "expected the decide step to handle both the no-release and tag paths"
fi

# 8b. A release that fails after the tag was pushed happens inside a called
#     workflow, which the sync job's own failure() step cannot observe.
if grep -qE '^  report-release-failure:' "$SYNC" \
   && grep -qE "needs\.release\.result == 'failure'" "$SYNC"; then
  ok "a failed release is reported"
else
  bad "a failed release is reported" "expected a report-release-failure job keyed on needs.release.result"
fi

# 8c. The trigger must be upstream's stable release, not its newest tag or
#     commit. `gh release view` reads releases/latest, which excludes
#     prereleases; `gh release list` would include them and restore
#     near-daily releasing. Checked in the script, where the lookup lives.
VER=".github/scripts/fork-version.sh"
has "the trigger reads upstream's stable release" "$VER" \
  'gh release view --repo "\$UPSTREAM_REPO"'
if grep -qE 'gh release list' "$VER"; then
  bad "the trigger excludes prereleases" "fork-version.sh uses 'gh release list', which includes prereleases"
else
  ok "the trigger excludes prereleases"
fi
# 8d. The caller must distinguish "no release due" (exit 3) from a real fault,
#     or a broken upstream lookup reports as a quiet day every day and the
#     fork stops releasing with nothing but green runs to show for it.
if awk '/id: decide/ {d=1} d && /rc" -eq 3/ {three=1} d && /rc" -ne 0/ {other=1} END {exit !(three && other)}' "$SYNC"; then
  ok "the decide step separates 'nothing due' from a real failure"
else
  bad "the decide step separates 'nothing due' from a real failure" \
    "expected the decide step to branch on exit 3 and still fail on other codes"
fi
has "fork-version.sh reserves exit 3 for 'nothing due'" "$VER" \
  'exit 3'

# The patch must never be 0: <AssemblyVersion>0.290</AssemblyVersion> reports
# as 0.290.0.0 at runtime, so 0.290.0 loses to an installed build and the
# in-app updater never offers it.
has "the patch floor is 1" "$VER" \
  'if \[ "\$patch" -eq 0 \]; then patch=1; fi'

# 9. Inputs must not be interpolated directly into shell bodies of a
#    token-bearing step; pwsh expands $(...) inside double quotes.
if grep -qE 'gh release create "v\$\{\{ inputs\.version \}\}"' "$REL"; then
  bad "release passes version via env, not inline interpolation" "inputs.version interpolated into the gh release create body"
else
  ok "release passes version via env, not inline interpolation"
fi

echo "---"
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
