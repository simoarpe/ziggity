#!/usr/bin/env bash
#
# release.sh — cut a Ziggity release.
#
# What it does (in order):
#   1. Bump build.zig.zon from  0.x.0-dev  ->  0.x.0,  commit, push.
#   2. Tag v0.x.0 (annotated) and push the tag.
#         -> pushing the tag triggers the `release.yml` GitHub Action, which
#            cross-compiles every target, publishes the GitHub Release, and
#            bumps the Homebrew tap formula.
#   3. Verify `brew install simoarpe/ziggity/ziggity` (best-effort, and NON-
#      destructive): if ziggity was not already installed via brew (e.g. a local
#      `zig build` dev setup), the formula is uninstalled again afterwards — and
#      the tap removed if the script added it — so your machine is left exactly
#      as it was. Skipped if brew is missing or the repo is still private (the
#      formula's download URLs 404 for anonymous users until it is public).
#   4. Bump build.zig.zon to the next dev cycle  0.(x+1).0-dev,  commit, push.
#
# The version to release is read from build.zig.zon; it MUST currently end in
# "-dev" (e.g. 0.2.0-dev releases 0.2.0 and then opens 0.3.0-dev).
#
# Usage:  ./release.sh [-y] [--no-brew] [--no-test]
#   -y, --yes     don't prompt for confirmation
#   --no-brew     skip the brew install verification (step 3)
#   --no-test     skip the local `zig build test` gate (not recommended)
#   -h, --help    show this help

set -euo pipefail

# ── config ────────────────────────────────────────────────────────────────
REPO="simoarpe/ziggity"
TAP_REPO="simoarpe/homebrew-ziggity"      # the tap's GitHub repo
TAP_NAME="simoarpe/ziggity"               # its brew tap name (homebrew- prefix stripped)
TAP_FORMULA="Formula/ziggity.rb"
BREW_FORMULA="simoarpe/ziggity/ziggity"
MAIN_BRANCH="main"
ZON="build.zig.zon"

# ── options ───────────────────────────────────────────────────────────────
ASSUME_YES=0
DO_BREW=1
DO_TEST=1
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    --no-brew) DO_BREW=0 ;;
    --no-test) DO_TEST=0 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

# ── pretty logging ────────────────────────────────────────────────────────
if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; Z=$'\033[0m'; else B= G= Y= R= C= Z=; fi
step() { echo "${B}${C}==>${Z} ${B}$*${Z}"; }
info() { echo "    $*"; }
ok()   { echo "${G}    ✓ $*${Z}"; }
warn() { echo "${Y}    ! $*${Z}"; }
die()  { echo "${R}error: $*${Z}" >&2; exit 1; }

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  local reply
  read -r -p "${B}$1${Z} [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# ── preflight ─────────────────────────────────────────────────────────────
step "Preflight checks"

command -v git >/dev/null || die "git not found"
command -v gh  >/dev/null || die "gh (GitHub CLI) not found — needed to watch the release"
[ "$DO_TEST" -eq 1 ] && { command -v zig >/dev/null || die "zig not found (or run with --no-test)"; }

# Run from the repo root regardless of where the script was invoked.
cd "$(git rev-parse --show-toplevel)" || die "not inside a git repository"
[ -f "$ZON" ] || die "$ZON not found in repo root"

branch=$(git rev-parse --abbrev-ref HEAD)
[ "$branch" = "$MAIN_BRANCH" ] || die "on branch '$branch', expected '$MAIN_BRANCH'"

[ -z "$(git status --porcelain)" ] || die "working tree is not clean — commit or stash first"

info "fetching origin…"
git fetch --quiet origin "$MAIN_BRANCH" --tags
if [ -n "$(git rev-list "HEAD..origin/$MAIN_BRANCH" 2>/dev/null)" ]; then
  die "local $MAIN_BRANCH is behind origin/$MAIN_BRANCH — pull first"
fi

# Read and validate the current (dev) version.
current=$(sed -nE 's/^[[:space:]]*\.version = "([^"]+)".*/\1/p' "$ZON" | head -n1)
[ -n "$current" ] || die "could not read .version from $ZON"
[[ "$current" == *-dev ]] || die "current version '$current' does not end in -dev; refusing to guess"

