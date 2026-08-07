#!/bin/bash
#
# bump-version.sh - Semantic version management for Xcode projects
#
# SPDX-License-Identifier: MIT
# Copyright (c) 2024-2025 Shawn Carrillo
#
# Usage: ./bump-version.sh [major|minor|patch|tag]
#        ./bump-version.sh tag [-y|--yes]  (non-interactive, for CI)
#
# Bash Reference: https://tldp.org/LDP/abs/html/comparison-ops.html
# Shell options:
#   set -e : Exit immediately if a command exits with a non-zero status
# Test operators:
#   -n STRING : True if string is not empty
#   -z STRING : True if string is empty
#   -d PATH   : True if path exists and is a directory
#   -f PATH   : True if path exists and is a regular file
#

set -e

# Parse arguments
BUMP_TYPE=""
AUTO_CONFIRM=false

for arg in "$@"; do
    case "$arg" in
        -y|--yes)
            AUTO_CONFIRM=true
            ;;
        major|minor|patch|tag)
            BUMP_TYPE="$arg"
            ;;
    esac
done

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Find .xcodeproj directory dynamically
XCODEPROJ=$(find "$PROJECT_ROOT" -maxdepth 1 -name "*.xcodeproj" -type d | head -1)

if [ -z "$XCODEPROJ" ]; then
    echo "Error: No .xcodeproj found in $PROJECT_ROOT"
    exit 1
fi

PROJECT_FILE="$XCODEPROJ/project.pbxproj"

# Check if project file exists
if [ ! -f "$PROJECT_FILE" ]; then
    echo "Error: project.pbxproj not found at $PROJECT_FILE"
    exit 1
fi

echo "Using project: $(basename "$XCODEPROJ")"

# Locate the version source.
#
# Projects authored in the Xcode GUI carry MARKETING_VERSION in
# project.pbxproj (checked first — the original behavior). Projects that
# centralize build settings in xcconfig files declare it there instead, and
# the pbxproj has no such key. Support both:
#   1. project.pbxproj, if it contains MARKETING_VERSION
#   2. otherwise, exactly one *.xcconfig in the repo defining it
read_version() {
    # Tolerates both syntaxes: `MARKETING_VERSION = 1.2.3;` (pbxproj) and
    # `MARKETING_VERSION = 1.2.3` (xcconfig, optionally with a // comment).
    grep -m1 -E "^[[:space:]]*MARKETING_VERSION[[:space:]]*=" "$1" \
        | sed -E 's/.*=[[:space:]]*//; s/;.*//; s|//.*||; s/[[:space:]]*$//'
}

if grep -q "MARKETING_VERSION" "$PROJECT_FILE"; then
    VERSION_FILE="$PROJECT_FILE"
else
    # Exclude this submodule and build products from the search.
    XCCONFIG_MATCHES=$(find "$PROJECT_ROOT" \
        -name "*.xcconfig" \
        -not -path "*/ci_scripts/*" \
        -not -path "*/.build/*" \
        -not -path "*/DerivedData/*" \
        -not -path "*/node_modules/*" \
        -exec grep -l -E "^[[:space:]]*MARKETING_VERSION[[:space:]]*=" {} + 2>/dev/null || true)

    MATCH_COUNT=$(echo "$XCCONFIG_MATCHES" | grep -c . || true)

    if [ "$MATCH_COUNT" -eq 0 ]; then
        echo "Error: Could not find MARKETING_VERSION in project.pbxproj or any .xcconfig"
        exit 1
    elif [ "$MATCH_COUNT" -gt 1 ]; then
        echo "Error: MARKETING_VERSION is defined in multiple .xcconfig files:"
        echo "$XCCONFIG_MATCHES" | sed 's/^/  /'
        echo "Consolidate to a single definition so the version source is unambiguous."
        exit 1
    fi

    VERSION_FILE="$XCCONFIG_MATCHES"
    echo "Version source: ${VERSION_FILE#"$PROJECT_ROOT"/}"
fi

# Get current version
CURRENT_VERSION=$(read_version "$VERSION_FILE")

if [ -z "$CURRENT_VERSION" ]; then
    echo "Error: Could not find MARKETING_VERSION in $VERSION_FILE"
    exit 1
fi

echo "Current version: $CURRENT_VERSION"

# Parse SemVer components
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

# Validate -y flag is only used with tag
if [ "$AUTO_CONFIRM" = true ] && [ "$BUMP_TYPE" != "tag" ]; then
    echo "Error: -y/--yes flag is only supported with 'tag' bump type"
    echo "Usage: ./bump-version.sh tag -y"
    exit 1
fi

