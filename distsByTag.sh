#!/bin/bash
# Unified dist.sh script with Jenkins integration and complete Git processing

set -euo pipefail  # Added for better error handling

SCRIPT_PATH=$(dirname "$0")
SCRIPT_NAME=$(basename "$0")


# Utility functions 섹션 아래에 스피너 함수들 추가
function spinner() {
    local i sp n
    sp='/-\|'
    n=${#sp}
    printf "[$SCRIPT_NAME] Wait a moment... "
    while sleep 0.1; do
        printf "%s\b" "${sp:i++%n:1}"
    done
}

function show_spinner() {
    tput civis #hide cursor
    spinner &
    spinner_pid=$!
}

function hide_spinner() {
    if [ -n "${spinner_pid:-}" ]; then
        kill -9 "$spinner_pid" 2>/dev/null
        wait "$spinner_pid" 2>/dev/null || true
        unset spinner_pid
        tput cnorm
        printf "\r%s\n" "완료"
    fi
}

# Utility functions
vercomp() {
    [[ $1 == $2 ]] && { echo 0; return; }
    local IFS=. i ver1=($1) ver2=($2)
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do ver1[i]=0; done
    for ((i=0; i<${#ver1[@]}; i++)); do
        ver2[i]=${ver2[i]:-0}
        if ((10#${ver1[i]} > 10#${ver2[i]})); then echo 1; return; fi
        if ((10#${ver1[i]} < 10#${ver2[i]})); then echo 2; return; fi
    done
    echo 0
}

getParsedVersion() {
    sed -E 's/^[^0-9]*//' <<< "$1"
}

printError() {
    cat << EOF
 ┍━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┑
     [$SCRIPT_NAME] ERROR: $1
 ┕━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┙
EOF
}

confirm() {
    local message="$1"
    while true; do
        read -rp "[$SCRIPT_NAME] $message (y/n): " answer
        case $answer in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "[$SCRIPT_NAME] Please answer yes (y) or no (n).";;
        esac
    done
}

help() {
    cat << EOF

Usage: $SCRIPT_NAME --make-config        설정 파일 생성
       $SCRIPT_NAME -t <tag> -p {ios|android|both} [-c <config_file>] [-r {release|develop}]
       $SCRIPT_NAME --jenkins-url <url> --jenkins-job <job-name> --dry-run
       $SCRIPT_NAME --jenkins-user     Jenkins 사용자 ID
       $SCRIPT_NAME --jenkins-token    Jenkins API 토큰
       $SCRIPT_NAME -u|--update-version-string    버전 문자열 업데이트
       $SCRIPT_NAME -uf|--update-version-string-forcefully    버전 체크를 건너뛰고 강제로 업데이트
       $SCRIPT_NAME -h

Examples:
  $SCRIPT_NAME --make-config
  $SCRIPT_NAME -t 'v1.2.3' -p both -r release -u
  $SCRIPT_NAME --config .distsConfig --jenkins-url http://jenkins.local --jenkins-job my-job --dry-run
EOF
}

loadConfig() {
    local configFile="$1"
    if [ -f "$configFile" ]; then
        echo "[$SCRIPT_NAME] Loading configuration from $configFile..."
        while IFS='=' read -r key value; do
            case "$key" in
                TAG) GIT_TAG_FULL="$value" ;;
                PLATFORM) INPUT_OS="$value" ;;
                RELEASE_TYPE) RELEASE_TYPE="$value" ;;
                UPDATE_VERSION_STRING) UPDATE_VERSION_STRING="$value" ;;
                BUILD_NUMBER) 
                    if [ -n "$value" ] && [ "$value" != "1" ]; then
                        BUILD_NUMBER="$value"
                    else
                        # 버전 문자열이 기본 형식(예: 1.0.1)인지 확인
                        if ! echo "$GIT_TAG_FULL" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
                            # 1.0.1.3 형식 체크
                            local version_number
                            version_number=$(echo "$GIT_TAG_FULL" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | cut -d'.' -f4)
                            if [ -n "$version_number" ]; then
                                BUILD_NUMBER="$version_number"
                            else
                                # 1.0.1(3) 또는 1.0.1 (3) 형식 체크
                                version_number=$(echo "$GIT_TAG_FULL" | grep -oE '\([0-9]+\)' | grep -oE '[0-9]+')
                                if [ -n "$version_number" ]; then
                                    BUILD_NUMBER="$version_number"
                                else
                                    BUILD_NUMBER="1"
                                fi
                            fi
                        else
                            BUILD_NUMBER="1"
                        fi
                    fi
                    ;;
                JENKINS_URL) JENKINS_URL="$value" ;;
                JENKINS_JOB_NAME) JENKINS_JOB_NAME="$value" ;;
                JENKINS_USER) JENKINS_USER="$value" ;;
                JENKINS_TOKEN) JENKINS_TOKEN="$value" ;;
            esac
        done < "$configFile"
    else
        printError "Configuration file not found: $configFile"
        exit 1
    fi

    echo "[$SCRIPT_NAME] Build number set to: $BUILD_NUMBER"
}