release="${current%-dev}"
IFS='.' read -r major minor patch <<<"$release"
[[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ && "$patch" =~ ^[0-9]+$ ]] \
  || die "release version '$release' is not MAJOR.MINOR.PATCH"
next_dev="${major}.$((minor + 1)).0-dev"
tag="v${release}"

# The tag must not already exist locally or on the remote.
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && die "tag $tag already exists locally"
git ls-remote --tags origin "refs/tags/$tag" | grep -q . && die "tag $tag already exists on origin"

ok "current dev version : $current"
ok "release             : $release   (tag $tag)"
ok "next dev version    : $next_dev"

echo
step "Plan"
info "1. $ZON: $current  ->  $release   (commit + push)"
info "2. tag $tag         (push -> triggers release.yml: build, publish, tap bump)"
if [ "$DO_BREW" -eq 1 ]; then
  info "3. wait for the release, then verify: brew install $BREW_FORMULA"
  info "   (non-destructive — uninstalled again if not already brew-managed)"
else
  info "3. (brew verification skipped: --no-brew)"
fi
info "4. $ZON: $release  ->  $next_dev   (commit + push)"
echo
confirm "Proceed with releasing $tag?" || { warn "aborted."; exit 0; }

# ── helper: rewrite the .version line in build.zig.zon ────────────────────
set_version() {
  local newver="$1" tmp
  tmp=$(mktemp)
  sed -E "s/^([[:space:]]*\.version = \")[^\"]*(\".*)$/\1${newver}\2/" "$ZON" >"$tmp"
  mv "$tmp" "$ZON"
  local got
  got=$(sed -nE 's/^[[:space:]]*\.version = "([^"]+)".*/\1/p' "$ZON" | head -n1)
  [ "$got" = "$newver" ] || die "failed to set version to $newver (got '$got')"
}

# ── test gate ─────────────────────────────────────────────────────────────
if [ "$DO_TEST" -eq 1 ]; then
  step "Running test suite (gate)"
  zig build test || die "tests failed — not releasing"
  ok "tests passed"
else
  warn "skipping tests (--no-test)"
fi

# ── step 1: bump to release, commit, push ─────────────────────────────────
step "Bumping $ZON to $release"
set_version "$release"
git add "$ZON"
git commit -q -m "Release $tag"
ok "committed 'Release $tag'"
git push origin "$MAIN_BRANCH"
ok "pushed $MAIN_BRANCH"

# ── step 2: tag and push the tag ──────────────────────────────────────────
step "Tagging $tag"
git tag -a "$tag" -m "Ziggity $release"
git push origin "$tag"
ok "pushed tag $tag — release.yml is now running"

# ── step 3: verify brew install (best-effort, non-destructive) ────────────
# Put the machine back the way we found it. If ziggity was not brew-managed
# before, uninstall the formula we installed; if the script added the tap,
# remove that too. If it was already brew-managed, leave it installed.
brew_restore() {
  local pre_installed="$1" pre_tapped="$2"
  if [ "$pre_installed" -eq 0 ]; then
    if brew uninstall ziggity >/dev/null 2>&1; then
      ok "restored: removed the brew formula (ziggity was not brew-managed before)"
    else
      warn "could not uninstall ziggity — remove it with: brew uninstall ziggity"
    fi
  else
    ok "left ziggity installed (it was brew-managed before)"
  fi
  if [ "$pre_tapped" -eq 0 ]; then
    brew untap "$TAP_NAME" >/dev/null 2>&1 \
      && info "restored: untapped $TAP_NAME (was not tapped before)" || true
  fi
}

