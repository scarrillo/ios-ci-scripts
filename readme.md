# iOS CI Scripts

A collection of shell scripts for iOS CI/CD workflows, designed to work with Xcode Cloud and local development environments. Built from learnings gleaned from the developer community and shared back for others to learn from, adapt, and improve upon.

These scripts also served as the inspiration for the [Claude Code Release Plugin](https://github.com/scarrillo/release).

## Table of Contents

- [Scripts](#scripts)
  - [bump-version.sh](#bump-versionsh)
  - [ci_post_clone.sh](#ci_post_clonesh)
  - [ci_pre_xcodebuild.sh](#ci_pre_xcodebuildsh)
  - [ci_post_xcodebuild.sh](#ci_post_xcodebuildsh)
  - [generate_xcconfig.sh](#generate_xcconfigsh)
  - [validate_xcconfig.sh](#validate_xcconfigsh)
  - [swiftlint.sh](#swiftlintsh)
  - [firebase_upload_symbols.sh](#firebase_upload_symbolssh)
  - [testflight_whattotest.sh](#testflight_whattotestsh)
  - [distribute.sh](#distributesh)
- [Claude Code Lint Hooks](#claude-code-lint-hooks)
  - [post-edit-lint.sh](#hookspost-edit-lintsh)
  - [pre-commit-lint.sh](#hookspre-commit-lintsh)
  - [pre-commit.sh](#hookspre-commitsh)
  - [Commit checks](#commit-checks)
  - [Setup](#hook-setup)
  - [Prerequisites](#hook-prerequisites)
  - [Tests](#hook-tests)
  - [Configuration Precedence](#configuration-precedence)
  - [Project-Specific Exclusions](#project-specific-exclusions)
- [Installation](#installation)
  - [Step 1: Add as a Git Submodule](#step-1-add-as-a-git-submodule)
  - [Step 2: Configure Xcode Build Phases (Local Builds)](#step-2-configure-xcode-build-phases-local-builds)
  - [Step 3: Xcode Cloud (Release Builds)](#step-3-xcode-cloud-release-builds)
- [Updating the Submodule](#updating-the-submodule)
- [Local Development: Run manually](#local-development-run-manually)
- [Optional GitHub Actions](#optional-github-actions)
  - [tag-on-merge.yml](#tag-on-mergeyml)
- [Environment Variables](#environment-variables)
- [License](#license)

## Scripts

### ci_post_clone.sh

Xcode Cloud post-clone hook. Runs after the repository is cloned. Executes `swiftlint.sh` to lint the codebase during CI builds.

### ci_pre_xcodebuild.sh

Xcode Cloud pre-build hook. Runs before xcodebuild starts. Calls `generate_xcconfig.sh` to generate xcconfig files from environment variables.

This enables you to inject API keys, feature flags, and other configuration at build time without committing them to source control.

### generate_xcconfig.sh

Converts `ENV_` prefixed environment variables into an xcconfig file for Xcode. Run once during project setup (or when secrets change) — the generated file persists across builds.

> **⚠️ Security Warning**
>
> This script generates **plain text** xcconfig values. Values can be extracted from compiled binaries using simple tools like `strings`.
>
> **Appropriate for:**
> - Analytics IDs (Google Analytics, Firebase)
> - Feature flags
> - Public API endpoints
> - Non-sensitive configuration
>
> **NOT appropriate for:**
> - Payment/billing API keys
> - Authentication secrets
> - Database credentials
> - Any key that could cause financial or security damage if exposed
>
> For sensitive credentials, use a backend proxy (keys never leave your server) or a dedicated secrets manager with obfuscation.

**Usage:**

```bash
generate_xcconfig.sh <output_directory> [product_name]
```

| Parameter | Description | Default |
|-----------|-------------|---------|
| `output_directory` | Where to write the xcconfig file | Required |
| `product_name` | Product name — used for output file naming and ENV_ variable prefix | `CI_PRODUCT` or `"App"` |

**Output:** `<output_dir>/<ProductName>Config.xcconfig` (gitignored — contains actual values)

**Variable naming convention:**

Environment variables follow the pattern `ENV_<ProductName>_<PropertyName>`. The product name maps to the `product_name` argument passed to the script. The script strips the `ENV_<ProductName>_` prefix and writes `<PropertyName> = <value>` to the xcconfig.

```
ENV_MyApp_apiKey=your-key        →  apiKey = your-key
ENV_MyApp_measurementId=G-XXX    →  measurementId = G-XXX
```

**Sources (checked in order):**

| Source | How ENV_ variables are set |
|--------|---------------------------|
| CI (Xcode Cloud) | App Store Connect → Environment Variables |
| Local (1Password) | `op run --environment <id>` injects variables into the shell |
| Fallback | Existing xcconfig used as-is |

#### Local Setup (1Password Environments)

Use [1Password Environments](https://developer.1password.com/docs/environments/) to manage config variables locally. Each developer runs the script once during project initialization — the generated xcconfig persists across builds.

**One-time setup:**

1. Install [1Password CLI](https://developer.1password.com/docs/cli/get-started/)
2. Create an Environment in 1Password (**Developer → View Environments**)
3. Add variables with `ENV_<ProductName>_` prefix (e.g., `ENV_MyApp_apiKey`)
4. Copy the example env file to your project root and fill in your values:
   ```bash
   cp ci_scripts/.env.example .env
   ```
   ```bash
   # .env (gitignored)
   export OP_SERVICE_ACCOUNT_TOKEN=your-token
   export OP_ENVIRONMENT_ID=your-env-id
   ```
5. Generate the xcconfig:
   ```bash
   (source .env && op run --environment "$OP_ENVIRONMENT_ID" -- \
     ./ci_scripts/generate_xcconfig.sh Config MyApp)
   ```
   The outer `()` runs everything in a subshell — `export`ed tokens are available to
   `op run` (a child process) but are automatically discarded when the subshell exits,
   so credentials don't persist in your shell session.

Re-run step 5 whenever secrets change in the 1Password Environment.

#### CI Setup (Xcode Cloud)

1. Add `ENV_<ProductName>_` prefixed variables in **App Store Connect → Environment Variables**
2. `ci_pre_xcodebuild.sh` calls this script automatically during builds

#### Example

For a product named "MyApp":

```bash
# Variables in environment (from 1Password or CI)
ENV_MyApp_apiKey=your-api-key
ENV_MyApp_measurementId=G-XXXXXXXXXX
```

```bash
./ci_scripts/generate_xcconfig.sh Config MyApp
```

Generates `Config/MyAppConfig.xcconfig`:
```xcconfig
apiKey = your-api-key
measurementId = G-XXXXXXXXXX
```

#### Xcode Integration

1. Run the script to generate the xcconfig
2. Add `<ProductName>Config.xcconfig` to `.gitignore`
3. Reference values in Info.plist: `$(propertyName)`
4. Access in Swift: `Bundle.main.object(forInfoDictionaryKey: "PropertyName") as? String ?? ""`
5. Handle missing values gracefully — if the xcconfig doesn't exist, variables are undefined

### validate_xcconfig.sh

Validates that required build settings from a generated xcconfig are present and resolved. Designed to run as a Run Script build phase before compilation, failing the build early if configuration is missing.

**Usage:**

```bash
validate_xcconfig.sh <key1> [key2] ...
```

The script performs two checks:

1. **File check** — Verifies `${SRCROOT}/Config/${PROJECT_NAME}Config.xcconfig` exists
2. **Key check** — Verifies each named key is set as a build setting and not an unresolved `$(...)` placeholder

**Xcode Build Phase Setup:**

Add as the first Run Script phase on each target (before Sources):

| Setting | Value |
|---------|-------|
| Shell | `/bin/sh` |
| Based on dependency analysis | Unchecked |

Script:
```bash
./ci_scripts/validate_xcconfig.sh analyticsId apiKey
```

Input Files:
```
$(SRCROOT)/ci_scripts/validate_xcconfig.sh
$(SRCROOT)/Config/$(PROJECT_NAME)Config.xcconfig
```

> **Note:** Input files are required for sandbox compatibility. Without them, sandboxed targets will deny file access to the script.

This pairs with `generate_xcconfig.sh` — one generates the config, the other validates it at build time.

### ci_post_xcodebuild.sh

Xcode Cloud post-build hook. Runs after xcodebuild completes. Only executes when `CI_ARCHIVE_PATH` is available (archive builds).

Calls:
- `firebase_upload_symbols.sh` - Upload dSYMs to Crashlytics
- `testflight_whattotest.sh` - Generate TestFlight release notes

### swiftlint.sh

Installs and runs SwiftLint for code linting.

| Environment | Behavior |
|-------------|----------|
| CI | Downloads a pinned, checksum-verified portable SwiftLint release, lints the repository |
| Local | Uses the installed SwiftLint, with `/opt/homebrew/bin` first on `PATH`, lints SRCROOT. A `swiftlint` that can't run (for example an x86_64 build without Rosetta) fails the build with an `error:` naming it |

**Configuration Files:**

| File | Purpose |
|------|---------|
| `ci_scripts/.swiftlint.yml` | Base config with sensible defaults |
| `.swiftlint.local.yml` | Project-specific overrides (gitignored) |

The script automatically uses `.swiftlint.local.yml` if it exists, otherwise falls back to the base config.

**Setup for project-specific exclusions:**

```bash
# Copy the template to your project root
cp ci_scripts/.swiftlint.local.yml.example .swiftlint.local.yml

# Edit to add your exclusions (e.g., generated code directories)
```

The local config uses `parent_config` to inherit all rules from the base config while adding project-specific exclusions.

See the [SwiftLint Rules Directory](https://realm.github.io/SwiftLint/rule-directory.html) for available rules.

### firebase_upload_symbols.sh

Uploads dSYM files to Firebase Crashlytics for crash symbolication.

| Environment | Behavior |
|-------------|----------|
| CI | Uses `upload-symbols` directly from the Firebase SDK checkout |
| Local | Uses the Firebase Crashlytics run script from SourcePackages |

The script automatically detects if Firebase is configured by checking for `GoogleService-Info.plist`. If not found, it skips gracefully without failing the build.

### testflight_whattotest.sh

Generates TestFlight "What to Test" release notes from git history. Creates `TestFlight/WhatToTest.en-US.txt` containing the last 20 commits formatted as:

```
- YYYY-MM-DD: commit message
```

### bump-version.sh

Interactive version management tool for Xcode projects. Automates semantic versioning, project file updates, and git tag creation.

**Usage:**
```bash
./bump-version.sh [major|minor|patch|tag]
./bump-version.sh tag [-y|--yes]  # Non-interactive mode for CI
```

If no argument is provided, the script displays an interactive menu to select the bump type. Use `-y` or `--yes` with the `tag` option to skip confirmation prompts and automatically push the tag to remote (useful for GitHub Actions or other CI pipelines).

**Bump Types:**

| Type | Description | Example |
|------|-------------|---------|
| `patch` | Bug fixes, minor changes | 1.2.3 → 1.2.4 |
| `minor` | New features, backwards compatible | 1.2.3 → 1.3.0 |
| `major` | Breaking changes | 1.2.3 → 2.0.0 |
| `tag` | Update existing tag only (no version change) | Re-tags current commit as rel.v1.2.3 |

**Features:**
- Automatically discovers `.xcodeproj` in the parent directory
- Reads current `MARKETING_VERSION` from `project.pbxproj`
- Updates all occurrences of `MARKETING_VERSION` in the project file
- Commits the version change with message "Bump version to X.Y.Z"
- Creates git tag in format: `rel.vX.Y.Z`
- Confirmation prompts before making changes

**The `tag` Option and Xcode Cloud Incremental Builds:**

The `tag` option is particularly useful for triggering incremental Xcode Cloud builds. When your Xcode Cloud workflow is configured to build on tag changes (e.g., tags matching `rel.v*`), you can use the `tag` option to:

- Force-update an existing release tag to point to a newer commit
- Trigger a new Xcode Cloud build without incrementing the version number
- Re-deploy the same version with additional fixes or changes

This enables a workflow where you can iterate on a release candidate by updating the tag, triggering rebuilds without burning through version numbers:

```bash
# Initial release
./bump-version.sh patch          # Creates rel.v1.2.4

# Need to include a quick fix in the same version
git commit -m "Fix critical bug"
./bump-version.sh tag            # Updates rel.v1.2.4 to current commit
git push origin -f rel.v1.2.4    # Force-push triggers new Xcode Cloud build
```

**Example Workflow:**

```bash
# Bump patch version (1.0.0 → 1.0.1)
./bump-version.sh patch

# Push commit and tag to remote
git push && git push origin rel.v1.0.1
```

### distribute.sh

Builds a Release archive, exports an ad-hoc IPA, and uploads it to
[Firebase App Distribution](https://firebase.google.com/docs/app-distribution).
An alternative to TestFlight that requires no App Store Connect record and no
review — suited to friends-and-family distribution.

App Distribution is delivery only: the app itself needs no Firebase SDK and no
`GoogleService-Info.plist`. Registering the iOS app in a Firebase project is
enough to obtain the App ID the upload needs.

**Configuration** (project-root `.env`, see `.env.example`):

| Variable | Purpose |
| --- | --- |
| `FIREBASE_APP_ID` | Required. Firebase console → Project settings → your iOS app |
| `FIREBASE_TESTER_GROUPS` | Optional comma-separated tester group aliases |
| `SCHEME` | Optional; defaults to the `.xcodeproj` basename |

**Usage:**

```bash
# Build, export, upload
./ci_scripts/distribute.sh

# Build and export only — verify signing without distributing
./ci_scripts/distribute.sh --skip-upload

# Override the generated release notes
./ci_scripts/distribute.sh --notes "Fixes the landscape share card"
```

Release notes default to the commit subjects since the last `rel.v*` tag,
which pairs with [bump-version.sh](#bump-versionsh)'s tagging.

**Signing:** runs with `-allowProvisioningUpdates`, so Xcode manages the
distribution certificate and ad-hoc profile. New tester devices must be added
to the Apple Developer portal (App Distribution collects UDIDs from testers);
the next export picks them up automatically. One-time prerequisites: a
Firebase project with the app's bundle ID registered as an iOS app, the
`firebase` CLI installed and logged in, and at least one registered device.

**Phases:**

- **Phase 1 (current) — local.** Runs on a developer machine: auth is the
  firebase CLI's cached login (`firebase login`), signing is local Xcode.
  This is the supported path today.
- **Phase 2 (later) — CI.** Auth via ambient credentials
  (`GOOGLE_APPLICATION_CREDENTIALS` service account, or workload identity)
  and signing material provisioned into the runner. Not built yet — the auth
  preflight already accepts ambient credentials, so a CI environment is not
  blocked by the interactive-login check, but the signing half is the real
  work and has deliberately not been started.

## Claude Code Lint Hooks

Shared [Claude Code](https://docs.anthropic.com/en/docs/claude-code) hooks and a git `pre-commit` hook that provide consistent swift-format and SwiftLint checks across all projects using this submodule. They live in `hooks/`: the Claude Code hooks are referenced by each project's `.claude/settings.json`, and the commit checks are shared through `hooks/lib/swift-checks.sh`.

### hooks/post-edit-lint.sh

**PostToolUse** hook for `Edit|Write`. Runs after Claude edits or creates a Swift file, giving immediate lint feedback per file, using the configs of the repository that holds the file. Claude only sees a PostToolUse hook's output as JSON, so findings are sent as `additionalContext`; a clean file prints plain "pass" lines for the transcript.

| Behavior | Detail |
|----------|--------|
| Skips non-`.swift` files | Exits silently |
| swift-format | Lint-only (no auto-fix) — reports issues to Claude, doesn't block |
| SwiftLint | Reports errors and warnings to Claude — doesn't block edits |
| Missing tools | Reports to Claude and allows the edit. A `swiftlint` that can't run (for example an x86_64 build without Rosetta) counts as missing, not as a pass |
| Missing parent config | Reports to Claude when `.swiftlint.local.yml` inherits from a file that is missing, for example an uninitialized submodule |

### hooks/pre-commit-lint.sh

**PreToolUse** hook for `Bash`. Runs before every Bash call and acts only on an actual `git commit`, as a formatting and lint check on what Claude commits. It reads the command's words, honoring quotes, so `rg 'git commit'` or a commit message that mentions `git add` doesn't trigger it, while `a && git commit`, `x="$(git commit)"`, backticks, subshells, `if …; then git commit`, and `git -C dir commit` do. Heredoc bodies are skipped.

This check is best effort: it runs before the shell does and predicts what the command will do. When it can't tell, it blocks and asks for a simpler command. To enforce formatting and lint on every commit, also install the git hook, [hooks/pre-commit.sh](#hookspre-commitsh), which runs after staging and sees exactly what git commits.

| Behavior | Detail |
|----------|--------|
| Shared checks | Everything in [Commit checks](#commit-checks). A failure **blocks the commit** (exit 2) |
| Warnings | Sent to Claude as `additionalContext` when the commit is allowed |
| Staging in the same call | **Blocks commit** (exit 2) when a git command not known to leave the index alone (for example `git add`, `git rm`, `git cherry-pick -n`) runs in the same Bash call as `git commit`. The hook runs before the whole call, so it can't see what gets staged. Stage first, then commit as its own call. Read-only commands such as `git status` or `git diff` are allowed |
| Unstaged content | **Blocks commit** (exit 2) for `git commit -a`, `-i`, `-o`, or with paths, which commit changes the hook can't check beforehand |
| Another repository or index | **Blocks commit** (exit 2) when `--git-dir`, `--work-tree`, `GIT_DIR`, `GIT_WORK_TREE`, or `GIT_INDEX_FILE` is set in the command |
| Forms it can't follow | **Blocks commit** (exit 2) when one Bash call runs `git commit` more than once, or runs it under a wrapper with options (`env -u X git commit`, `sudo -u me git commit`) |
| Repository | The one the commit runs in: the hook input's `cwd`, followed through `cd` (including `-P`), `pushd`, and `git -C`, which follows symlinks (a `cd` inside a subshell ends with it), so a worktree or submodule is checked against its own index and configs |
| Directory it can't tell | **Blocks commit** (exit 2) when the directory comes from something the text doesn't show: a `cd` or `pushd` to a variable or substitution, `-`, `+N`, `~user`, zsh's `cd old new`, `popd`, or a directory that doesn't exist yet. `cd` to a literal path works |
| Command it can't tell | **Blocks commit** (exit 2) when the command contains the word `commit` (quotes removed) and a command name comes from a variable, substitution, `$'…'` escape, or zsh's `=git`, also under wrappers; or when `eval`, `alias`, `source`, or `sh`/`bash`/`zsh -c` is given a string that contains `commit` or a value the text doesn't show. A shell running a script (`bash script.sh`) isn't affected. An argument the text doesn't show counts as possible unstaged content (`$'--\x61ll'`), while option values such as `-m "$msg"` are fine |
| jq missing | **Blocks commit** (exit 2) when the input looks like a commit, since the command can't be read; other commands pass |

Limits: scripts that run or stage a commit (`./release.sh`) aren't followed; `commit` spelled with escapes (`$'\x63ommit'`) isn't recognized; a `$(…)` inside an unquoted heredoc isn't followed; and quoting is tracked per word, so a redirection character quoted partway through a word (`2\>file`) is read as a redirection.

### hooks/pre-commit.sh

A git `pre-commit` hook running the [Commit checks](#commit-checks). Git runs it after staging, for every commit from any client, so it sees exactly what gets committed, including `git commit -a`. A failure blocks the commit (exit 1). Install it from the project root; an existing hook is left in place:

```bash
hook="$(git rev-parse --git-path hooks)/pre-commit"
if [ -e "$hook" ] || [ -L "$hook" ]; then
    echo "$hook already exists. Add this line to it instead:"
    echo '"$(git rev-parse --show-toplevel)/ci_scripts/hooks/pre-commit.sh" || exit 1'
else
    ln -s "$PWD/ci_scripts/hooks/pre-commit.sh" "$hook"
fi
```

From an existing hook or another hook manager (for example `.husky/pre-commit`), call `"$(git rev-parse --show-toplevel)/ci_scripts/hooks/pre-commit.sh" || exit 1`. With both this and the Claude Code hook installed, a commit from Claude is checked twice; formatting is idempotent.

### Commit checks

`hooks/lib/swift-checks.sh`, shared by both commit hooks, checks the staged Swift files of the repository:

| Behavior | Detail |
|----------|--------|
| Files | Added, copied, modified, and renamed `.swift` files, read null-separated so any file name works |
| swift-format | Auto-formats staged files in place and re-stages them |
| Partly staged files | A staged file that also has unstaged changes is not auto-formatted (warning), because re-staging would commit those changes. Its staged content is linted, not the working copy |
| SwiftLint | Lints staged files — **blocks the commit on errors** |
| Symlinks | A staged symlink is skipped with a warning, so formatting can't write through a link. A staged regular file whose working copy is now a symlink is checked like a partly staged file |
| swift-format failure | **Blocks the commit** when swift-format can't format a file, for example with a malformed `.swift-format` |
| Merges | During a merge, a file whose staged content matches a merge parent (brought in unchanged) is skipped. A heuristic, not a detector for hand-resolved conflicts |
| Missing parent config | **Blocks the commit** when `.swiftlint.local.yml` inherits from a file that is missing, because SwiftLint would only warn and lint without the parent's rules |
| Missing tools | **Blocks the commit** — both tools are required. A `swiftlint` that can't run counts as missing |
| No staged Swift files | Skips |

Standard-input linting of partly staged files doesn't apply the config's `excluded` paths.

### Hook Setup

Add the following to your project's `.claude/settings.json`:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/ci_scripts/hooks/post-edit-lint.sh"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "\"$CLAUDE_PROJECT_DIR\"/ci_scripts/hooks/pre-commit-lint.sh"
          }
        ]
      }
    ]
  }
}
```

A `matcher` matches the tool name only, so `Bash(git commit*)` never fires. Use `"matcher": "Bash"`; the script finds `git commit` itself. A handler-level `"if": "Bash(git commit *)"` is not needed, and would skip forms such as `git -C dir commit`.

`$CLAUDE_PROJECT_DIR` is set automatically by Claude Code to the project root, so the paths resolve correctly regardless of where Claude invokes the hook from.

### Hook Prerequisites

| Tool | Install | Required for |
|------|---------|-------------|
| swift-format | Included with Xcode (Swift 5.9+) | All hooks |
| SwiftLint | `brew install swiftlint` | All hooks |
| jq | Included with recent macOS, or `brew install jq` | Claude Code hooks (parses hook input) |

On Apple Silicon, when `/opt/homebrew/bin` isn't on `PATH` (a session started outside a login shell), the hooks add it first, so an x86_64 tool in `/usr/local/bin` doesn't win. An existing `PATH` that lists it keeps its order. Elsewhere `PATH` is unchanged.

When `swift format` isn't available because the Command Line Tools are selected (`xcode-select -p`), the hooks use Xcode's toolchain if Xcode is installed. A selection that works, or an explicit `DEVELOPER_DIR`, is kept.

### Hook Tests

```bash
tests/hooks.sh
```

Runs the hooks against throwaway repositories with the system bash (3.2 on macOS). Requires git, jq, swift-format, and SwiftLint; skips when one is missing.

### Configuration Precedence

Both hooks auto-detect SwiftLint config using this priority:

1. `.swiftlint.local.yml` in project root (project-specific overrides)
2. `ci_scripts/.swiftlint.yml` (shared base config)
3. SwiftLint defaults (no config file found)

swift-format uses `.swift-format` in the project root. If the file doesn't exist, swift-format is skipped.

### Project-Specific Exclusions

The hooks contain **no hardcoded path exclusions**. Each project handles exclusions through its own config files:

| Tool | Exclusion method |
|------|-----------------|
| SwiftLint | `excluded:` key in `.swiftlint.local.yml` |
| swift-format | Not natively supported — files are only linted when Claude edits them or stages them for commit |

**Example `.swiftlint.local.yml`** for project-specific exclusions:

```yaml
parent_config: ci_scripts/.swiftlint.yml

excluded:
  - data/emoji-generated
  - scripts
  - Pods
  - .build
```

## Installation

### Step 1: Add as a Git Submodule

Add this repository as a git submodule named `ci_scripts` at your project root. The `ci_scripts` name is required for Xcode Cloud compatibility.

```bash
cd /path/to/YourApp

# Add the submodule
git submodule add https://github.com/scarrillo/ios-ci-scripts.git ci_scripts

# Commit the submodule reference
git commit -m "Add CI scripts submodule"
```

Your project structure will look like:

```
YourApp/
├── YourApp.xcodeproj/
├── YourApp/
│   ├── AppDelegate.swift
│   ├── GoogleService-Info.plist
│   └── ...
├── .claude/
│   └── settings.json        # ← Hook paths point to ci_scripts/hooks/
├── ci_scripts/               # ← Submodule (this repo)
│   ├── hooks/
│   │   ├── lib/swift-checks.sh
│   │   ├── post-edit-lint.sh
│   │   ├── pre-commit-lint.sh
│   │   └── pre-commit.sh     # ← git pre-commit hook (optional)
│   ├── workflows/
│   │   └── tag-on-merge.yml  # ← Copy to .github/workflows/
│   ├── ci_post_clone.sh
│   ├── ci_post_xcodebuild.sh
│   ├── firebase_upload_symbols.sh
│   ├── swiftlint.sh
│   └── ...
└── .gitmodules
```

### Step 2: Configure Xcode Build Phases (Local Builds)

To run scripts during local builds, add them as Run Script phases in your Xcode project:

1. Open your project in Xcode
2. Select your app target
3. Go to **Build Phases**
4. Click **+** → **New Run Script Phase**
5. Configure the script (see examples below)

**SwiftLint (Build Phase)**

Add as an early build phase to lint code before compilation:

| Setting | Value |
|---------|-------|
| Shell | `/bin/sh` |
| Based on dependency analysis | ☐ Unchecked |

Script:
```bash
# Only run locally - Xcode Cloud uses ci_post_clone.sh
if [ -z "$CI" ]; then
    ./ci_scripts/swiftlint.sh
fi
```

**Firebase Crashlytics (Build Phase)**

Add as the final build phase to upload dSYM symbols:

| Setting | Value |
|---------|-------|
| Shell | `/bin/sh` |
| Based on dependency analysis | ☐ Unchecked |

Script:
```bash
# Only run locally - Xcode Cloud uses ci_post_xcodebuild.sh
if [ -z "$CI" ]; then
    ./ci_scripts/firebase_upload_symbols.sh
fi
```

Input Files:
```
$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/GoogleService-Info.plist
$(TARGET_BUILD_DIR)/$(EXECUTABLE_PATH)
${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}
${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}/Contents/Info.plist
${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}/Contents/Resources/DWARF/${PRODUCT_NAME}.debug.dylib
```

> **Note:** Adding input files helps Xcode determine when the script needs to re-run and improves incremental build performance.

### Step 3: Xcode Cloud (Release Builds)

Xcode Cloud automatically discovers and executes scripts in the `ci_scripts/` directory at specific points in the build lifecycle:

| Script | Trigger | Purpose |
|--------|---------|---------|
| `ci_post_clone.sh` | After repository clone | Runs SwiftLint |
| `ci_pre_xcodebuild.sh` | Before build | Generates xcconfig from env variables |
| `ci_post_xcodebuild.sh` | After archive build | Uploads dSYMs, generates TestFlight notes |

**Xcode Cloud and Submodules**

Xcode Cloud automatically handles git submodules:

- Submodules are recursively initialized and updated during clone
- No additional configuration required in Xcode Cloud settings
- Scripts execute with full access to submodule contents

**Configuring Xcode Cloud Workflows**

For release builds triggered by git tags:

1. In Xcode, go to **Product** → **Xcode Cloud** → **Manage Workflows**
2. Create or edit a workflow
3. Under **Start Conditions**, add:
   - **Source Branch Changes**: `main` (for development builds)
   - **Tag Changes**: `rel.v*` (for release builds)
4. Under **Actions**, select **Archive** for release builds

The `ci_post_xcodebuild.sh` script only runs for archive builds (when `CI_ARCHIVE_PATH` is set), so it won't interfere with test or analysis workflows.

## Updating the Submodule

To pull the latest CI script updates into your project:

```bash
# Update to latest commit
cd ci_scripts
git pull origin main
cd ..

# Commit the updated submodule reference
git add ci_scripts
git commit -m "Update CI scripts submodule"
git push
```

Or update all submodules at once:

```bash
git submodule update --remote --merge
git commit -am "Update submodules"
```

## Local Development: Run manually

Run scripts directly from the command line:

```bash
cd ci_scripts

# Lint the codebase
./swiftlint.sh

# Bump version and create release tag
./bump-version.sh
```

## Optional GitHub Actions

Workflow templates in `workflows/` that help automate Xcode Cloud builds. These are **not** active workflows — GitHub only executes workflows in `.github/workflows/`. Copy them into your project to use them.

### tag-on-merge.yml
Add this GitHub Action to automatically create/update a git tag when a PR is merged to main. This runs `bump-version.sh tag -y` to tag the current `MARKETING_VERSION` and push it to the remote.

This will automatically trigger your Xcode Cloud workflow listening for tags prefixed with `rel.v*`. [Configure Xcode Cloud (Release Builds by tag)](#step-3-xcode-cloud-release-builds)

**Install:**

```bash
cp ci_scripts/workflows/tag-on-merge.yml .github/workflows/tag-on-merge.yml
```

Or ask [Claude Code](https://docs.anthropic.com/en/docs/claude-code):
> Install the tag-on-merge GitHub Action from ci_scripts/workflows/

**Requirements:**
- This repo as a submodule at `ci_scripts/`
- `MARKETING_VERSION` set in your `.xcodeproj`
- Repository permissions: `contents: write`


## Environment Variables

The scripts detect CI environments using these variables:

| Variable | Description |
|----------|-------------|
| `CI` | Set in CI environments |
| `CI_PRIMARY_REPOSITORY_PATH` | Xcode Cloud repository checkout path |
| `CI_WORKSPACE_PATH` | Xcode Cloud workspace path |
| `CI_ARCHIVE_PATH` | Path to the archive (post-build) |
| `CI_DERIVED_DATA_PATH` | Derived data location |
| `CI_PRODUCT` | Product name (used for xcconfig file naming) |
| `SRCROOT` | Xcode project source root (local builds) |
| `BUILD_DIR` | Xcode build directory (local builds) |

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