checkArguments() {
    local errors=()
    [ -z "$GIT_TAG_FULL" ] && errors+=("Missing required argument: --tag (-t)")
    [ -n "$JENKINS_URL" ] && [ -z "$JENKINS_JOB_NAME" ] && errors+=("If --jenkins-url is provided, --jenkins-job must also be specified.")
    [ -n "$JENKINS_JOB_NAME" ] && [ -z "$JENKINS_URL" ] && errors+=("If --jenkins-job is provided, --jenkins-url must also be specified.")

    if [ ${#errors[@]} -gt 0 ]; then
        for error in "${errors[@]}"; do
            printError "$error"
        done
        help
        exit 1
    fi

    # 플랫폼이 지정되지 않은 경우 알림 메시지만 출력하고 계속 진행
    if [ "$INPUT_OS" == "unknown" ]; then
        echo "[$SCRIPT_NAME] 경고: 플랫폼이 지정되지 않았습니다. (-p 옵션 없음)"
    fi

    echo "[$SCRIPT_NAME] Arguments validated successfully."
}

downloadJenkinsCLI() {
    local url="$1" jarFile="$2"
    local maxAge=86400  # 24 hours in seconds
    local tempFile
    tempFile="/tmp/jenkins-cli-${RANDOM}-${$}.jar.tmp"

    if [ -f "$jarFile" ]; then
        local fileAge=$(($(date +%s) - $(date -r "$jarFile" +%s)))
        if [ "$fileAge" -lt "$maxAge" ]; then
            echo "[$SCRIPT_NAME] Using existing Jenkins CLI jar (age: $((fileAge/3600)) hours)"
            return 0
        else
            echo "[$SCRIPT_NAME] Existing Jenkins CLI jar is older than 24 hours, downloading fresh copy..."
        fi
    else
        echo "[$SCRIPT_NAME] Jenkins CLI jar not found, downloading..."
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[$SCRIPT_NAME] DRY-RUN: Would download $url/jnlpJars/jenkins-cli.jar to $jarFile"
        return 0
    fi

    # Ensure cleanup of temp file on script exit or interrupt
    # trap 'rm -f "$tempFile"' EXIT
    
    show_spinner

    # Attempt download with timeout and basic error handling
    if curl -sSfL --connect-timeout 10 --max-time 60 -o "$tempFile" "$url/jnlpJars/jenkins-cli.jar"; then
        hide_spinner

        # Verify the downloaded file is a valid jar
        if file "$tempFile" | grep -q "Java archive data"; then
            mv "$tempFile" "$jarFile"
            echo "[$SCRIPT_NAME] Downloaded Jenkins CLI to $jarFile successfully."
            return 0
        else
            rm -f "$tempFile"
            printError "Downloaded file is not a valid Java archive."
            return 1
        fi
    else
        hide_spinner
        rm -f "$tempFile"
        printError "Failed to download Jenkins CLI jar. HTTP Error: $?"
        return 1
    fi
}

triggerJenkinsBuild() {
    local url="$1" jobName="$2" jarFile="$3"
    echo "[$SCRIPT_NAME] Triggering Jenkins build for job '$jobName'..."
    
    # Jenkins 인증 정보가 없는 경우 사용자에게 요청
    if [ -z "$JENKINS_USER" ] || [ -z "$JENKINS_TOKEN" ]; then
        read -rp "[$SCRIPT_NAME] Jenkins 사용자 ID를 입력하세요: " JENKINS_USER
        read -rsp "[$SCRIPT_NAME] Jenkins 토큰을 입력하세요: " JENKINS_TOKEN
        echo  # 새 줄 추가
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[$SCRIPT_NAME] DRY-RUN: Would run: java -jar $jarFile -s $url/ -auth '$JENKINS_USER:****' build $jobName"
        return 0
    fi

    show_spinner

    if java -jar "$jarFile" -s "$url/" -auth "$JENKINS_USER:$JENKINS_TOKEN" build "$jobName"; then
        hide_spinner
        echo "[$SCRIPT_NAME] Jenkins build for job '$jobName' triggered successfully."
    else
        hide_spinner
        printError "Failed to trigger Jenkins build."
        exit 1
    fi
}

processGitChanges() {
    # 변경사항 확인
    if [ -z "$(git status --porcelain)" ]; then
        echo "[$SCRIPT_NAME] No changes to commit."
        return 0
    fi
    echo "[$SCRIPT_NAME] Processing Git changes..."
    
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[$SCRIPT_NAME] DRY-RUN: Would stage all changes, commit them, and push to remote."
        echo "[$SCRIPT_NAME] DRY-RUN: Commit message: 'Update version $GIT_TAG_FULL for $INPUT_OS platform.'"
        return 0
    fi
    
    if confirm "There's uncommitted changes. Do you want to commit?"; then
        git add . || {
            printError "Failed to stage changes."
            exit 1
        }
        git commit -m "Update version $GIT_TAG_FULL for $INPUT_OS platform." || {
            printError "Failed to commit changes."
            exit 1
        }
        git push || {
            printError "Failed to push changes to remote."
            exit 1
        }
        echo "[$SCRIPT_NAME] Changes pushed to remote successfully."
    else
        echo "[$SCRIPT_NAME] Commit & push operation cancelled by user."
        exit 0
    fi
}

processGitTagging() {
    echo "[$SCRIPT_NAME] Processing Git tagging..."
    if git tag | grep -q "$GIT_TAG_FULL"; then
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "[$SCRIPT_NAME] DRY-RUN: Tag $GIT_TAG_FULL exists. Would delete it locally and from remote."
            return 0
        fi
        
        if confirm "Tag $GIT_TAG_FULL already exists. Do you want to delete and recreate it?"; then
            git tag -d "$GIT_TAG_FULL" || {
                printError "Failed to delete local tag."
                exit 1
            }
            git push --delete origin "$GIT_TAG_FULL" || {
                printError "Failed to delete remote tag."
                exit 1
            }
            echo "[$SCRIPT_NAME] Tag $GIT_TAG_FULL deleted locally and from remote."
        else
            echo "[$SCRIPT_NAME] Tag operation cancelled by user."
            exit 0
        fi
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[$SCRIPT_NAME] DRY-RUN: Would create tag $GIT_TAG_FULL and push it to remote."
        return 0
    fi
    
    git tag -a "$GIT_TAG_FULL" -m "Release: $GIT_TAG_FULL" || {
        printError "Failed to create tag."
        exit 1
    }
    git push origin "$GIT_TAG_FULL" || {
        printError "Failed to push tag to remote."
        exit 1
    }
    echo "[$SCRIPT_NAME] Tag $GIT_TAG_FULL created and pushed."
}

updateVersion() {
    local platform="$1"
    if [[ "$platform" == "ios" || "$platform" == "both" ]]; then
        local IOS_FILE
        IOS_FILE=$(find . -name 'project.pbxproj' -not -path "*/Pods/*" -not -path "*/node_modules/*")
        if [ -f "$IOS_FILE" ]; then
            local oldMarketingVersion oldCurrentProjectVersion
            oldMarketingVersion=$(grep 'MARKETING_VERSION =' "$IOS_FILE" | awk '{print $3}' | tr -d ';')
            oldCurrentProjectVersion=$(grep 'CURRENT_PROJECT_VERSION =' "$IOS_FILE" | awk '{print $3}' | tr -d ';')
            
            if checkVersionUpdate "$MARKET_VERSION" "$oldMarketingVersion" "iOS"; then
                if [ "$DRY_RUN" -eq 1 ]; then
                    echo "[$SCRIPT_NAME] DRY-RUN: Would update iOS file:"
                    echo "[$SCRIPT_NAME] DRY-RUN:   Replace MARKETING_VERSION = $oldMarketingVersion; with MARKETING_VERSION = $MARKET_VERSION;"
                    echo "[$SCRIPT_NAME] DRY-RUN:   Replace CURRENT_PROJECT_VERSION = $oldCurrentProjectVersion; with CURRENT_PROJECT_VERSION = $BUILD_NUMBER;"
                else
                    sed -i "s/MARKETING_VERSION = $oldMarketingVersion;/MARKETING_VERSION = $MARKET_VERSION;/" "$IOS_FILE"
                    sed -i "s/CURRENT_PROJECT_VERSION = $oldCurrentProjectVersion;/CURRENT_PROJECT_VERSION = $BUILD_NUMBER;/" "$IOS_FILE"
                    echo "[$SCRIPT_NAME] Updated iOS version in $IOS_FILE"
                fi
            else
                UPDATE_VERSION_STRING=0
            fi
        fi
    fi

    if [[ "$platform" == "android" || "$platform" == "both" ]]; then
        local AOS_FILE
        AOS_FILE=$(find . -name 'build.gradle' -exec grep -lir 'com.android.application' {} + | grep -v 'node_modules')
        if [ -f "$AOS_FILE" ]; then
            local oldVersionName oldVersionCode parsedTagVersion
            oldVersionName=$(grep 'versionName' "$AOS_FILE" | awk -F\" '{print $2}')
            oldVersionCode=$(grep 'versionCode' "$AOS_FILE" | awk '{print $2}')
            parsedTagVersion=$(getParsedVersion "$GIT_TAG_FULL")

            if checkVersionUpdate "$parsedTagVersion" "$oldVersionName" "Android"; then
                if [ "$DRY_RUN" -eq 1 ]; then
                    echo "[$SCRIPT_NAME] DRY-RUN: Would update Android file:"
                    echo "[$SCRIPT_NAME] DRY-RUN:   Replace versionName \"$oldVersionName\" with versionName \"$parsedTagVersion\""
                    echo "[$SCRIPT_NAME] DRY-RUN:   Replace versionCode $oldVersionCode with versionCode $BUILD_NUMBER"
                else
                    sed -i "s/versionName \"$oldVersionName\"/versionName \"$parsedTagVersion\"/" "$AOS_FILE"
                    sed -i "s/versionCode $oldVersionCode/versionCode $BUILD_NUMBER/" "$AOS_FILE"
                    echo "[$SCRIPT_NAME] Updated Android version in $AOS_FILE"
                fi
            else
                UPDATE_VERSION_STRING=0
            fi
        fi
    fi
}

makeConfig() {
    local configFile=".distsConfig"
    
    echo "[$SCRIPT_NAME] 설정 파일 생성을 시작합니다..."
    
    # 기존 파일 확인
    if [ -f "$configFile" ]; then
        if ! confirm "설정 파일이 이미 존재합니다. 덮어쓰시겠습니까?"; then
            echo "[$SCRIPT_NAME] 설정 파일 생성이 취소되었습니다."
            exit 0
        fi
    fi
    
    # 사용자 입력 받기
    read -rp "[$SCRIPT_NAME] Git 태그를 입력하세요 (예: v1.0.0): " tag
    read -rp "[$SCRIPT_NAME] 플랫폼을 입력하세요 (ios/android/both): " platform
    read -rp "[$SCRIPT_NAME] 릴리스 타입을 입력하세요 (release/develop): " releaseType
    read -rp "[$SCRIPT_NAME] Jenkins URL을 입력하세요 (선택사항): " jenkinsUrl
    read -rp "[$SCRIPT_NAME] Jenkins Job 이름을 입력하세요 (선택사항): " jenkinsJob
    read -rp "[$SCRIPT_NAME] Jenkins 사용자 ID를 입력하세요 (선택사항): " jenkinsUser
    read -rp "[$SCRIPT_NAME] Jenkins API 토큰을 입력하세요 (선택사항): " jenkinsToken
    read -rp "[$SCRIPT_NAME] 버전 업데이트를 하시겠습니까? (1: 예, 0: 아니오): " updateVersion
    
    # Jenkins URL에서 따옴표 제거
    jenkinsUrl=$(echo "$jenkinsUrl" | sed -e 's/^["\x27]*//' -e 's/["\x27]*$//')
    
    # 설정 파일 생성
    cat > "$configFile" << EOF
TAG=$tag
PLATFORM=$platform
RELEASE_TYPE=$releaseType
UPDATE_VERSION_STRING=$updateVersion
BUILD_NUMBER=1
JENKINS_URL=$jenkinsUrl
JENKINS_JOB_NAME=$jenkinsJob
JENKINS_USER=$jenkinsUser
JENKINS_TOKEN=$jenkinsToken
EOF
    
    echo "[$SCRIPT_NAME] 설정 파일이 생성되었습니다: $configFile"
    exit 0
}

# Utility functions 섹션에 추가
checkVersionUpdate() {
    local parsedTagVersion="$1"
    local currentVersion="$2"
    local platform="$3"
    
    if [ "$UPDATE_VERSION_STRING_FORCE" -eq 1 ]; then
        return 0
    fi
    
    local versionComparison
    versionComparison=$(vercomp "$parsedTagVersion" "$currentVersion")
    
    if [ "$versionComparison" -ge 2 ]; then
        echo "[$SCRIPT_NAME] $platform: 새 버전($parsedTagVersion)이 현재 버전($currentVersion)보다 낮습니다."
        return 1
    fi
    return 0
}

shouldUpdateVersion() {
    local HAS_IOS_FILE HAS_AOS_FILE SHOULD_UPDATE=0
    local parsedTagVersion
    
    # iOS와 Android 파일 존재 여부 확인
    HAS_IOS_FILE=$(find . -name 'project.pbxproj' -not -path "*/Pods/*" -not -path "*/node_modules/*" -print -quit)
    HAS_AOS_FILE=$(find . -name 'build.gradle' -exec grep -l 'com.android.application' {} + 2>/dev/null | grep -v 'node_modules' | head -n1)
    
    # 태로젝트 파일이 하나도 없으면 early return
    if [ -z "$HAS_IOS_FILE" ] && [ -z "$HAS_AOS_FILE" ]; then
        return 1
    fi
    
    parsedTagVersion=$(getParsedVersion "$GIT_TAG_FULL")
    
    if [ -n "$HAS_IOS_FILE" ]; then
        local oldMarketingVersion
        oldMarketingVersion=$(grep 'MARKETING_VERSION =' "$HAS_IOS_FILE" | awk '{print $3}' | tr -d ';' | head -n1)
        if [ -n "$oldMarketingVersion" ]; then
            checkVersionUpdate "$parsedTagVersion" "$oldMarketingVersion" "iOS" && SHOULD_UPDATE=1
        fi
    fi
    
    if [ -n "$HAS_AOS_FILE" ]; then
        local oldVersionName
        oldVersionName=$(grep 'versionName' "$HAS_AOS_FILE" | awk -F'"' '{print $2}' | head -n1)
        if [ -n "$oldVersionName" ]; then
            checkVersionUpdate "$parsedTagVersion" "$oldVersionName" "Android" && SHOULD_UPDATE=1
        fi
    fi
    
    [ "$SHOULD_UPDATE" -eq 1 ]
    return $?
}

# Default variables
UPDATE_VERSION_STRING=0
DRY_RUN=0
CONFIG_FILE=".distsConfig"
MARKET_VERSION=""
BUILD_NUMBER=1
JENKINS_URL=""
JENKINS_JOB_NAME=""
JENKINS_JAR="/tmp/jenkins-cli.jar"
INPUT_OS="unknown"
JENKINS_USER=""
JENKINS_TOKEN=""
UPDATE_VERSION_STRING_FORCE=0

# Argument parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        --make-config)
            makeConfig
            ;;
        -p|--platform)
            if [[ "$2" =~ ^(ios|android|both)$ ]]; then
                INPUT_OS="$2"
            else
                INPUT_OS="unknown";
            fi
            shift 2
            ;;
        -t|--tag) GIT_TAG_FULL="$2"; shift 2 ;;
        -c|--config) CONFIG_FILE="$2"; shift 2 ;;
        -r|--release-type) RELEASE_TYPE="$2"; shift 2 ;;
        -u|--update-version-string) UPDATE_VERSION_STRING=1; shift ;;
        -uf|--update-version-string-forcefully) 
            UPDATE_VERSION_STRING=1
            UPDATE_VERSION_STRING_FORCE=1
            shift 
            ;;
        --jenkins-url) JENKINS_URL="$2"; shift 2 ;;
        --jenkins-job) JENKINS_JOB_NAME="$2"; shift 2 ;;
        --jenkins-user) JENKINS_USER="$2"; shift 2 ;;
        --jenkins-token) JENKINS_TOKEN="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) help; exit 0 ;;
        *) printError "Unknown option: $1"; help; exit 1 ;;
    esac