verify_brew() {
  command -v brew >/dev/null || { warn "brew not installed — skipping verification"; return 0; }

  local vis
  vis=$(gh repo view "$REPO" --json isPrivate --jq .isPrivate 2>/dev/null || echo "true")
  if [ "$vis" = "true" ]; then
    warn "$REPO is PRIVATE — release assets 404 for anonymous brew; skipping."
    warn "make the repo public, then run: brew install $BREW_FORMULA"
    return 0
  fi

  # Snapshot the current state up front so we can restore it exactly. Note
  # `brew list ziggity` is true ONLY for a brew-managed install — a local dev
  # build on PATH does not count, so that setup is correctly treated as "remove
  # afterwards".
  local pre_installed=0 pre_tapped=0
  brew list ziggity >/dev/null 2>&1 && pre_installed=1
  brew tap 2>/dev/null | grep -qx "$TAP_NAME" && pre_tapped=1
  if [ "$pre_installed" -eq 1 ]; then
    info "ziggity is currently brew-managed — it will be upgraded and kept"
  else
    info "ziggity is not brew-managed — it will be installed, verified, then removed"
  fi

  step "Waiting for the release workflow to finish"
  sleep 8
  local run_id
  run_id=$(gh run list --repo "$REPO" --workflow release.yml --limit 1 \
             --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)
  if [ -n "$run_id" ]; then
    gh run watch "$run_id" --repo "$REPO" --exit-status --interval 15 \
      || warn "release workflow did not report success — check the Actions tab"
  else
    warn "could not find the workflow run; polling for the release instead"
  fi

  info "waiting for release $tag to be published…"
  local i
  for i in $(seq 1 30); do
    gh release view "$tag" --repo "$REPO" >/dev/null 2>&1 && break
    sleep 10
  done
  gh release view "$tag" --repo "$REPO" >/dev/null 2>&1 \
    || { warn "release $tag not visible yet — verify brew manually later"; return 0; }

  info "waiting for the tap formula to reflect $release…"
  for i in $(seq 1 30); do
    local fv
    fv=$(gh api "repos/$TAP_REPO/contents/$TAP_FORMULA" \
           -H "Accept: application/vnd.github.raw" 2>/dev/null \
           | sed -nE 's/^[[:space:]]*version "([^"]+)".*/\1/p' | head -n1 || true)
    [ "$fv" = "$release" ] && break
    sleep 10
  done

  # If the tap already existed, its local clone may be stale — refresh just that
  # tap (avoid `brew update`, which would touch every tap on the machine).
  if [ "$pre_tapped" -eq 1 ]; then
    local taprepo
    taprepo=$(brew --repo "$TAP_NAME" 2>/dev/null || true)
    [ -n "$taprepo" ] && git -C "$taprepo" pull --ff-only --quiet 2>/dev/null || true
  fi

  step "Verifying: brew install $BREW_FORMULA"
  if [ "$pre_installed" -eq 1 ]; then
    brew upgrade "$BREW_FORMULA" 2>/dev/null || brew reinstall "$BREW_FORMULA" \
      || { warn "brew upgrade/reinstall failed"; return 0; }
  else
    brew install "$BREW_FORMULA" \
      || { warn "brew install failed"; brew_restore "$pre_installed" "$pre_tapped"; return 0; }
  fi

  # Check the brew-linked binary explicitly, so a dev build shadowing it on PATH
  # can't give a false positive.
  local bin installed
  bin="$(brew --prefix)/bin/ziggity"
  installed=$("$bin" --version 2>/dev/null || true)
  if printf '%s' "$installed" | grep -q "$release"; then
    ok "brew install verified: '$installed'"
  else
    warn "installed, but '$bin --version' = '${installed:-<none>}' (expected $release)"
  fi

  brew_restore "$pre_installed" "$pre_tapped"
}

if [ "$DO_BREW" -eq 1 ]; then
  # Best-effort: never let a verification hiccup abort the final dev bump.
  verify_brew || warn "brew verification encountered an issue (continuing)"
else
  warn "skipping brew verification (--no-brew)"
fi

# ── step 4: open the next dev cycle ───────────────────────────────────────
step "Bumping $ZON to $next_dev (next dev cycle)"
set_version "$next_dev"
git add "$ZON"
git commit -q -m "Start $next_dev development"
ok "committed 'Start $next_dev development'"
git push origin "$MAIN_BRANCH"
ok "pushed $MAIN_BRANCH"

echo
step "Done"
ok "Released $tag"
info "Release : https://github.com/$REPO/releases/tag/$tag"
info "Actions : https://github.com/$REPO/actions"
info "Now on  : $next_dev"