# Prompt for bump type if not provided
if [ -z "$BUMP_TYPE" ]; then
    echo ""
    echo "Select version bump type:"
    echo "  1) patch  ($MAJOR.$MINOR.$((PATCH + 1))) - Bug fixes, minor changes"
    echo "  2) minor  ($MAJOR.$((MINOR + 1)).0) - New features, backwards compatible"
    echo "  3) major  ($((MAJOR + 1)).0.0) - Breaking changes"
    echo "  4) tag    (rel.v$CURRENT_VERSION) - Update existing tag only"
    echo ""
    read -p "Enter choice [1-4] (default: 1): " choice

    case "$choice" in
        2) BUMP_TYPE="minor" ;;
        3) BUMP_TYPE="major" ;;
        4) BUMP_TYPE="tag" ;;
        *) BUMP_TYPE="patch" ;;
    esac
fi

# Handle "tag" type separately (no version change)
if [ "$BUMP_TYPE" = "tag" ]; then
    TAG_NAME="rel.v$CURRENT_VERSION"
    TAG_EXISTS=$(git tag -l "$TAG_NAME")

    echo "Bump type: $BUMP_TYPE"
    echo "Tag: $TAG_NAME"

    if [ -n "$TAG_EXISTS" ]; then
        echo "Status: Tag already exists"
        echo ""

        # Confirm force-update (skip if auto-confirm)
        if [ "$AUTO_CONFIRM" != true ]; then
            read -p "Force-update existing tag '$TAG_NAME'? [y/N]: " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                echo "Aborted."
                exit 0
            fi
        fi

        echo "Updating git tag: $TAG_NAME"
        git tag -f "$TAG_NAME"

        echo ""
        echo "Done! Tag '$TAG_NAME' updated to current commit"

        if [ "$AUTO_CONFIRM" = true ]; then
            echo "Pushing tag to remote..."
            git push origin -f "$TAG_NAME"
        else
            echo ""
            echo "To push to remote, run:"
            echo "  git push origin -f $TAG_NAME"
        fi
    else
        echo "Status: New tag"
        echo ""

        # Confirm creation (skip if auto-confirm)
        if [ "$AUTO_CONFIRM" != true ]; then
            read -p "Create tag '$TAG_NAME'? [y/N]: " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                echo "Aborted."
                exit 0
            fi
        fi

        echo "Creating git tag: $TAG_NAME"
        git tag "$TAG_NAME"

        echo ""
        echo "Done! Tag '$TAG_NAME' created"

        if [ "$AUTO_CONFIRM" = true ]; then
            echo "Pushing tag to remote..."
            git push origin "$TAG_NAME"
        else
            echo ""
            echo "To push to remote, run:"
            echo "  git push origin $TAG_NAME"
        fi
    fi
    exit 0
fi

# Calculate new version based on bump type
case "$BUMP_TYPE" in
    major)
        NEW_VERSION="$((MAJOR + 1)).0.0"
        ;;
    minor)
        NEW_VERSION="$MAJOR.$((MINOR + 1)).0"
        ;;
    patch)
        NEW_VERSION="$MAJOR.$MINOR.$((PATCH + 1))"
        ;;
    *)
        echo "Error: Invalid bump type '$BUMP_TYPE'. Use: major, minor, patch, or tag"
        exit 1
        ;;
esac

echo "Bump type: $BUMP_TYPE"
echo "New version: $NEW_VERSION"
echo ""

# Confirm before proceeding
read -p "Proceed with version bump? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# Update version in the source file (all occurrences). The pattern preserves
# whatever follows the version — the pbxproj's `;`, or an xcconfig comment.
sed -i '' -E "s/(MARKETING_VERSION[[:space:]]*=[[:space:]]*)$CURRENT_VERSION/\1$NEW_VERSION/g" "$VERSION_FILE"

# Verify the update
UPDATED_VERSION=$(read_version "$VERSION_FILE")

if [ "$UPDATED_VERSION" != "$NEW_VERSION" ]; then
    echo "Error: Version update failed"
    exit 1
fi

echo "Updated ${VERSION_FILE#"$PROJECT_ROOT"/} to version $NEW_VERSION"

# Commit the version change
echo "Committing version bump..."
git add "$VERSION_FILE"
git commit -m "Bump version to $NEW_VERSION"

# Create git tag
TAG_NAME="rel.v$NEW_VERSION"

echo "Creating git tag: $TAG_NAME"
git tag "$TAG_NAME"

echo ""
echo "Done! Version bumped to $NEW_VERSION"
echo "Committed and tagged as '$TAG_NAME'"
echo ""
echo "To push to remote, run:"
echo "  git push && git push origin $TAG_NAME"