done

# Main process
if [ -f "$CONFIG_FILE" ]; then
    loadConfig "$CONFIG_FILE"
    echo "[$SCRIPT_NAME] Configuration loaded from $CONFIG_FILE"
else
    echo "[$SCRIPT_NAME] No configuration file found at $CONFIG_FILE, proceeding with command line arguments..."
fi

checkArguments

if [ "$UPDATE_VERSION_STRING" -eq 0 ]; then
    if shouldUpdateVersion; then
        UPDATE_VERSION_STRING=1
        [ "$INPUT_OS" == "unknown" ] && INPUT_OS="both"
        echo "[$SCRIPT_NAME] 프로젝트 파일이 감지되어 자동으로 버전 업데이트를 활성화합니다. (플랫폼: $INPUT_OS)"
    fi
fi

if [ "$UPDATE_VERSION_STRING" -eq 1 ]; then
    updateVersion "$INPUT_OS"
fi

processGitChanges
processGitTagging

if [ -n "$JENKINS_URL" ] && [ -n "$JENKINS_JOB_NAME" ]; then
    downloadJenkinsCLI "$JENKINS_URL" "$JENKINS_JAR"
    triggerJenkinsBuild "$JENKINS_URL" "$JENKINS_JOB_NAME" "$JENKINS_JAR"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "[$SCRIPT_NAME] DRY-RUN: All operations simulated successfully."
else
    echo "[$SCRIPT_NAME] All operations completed successfully."
fi
