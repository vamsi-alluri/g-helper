#!/usr/bin/env bash
# Decides whether the fork should publish a release, and at what version.
#
# Prints <upstream stable version>.<patch>, e.g. 0.290.1, and exits 0 when a
# release is due.
#
# Exit codes are split because the caller must not confuse the two:
#   0  a release is due; the version is on stdout
#   3  no release is due -- the normal, expected outcome on most days
#   1  something is actually wrong (bad upstream tag, gh failure)
# Collapsing 1 into 3 would report a broken lookup as a quiet day, every day,
# and the fork would silently stop releasing with a green run to show for it.
#
# The fork releases only when upstream publishes a new *stable* release.
# Upstream flags most of its releases as prereleases and promotes only some to
# "Latest", so `releases/latest` (what `gh release view` reads) is the stable
# line. The fork keeps merging upstream/main daily regardless; that merge is
# what moves `main`, and this script is what decides whether a binary ships.
#
# The fork never stores a version of its own: app/GHelper.csproj keeps
# upstream's AssemblyVersion byte-for-byte, so upstream's frequent version
# bumps never conflict. The patch component is derived here instead, and
# restarts at 1 on every upstream version bump.
#
# Inputs come from the environment so the decision is testable offline. Each
# is looked up only when unset -- an empty value is a meaningful answer
# ("nothing released yet"), not a missing one:
#   UPSTREAM_STABLE  upstream's latest stable release tag, e.g. v0.290
#   FORK_LATEST      this fork's latest published release tag, e.g. v0.289.31
#   FORK_TAGS        `git ls-remote --tags` output for this fork
set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-seerge/g-helper}"
FORK_REPO="${FORK_REPO:-${GITHUB_REPOSITORY:-}}"

# `gh release view` with no tag reads releases/latest, which excludes both
# prereleases and drafts. That exclusion is the entire trigger: asking for
# the newest tag instead would fire on upstream's weekly prereleases.
if [ -z "${UPSTREAM_STABLE+set}" ]; then
  UPSTREAM_STABLE="$(gh release view --repo "$UPSTREAM_REPO" \
    --json tagName --jq .tagName 2>/dev/null || true)"
fi

# Read the fork's own releases rather than scanning its tags for the high
# water mark: this repo inherited upstream's tags (v0.9.1, v0.9.9.0, v0.290),
# and a v*.*.* glob over them would eventually pick one of those as "latest".
# A fork with no releases yet is fine and yields an empty string.
if [ -z "${FORK_LATEST+set}" ]; then
  if [ -z "$FORK_REPO" ]; then
    echo "fork-version: set FORK_REPO or GITHUB_REPOSITORY" >&2
    exit 1
  fi
  FORK_LATEST="$(gh release view --repo "$FORK_REPO" \
    --json tagName --jq .tagName 2>/dev/null || true)"
fi

up="${UPSTREAM_STABLE#v}"
fork="${FORK_LATEST#v}"

if [ -z "$up" ]; then
  echo "fork-version: no stable release found for $UPSTREAM_REPO" >&2
  exit 1
fi

# Upstream must contribute exactly two components. The fork appends a third,
# and .NET parses the result as four (0.290.1 -> 0.290.1.0); a three-component
# upstream tag such as v0.9.9.0 would overflow that and fail deep inside the
# release build, after main and the tag had already been pushed.
case "$up" in
  *[!0-9.]*|.*|*.|*..*)
    echo "fork-version: upstream tag '$UPSTREAM_STABLE' is not a version" >&2
    exit 1
    ;;
esac
up_rest="${up#*.}"
if [ "$up_rest" = "$up" ] || [ "${up_rest#*.}" != "$up_rest" ]; then
  echo "fork-version: upstream version '$up' must have exactly two components" >&2
  exit 1
fi
up_major="${up%%.*}"
up_minor="$up_rest"

# The fork's own releases are always <maj>.<min>.<patch>. Anything else means
# releases/latest picked up a release this scheme did not publish, and
# guessing a patch from it risks re-emitting a version that is already live.
fork_major=""
fork_minor=""
if [ -n "$fork" ]; then
  case "$fork" in
    *[!0-9.]*|.*|*.|*..*)
      echo "fork-version: fork release '$FORK_LATEST' is not a fork version" >&2
      exit 1
      ;;
  esac
  fork_major="${fork%%.*}"
  fork_rest="${fork#*.}"
  fork_minor="${fork_rest%%.*}"
  fork_patch="${fork_rest#*.}"
  if [ "$fork_rest" = "$fork" ] || [ "$fork_patch" = "$fork_rest" ] \
     || [ "${fork_patch#*.}" != "$fork_patch" ]; then
    echo "fork-version: fork release '$FORK_LATEST' is not a fork version" >&2
    exit 1
  fi
fi

# Compared numerically, not as strings: 0.9 must lose to 0.290.
if [ -n "$fork_major" ]; then
  if [ "$up_major" -lt "$fork_major" ] \
     || { [ "$up_major" -eq "$fork_major" ] && [ "$up_minor" -le "$fork_minor" ]; }; then
    echo "fork-version: no new upstream stable release ($UPSTREAM_REPO is at $up, fork already shipped $fork)" >&2
    exit 3
  fi
fi

if [ -z "${FORK_TAGS+set}" ]; then
  FORK_TAGS="$(git ls-remote --tags origin "refs/tags/v$up.*" 2>/dev/null || true)"
fi

# A tag for this upstream version that exists while releases/latest is still
# older can only be an earlier run that tagged and then failed to publish --
# a published tag would have become releases/latest and refused above. So
# reuse the highest such tag rather than stepping past it, which would orphan
# it and leave a permanent gap in the version line.
patch=0
while IFS= read -r line; do
  ref="${line##*refs/tags/}"
  case "$ref" in
    "v$up."*)
      n="${ref#v$up.}"
      # Only a bare integer: v0.290.1.2 and v0.290.1^{} are not patches.
      case "$n" in
        ""|*[!0-9]*) continue ;;
      esac
      if [ "$n" -gt "$patch" ]; then patch="$n"; fi
      ;;
  esac
done <<EOF
$FORK_TAGS
EOF

# Never 0. <AssemblyVersion>0.290</AssemblyVersion> reports as 0.290.0.0 at
# runtime, so 0.290.0 would compare *lower* than an installed build and the
# in-app updater would never offer it.
if [ "$patch" -eq 0 ]; then patch=1; fi

echo "$up.$patch"
