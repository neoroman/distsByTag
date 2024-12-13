# distsByTag.sh

`distsByTag.sh`는 모바일 플랫폼(iOS/Android)의 버전 관리를 간소화하고, Git 태깅 및 버전 관리와 통합하며, Jenkins 빌드 작업을 트리거하도록 설계된 쉘 스크립트입니다. 안전한 시뮬레이션을 위한 dry-run 지원을 포함합니다.

## 주요 기능
- iOS 및 Android 버전 문자열 업데이트
- Git 통합:
  - 변경사항 커밋 및 푸시
  - 태그 생성, 업데이트, 삭제 (로컬 및 원격)
- Jenkins 통합:
  - Jenkins CLI 다운로드
  - Jenkins 작업 트리거
- .distsConfig 파일을 통한 구성 가능
- 실제 변경 없이 작업을 시뮬레이션하는 dry-run 모드

---

## 요구사항
- bash (버전 4.0 이상)
- curl (Jenkins CLI 다운로드용)
- git
- java (Jenkins CLI용)

---

## 사용법

```bash
./distsByTag.sh [옵션]
```

## 옵션
| 옵션 | 설명 |
|--------|-------------|
| `-t, --tag <tag>` | 사용할 태그 지정. 필수. |
| `-p, --platform <platform>` | 플랫폼 지정: ios, android, 또는 both. 기본값은 both. |
| `-c, --config <file>` | 지정된 구성 파일에서 옵션 로드. 기본값은 .distsConfig. |
| `-r, --release-type <type>` | 릴리스 타입 지정 (release 또는 develop). |
| `--update-version-string` | iOS 및 Android 버전 문자열 업데이트 활성화. |
| `--jenkins-url <url>` | Jenkins 서버 URL 지정. |
| `--jenkins-job <job-name>` | 트리거할 Jenkins 작업 이름 지정. |
| `--dry-run` | 변경 없이 모든 작업 시뮬레이션. |
| `-h, --help` | 도움말 정보 표시. |

---

## 구성 파일

구성 파일(.distsConfig)을 사용하여 스크립트의 옵션을 미리 정의할 수 있습니다. 반복적인 명령줄 인수를 피하기 위해 사용하세요.

### .distsConfig 예시
```ini
TAG=v1.2.3
PLATFORM=both
RELEASE_TYPE=release
UPDATE_VERSION_STRING=1
BUILD_NUMBER=123
JENKINS_URL=http://jenkins.local
JENKINS_JOB_NAME=my-job
DRY_RUN=0
GIT_PUSH=1
```

## 사용 예시

### 전체 실행
버전 문자열 업데이트, Git 태그 생성, 변경사항 푸시 및 Jenkins 작업 트리거:
```bash
./distsByTag.sh -t "v1.2.4" -p both --update-version-string --jenkins-url http://jenkins.local --jenkins-job my-job
```

### Dry-Run 모드
변경 없이 모든 작업 시뮬레이션:
```bash
./distsByTag.sh --config .distsConfig --dry-run
```

### Jenkins 통합만 실행
버전 업데이트나 Git 작업 없이 Jenkins 작업만 트리거:
```bash
./distsByTag.sh --jenkins-url http://jenkins.local --jenkins-job my-job
```

---

## 작업 흐름

### 1단계: 인수 검증
모든 필수 인수와 구성이 제공되었는지 확인합니다.

### 2단계: 버전 업데이트
- iOS:
  - Info.plist 파일의 CFBundleShortVersionString 업데이트
  - project.pbxproj의 MARKETING_VERSION 업데이트
  - BUILD_NUMBER가 제공된 경우 CURRENT_PROJECT_VERSION 업데이트
- Android:
  - build.gradle 파일의 versionName 업데이트
  - BUILD_NUMBER가 제공된 경우 versionCode 업데이트

### 3단계: Git 처리
- 변경사항 스테이징
- 의미 있는 메시지로 변경사항 커밋
- 원격 저장소에 변경사항 푸시
- Git 태그 처리:
  - 기존 태그 삭제 (로컬 및 원격)
  - 새 태그 생성 및 푸시

### 4단계: Jenkins 통합
- Jenkins CLI 다운로드
- 지정된 Jenkins 작업 트리거

---

## 개발 참고사항

### 오류 처리
- 커밋되지 않은 변경사항이 감지되면 실행 중지
- Jenkins CLI 다운로드 및 작업 트리거 확인
- 필수 도구(git, curl, java) 존재 여부 확인
- 구성 파일 유효성 검사
- 태그 형식 검증

### Dry-Run 모드
- 파일, Git 저장소 또는 Jenkins 작업을 수정하지 않고 수행될 모든 작업 출력

---

## 트러블슈팅

### 일반적인 문제
1. Git 태그 충돌
   - 해결: --force 옵션으로 기존 태그 덮어쓰기
   
2. Jenkins 연결 실패
   - Jenkins URL 접근성 확인
   - Jenkins CLI 권한 확인
   
3. 버전 파일 찾기 실패
   - 프로젝트 구조 확인
   - 파일 경로 설정 검증

---

## 라이선스

이 스크립트는 MIT 라이선스로 배포됩니다. 자유롭게 수정하고 공유하세요.

---

## 기여

기여를 환영합니다! 스크립트를 개선하기 위한 이슈나 풀 리퀘스트를 제출해주세요.


---

## 연락처

문의사항이나 버그 리포트는 아래 연락처로 보내주세요:

- 이메일: support@example.com
- 이슈 트래커: https://github.com/example/project/issues
