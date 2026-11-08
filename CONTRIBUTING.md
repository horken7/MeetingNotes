# Contributing

## Pull request titles: Conventional Commits

Pull requests are squash-merged, so the pull request title becomes the commit message on `main`, and the release
version is worked out from those messages. A check (`.github/workflows/pr-title.yml`) makes sure every title follows
[Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/):

```
<type>[optional scope][!]: <description>
```

Types:

| Type | For | Release |
| --- | --- | --- |
| `feat` | a new feature | minor (1.2.0 → 1.3.0) |
| `fix` | a bug fix | patch (1.2.0 → 1.2.1) |
| `perf` | a performance improvement | patch |
| `revert` | reverting an earlier change | patch |
| `docs`, `style`, `refactor`, `test`, `build`, `ci`, `chore` | everything else | none on its own |

Optional scopes: `mac`, `windows`, `android`, `ios`, `website`, `mcp`, `deps`.

A breaking change bumps the major version (1.2.0 → 2.0.0): add `!` after the type or scope, or a
`BREAKING CHANGE:` footer in the commit body.

Examples:

```
feat(android): share the transcript with any app
fix(windows): keep the recording when the microphone disconnects
docs: explain the MCP setup for Claude Desktop
feat(mac)!: drop support for macOS 14
```

## Releases

There is one version for the whole repository, in `version.txt`, with the history in `CHANGELOG.md`. Both are kept by
[release-please](https://github.com/googleapis/release-please) (`.github/workflows/release-please.yml`):

1. Each merge to `main` updates an open release pull request, `chore: release X.Y.Z`, with the next version and the
   changelog so far.
2. Merging that pull request tags `vX.Y.Z` and creates the GitHub Release.
3. The same workflow then builds the Mac DMG, the Windows installer and the Android APK for that tag and attaches them
   to the release.

To pick a version yourself, put `Release-As: X.Y.Z` in the body of a commit on `main` (for a squash merge, in the
merge commit's description). Pushing a `v*` tag by hand still builds and uploads the installers.
