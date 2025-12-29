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

# Get current version
CURRENT_VERSION=$(grep -m1 "MARKETING_VERSION" "$PROJECT_FILE" | sed 's/.*= \(.*\);/\1/')

if [ -z "$CURRENT_VERSION" ]; then
    echo "Error: Could not find MARKETING_VERSION in project file"
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
        echo ""
        echo "To push to remote, run:"
        echo "  git push origin -f $TAG_NAME"
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
        echo ""
        echo "To push to remote, run:"
        echo "  git push origin $TAG_NAME"
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

# Update version in project file (all occurrences)
sed -i '' "s/MARKETING_VERSION = $CURRENT_VERSION;/MARKETING_VERSION = $NEW_VERSION;/g" "$PROJECT_FILE"

# Verify the update
UPDATED_VERSION=$(grep -m1 "MARKETING_VERSION" "$PROJECT_FILE" | sed 's/.*= \(.*\);/\1/')

if [ "$UPDATED_VERSION" != "$NEW_VERSION" ]; then
    echo "Error: Version update failed"
    exit 1
fi

echo "Updated project.pbxproj to version $NEW_VERSION"

# Commit the version change
echo "Committing version bump..."
git add "$PROJECT_FILE"
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
