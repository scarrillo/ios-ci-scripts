# iOS CI Scripts

A collection of shell scripts for iOS CI/CD workflows, designed to work with Xcode Cloud and local development environments. Built from learnings gleaned from the developer community and shared back for others to learn from, adapt, and improve upon.

These scripts also served as the inspiration for the [Claude Code Release Plugin](https://github.com/scarrillo/release).

## Table of Contents

- [Scripts](#scripts)
  - [bump-version.sh](#bump-versionsh)
  - [ci_post_clone.sh](#ci_post_clonesh)
  - [ci_post_xcodebuild.sh](#ci_post_xcodebuildsh)
  - [swiftlint.sh](#swiftlintsh)
  - [firebase_upload_symbols.sh](#firebase_upload_symbolssh)
  - [testflight_whattotest.sh](#testflight_whattotestsh)
- [Installation](#installation)
  - [Step 1: Add as a Git Submodule](#step-1-add-as-a-git-submodule)
  - [Step 2: Configure Xcode Build Phases (Local Builds)](#step-2-configure-xcode-build-phases-local-builds)
  - [Step 3: Xcode Cloud (Release Builds)](#step-3-xcode-cloud-release-builds)
- [Updating the Submodule](#updating-the-submodule)
- [Local Development: Run manually](#local-development-run-manually)
- [Environment Variables](#environment-variables)
- [License](#license)

## Scripts

### ci_post_clone.sh

Xcode Cloud post-clone hook. Runs after the repository is cloned. Executes `swiftlint.sh` to lint the codebase during CI builds.

### ci_post_xcodebuild.sh

Xcode Cloud post-build hook. Runs after xcodebuild completes. Only executes when `CI_ARCHIVE_PATH` is available (archive builds).

Calls:
- `firebase_upload_symbols.sh` - Upload dSYMs to Crashlytics
- `testflight_whattotest.sh` - Generate TestFlight release notes

### swiftlint.sh

Installs and runs SwiftLint for code linting.

| Environment | Behavior |
|-------------|----------|
| CI | Installs SwiftLint via Homebrew, lints the repository |
| Local | Uses existing SwiftLint installation, lints SRCROOT |

Configuration: `.swiftlint.yml` - A sample SwiftLint configuration is included. Customize it to match your project's coding standards. See the [SwiftLint Rules Directory](https://realm.github.io/SwiftLint/rule-directory.html) for available rules.

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

If no argument is provided, the script displays an interactive menu to select the bump type. Use `-y` or `--yes` with the `tag` option to skip confirmation prompts (useful for GitHub Actions or other CI pipelines).

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

## Installation

### Step 1: Add as a Git Submodule

Add this repository as a git submodule named `ci_scripts` at your project root. The `ci_scripts` name is required for Xcode Cloud compatibility.

```bash
cd /path/to/YourApp

# Add the submodule
git submodule add https://github.com/user/ios-ci-scripts.git ci_scripts

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
├── ci_scripts/              # ← Submodule (this repo)
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

## Environment Variables

The scripts detect CI environments using these variables:

| Variable | Description |
|----------|-------------|
| `CI` | Set in CI environments |
| `CI_WORKSPACE_PATH` | Xcode Cloud workspace path |
| `CI_ARCHIVE_PATH` | Path to the archive (post-build) |
| `CI_DERIVED_DATA_PATH` | Derived data location |
| `CI_PRODUCT` | Product name |
| `SRCROOT` | Xcode project source root (local builds) |
| `BUILD_DIR` | Xcode build directory (local builds) |

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
