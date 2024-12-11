#!/bin/bash
# Unified dist.sh script with .distsConfig support

SCRIPT_PATH=$(dirname "$0")
SCRIPT_NAME=$(basename "$0")

# Utility functions
vercomp() {
    if [[ $1 == $2 ]]; then
        echo 0
        return
    fi
    local IFS=.
    local i ver1=($1) ver2=($2)
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do ver1[i]=0; done
    for ((i=0; i<${#ver1[@]}; i++)); do
        if [[ -z ${ver2[i]} ]]; then ver2[i]=0; fi
        if ((10#${ver1[i]} > 10#${ver2[i]})); then echo 1; return; fi
        if ((10#${ver1[i]} < 10#${ver2[i]})); then echo 2; return; fi
    done
    echo 0
}

getParsedVersion() {
    echo "$1" | sed -E 's/^[^0-9]*//'
}

printError() {
    local message="$1"
    echo " ┍━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┑"
    echo "     ERROR: $message"
    echo " ┕━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┙"
}

help() {
    echo ""
    echo "Usage: $SCRIPT_NAME -t <tag> -p {ios|android|both} [-c <config_file>] [-r {release|develop}]"
    echo "       $SCRIPT_NAME -h"
    echo ""
    echo "Examples:"
    echo "  $SCRIPT_NAME -t 'v1.2.3' -p both -r release"
    echo "  $SCRIPT_NAME --config .distsConfig --dry-run"
    echo ""
}

loadConfig() {
    local configFile="$1"
    if [ -f "$configFile" ]; then
        echo "Loading configuration from $configFile..."
        while IFS='=' read -r key value; do
            case "$key" in
                TAG) GIT_TAG_FULL="$value" ;;
                PLATFORM) INPUT_OS="$value" ;;
                RELEASE_TYPE) RELEASE_TYPE="$value" ;;
                AUTO_UPDATE) UPDATE_VERSION="$value" ;;
                BUILD_NUMBER) BUILD_NUMBER="$value" ;;
                *) ;;
            esac
        done < "$configFile"
    else
        printError "Configuration file not found: $configFile"
        exit 1
    fi
}

checkArguments() {
    if [ -z "$GIT_TAG_FULL" ]; then
        printError "No tag specified"
        help
        exit 1
    fi
    if [ -z "$INPUT_OS" ]; then INPUT_OS="both"; fi
    if [ -n "$CONFIG_FILE" ] && [ ! -f "$CONFIG_FILE" ]; then
        printError "Config file not found: $CONFIG_FILE"
        exit 1
    fi
}

updateVersion() {
    local platform="$1"
    if [[ "$platform" == "ios" || "$platform" == "both" ]]; then
        IOS_FILE=$(find . -name 'project.pbxproj' -not -path "*/Pods/*" -not -path "*/node_modules/*")
        if [ -f "$IOS_FILE" ]; then
            oldMarketingVersion=$(grep 'MARKETING_VERSION =' "$IOS_FILE" | awk '{print $3}' | tr -d ';')
            oldCurrentProjectVersion=$(grep 'CURRENT_PROJECT_VERSION =' "$IOS_FILE" | awk '{print $3}' | tr -d ';')
            if [ "$DRY_RUN" -eq 1 ]; then
                echo "[DRY-RUN] Would update iOS file:"
                echo "  Replace MARKETING_VERSION = $oldMarketingVersion; with MARKETING_VERSION = $MARKET_VERSION;"
                echo "  Replace CURRENT_PROJECT_VERSION = $oldCurrentProjectVersion; with CURRENT_PROJECT_VERSION = $BUILD_NUMBER;"
            else
                sed -i "s/MARKETING_VERSION = $oldMarketingVersion;/MARKETING_VERSION = $MARKET_VERSION;/" "$IOS_FILE"
                sed -i "s/CURRENT_PROJECT_VERSION = $oldCurrentProjectVersion;/CURRENT_PROJECT_VERSION = $BUILD_NUMBER;/" "$IOS_FILE"
                echo "Updated iOS version in $IOS_FILE"
            fi
        fi
    fi

    if [[ "$platform" == "android" || "$platform" == "both" ]]; then
        AOS_FILE=$(find . -name 'build.gradle' -exec grep -lir 'com.android.application' {} + | grep -v 'node_modules')
        if [ -f "$AOS_FILE" ]; then
            oldVersionName=$(grep 'versionName' "$AOS_FILE" | awk -F\" '{print $2}')
            oldVersionCode=$(grep 'versionCode' "$AOS_FILE" | awk '{print $2}')
            parsedTagVersion=$(getParsedVersion "$GIT_TAG_FULL")
            versionComparison=$(vercomp "$parsedTagVersion" "$oldVersionName")

            if [ $versionComparison -lt 2 ]; then
                if [ "$DRY_RUN" -eq 1 ]; then
                    echo "[DRY-RUN] Would update Android file:"
                    echo "  Replace versionName \"$oldVersionName\" with versionName \"$parsedTagVersion\""
                    echo "  Replace versionCode $oldVersionCode with versionCode $BUILD_NUMBER"
                else
                    sed -i "s/versionName \"$oldVersionName\"/versionName \"$parsedTagVersion\"/" "$AOS_FILE"
                    sed -i "s/versionCode $oldVersionCode/versionCode $BUILD_NUMBER/" "$AOS_FILE"
                    echo "Updated Android version in $AOS_FILE"
                fi
            else
                printError "Parsed tag version ($parsedTagVersion) is older than current version ($oldVersionName). Update aborted."
                exit 1
            fi
        fi
    fi
}

# Default variables
UPDATE_VERSION=0
DRY_RUN=0
USING_CONFIG=0
CONFIG_FILE=".distsConfig"
MARKET_VERSION=""
BUILD_NUMBER=1

# Argument parsing
while [[ $# -gt 0 ]]; do
    case $1 in
    -p | --platform)
        INPUT_OS="$2"
        shift 2
        ;;
    -t | --tag)
        GIT_TAG_FULL="$2"
        shift 2
        ;;
    -c | --config)
        CONFIG_FILE="${2:-.distsConfig}"
        shift
        ;;
    -r | --release-type)
        RELEASE_TYPE="$2"
        shift 2
        ;;
    -a | --auto-update)
        UPDATE_VERSION=1
        shift
        ;;
    --dry-run)
        DRY_RUN=1
        shift
        ;;
    -h | --help)
        help
        exit 0
        ;;
    *)
        printError "Unknown option: $1"
        help
        exit 1
        ;;
    esac
done

# Load config file if specified
[ -f "$CONFIG_FILE" ] && loadConfig "$CONFIG_FILE"

# Main Process
checkArguments

if git diff --quiet && git diff --cached --quiet; then
    echo "Working directory clean."
    if [ "$UPDATE_VERSION" -eq 1 ]; then
        updateVersion "$INPUT_OS"
    fi

    if git tag | grep -q "$GIT_TAG_FULL"; then
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "[DRY-RUN] Tag $GIT_TAG_FULL exists. Would delete it locally and from remote."
        else
            git tag -d "$GIT_TAG_FULL"
            git push --delete origin "$GIT_TAG_FULL"
            echo "Tag $GIT_TAG_FULL deleted locally and from remote."
        fi
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[DRY-RUN] Would create tag $GIT_TAG_FULL and push it to remote."
    else
        git tag -a "$GIT_TAG_FULL" -m "Release: $GIT_TAG_FULL"
        git push origin "$GIT_TAG_FULL"
        echo "Tag $GIT_TAG_FULL created and pushed."
    fi
else
    printError "Uncommitted changes present. Please commit first."
    exit 1
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY-RUN] All operations simulated successfully."
else
    echo "All operations completed successfully."
fi