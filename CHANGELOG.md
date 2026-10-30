# Changelog

All notable changes to ziggity are recorded here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and ziggity aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

How it works: add a bullet under `## [Unreleased]` as you land a user-facing
change, grouped under `Added`, `Changed`, `Fixed`, `Removed`, `Deprecated`, or
`Security`. When `release.sh` cuts a release it stamps the Unreleased section
with the version and date, so whatever you wrote there becomes the published
GitHub release notes (and the release Atom feed entry). Keep entries short and
written for someone using ziggity, not reading the diff.

Releases before 0.55.0 are listed on the
[GitHub releases page](https://github.com/simoarpe/ziggity/releases).

## [Unreleased]

## [0.55.0] - 2026-10-30

### Added
- AI commit-message generation (`ctrl+g`) now works when rewording, amending, or
  editing a cherry-picked message, not only for a brand-new commit. It reads the
  relevant commit's own diff, so the generated subject and body describe the
  right changes.
- GitHub releases now carry curated notes from this changelog, so the releases
  page and the release Atom feed (`/releases.atom`) describe what changed in each
  version instead of showing only a compare link.
