# MyDays — iOS Todo App

## 개요
- 앱 이름: MyDays. 목표: iOS/Android 마켓 출시.
- 1단계: iPhone + iPad (Swift + SwiftUI)
- 2단계: Catalyst (Mac)
- 3단계: Android (Java + XML Layout)
- 동기화: 1~2단계 iCloud (CloudKit). 3단계 추가 시 Firebase.

## 기술 스택
- Swift 5 + **SwiftUI** (UIKit Programmatic 도입 자제, Storyboard는 LaunchScreen만)
- Core Data + `NSPersistentCloudKitContainer`
- **Deployment Target: iOS 17.6**
- Bundle ID: `io.snapplay.MyDays` / Team: `W42FK7WLJ9`
- CloudKit Container: `iCloud.io.snapplay.MyDays`
- Background Modes: `fetch`, `processing`, `remote-notification`

## 데이터 모델 (`MyDays.xcdatamodeld`)
모든 attribute는 optional, 양방향 inverse 필수 (CloudKit 호환).

- **Item**: title, notes, kind, priority, status, isSomeday, startDate, dueDate, completedAt, sortOrder, createdAt, updatedAt
  - self-relation: parent/children (3단계 계층은 앱 로직에서 강제)
  - 관계: category, tags, recurrenceRule, reminders, completions, events
- **Category** / **Tag** (현재 colorHex는 단일 색 유지) / **RecurrenceRule** / **RoutineCompletion** (Streak용) / **Reminder**
- **ItemEvent** (활동 로그 인프라): timestamp, action, itemTitle(snapshot), note, item(Nullify) — Item 삭제돼도 보존

Enum 매핑은 `Models/ModelEnums.swift`:
- ItemKind / Priority / Status / Frequency / ReminderAnchor / ItemAction

## 폴더 구조
```
MyDays/MyDays/
├── MyDaysApp.swift              @main App
├── Info.plist / MyDays.entitlements / MyDays.xcdatamodeld
├── Models/
│   ├── ModelEnums.swift
│   ├── Item+Helpers.swift       itemKind/Priority/Status, daysUntilDue, make()
│   └── ItemEvent+Helpers.swift  log(_:on:in:note:)
├── Services/
│   └── PersistenceController.swift   shared singleton, CloudKit 스택
└── Views/
    ├── RootView.swift                TabView: 오늘/목록/보관함/설정
    ├── TodayView.swift               부모(date state) + TodayList(자식 fetch)
    ├── ListView.swift                전체 + 완료 토글 (eye/eye.slash)
    ├── ArchiveView.swift             isSomeday=YES 항목
    ├── SettingsView.swift            동기화/활동/정보
    ├── ActivityLogView.swift         시계열 ItemEvent 표시
    ├── AddItemView.swift             입력/편집/삭제 통합 시트
    ├── ItemRow.swift                 체크박스 + 제목 + D-day + priority 배지
    ├── DatePickerSheet.swift         X/V + "날짜 없음으로 설정"
    └── ItemSheetMode.swift           enum new(baseDate:) / edit(Item)
```

## 구현 완료 (Phase 1)
**탭바 4개** — 오늘 / 목록 / 보관함 / 설정 (이 순서)

**오늘 화면**
- 일자 이동: 좌우 chevron toolbar 버튼
- 오늘로 점프: chevron 옆 "오늘"/"Today" 버튼 (그제 이전이면 우측, 모레 이후면 좌측). 어제/오늘/내일은 표시 안 함
- iOS 26+에선 `ToolbarSpacer(.fixed, …)`로 점프 버튼과 chevron 분리. iOS 17~25는 capsule로 묶임 (fallback)
- 섹션 순서: 진행 중 Not Todo / 마감 / 진행 중 / 시작 / 루틴 (Not Todo·루틴은 placeholder)
- "시작" 섹션 predicate에 `(dueDate == nil OR dueDate >= 다음날)` 조건 — 시작=마감 같은 날은 "마감" 섹션에만 표시
- "진행 중" 섹션: `startDate < startOfDay AND dueDate >= 다음날`

**보관함** — `isSomeday=YES AND status==0` fetch
**목록** — 진행 중 + 완료 토글 (default 숨김), navigationTitle 없음 (탭이 이미 컨텍스트)

**AddItemView (입력/편집/삭제 통합)**
- chips 라인 (가로 스크롤): `오늘 / 내일 / 모레 / 날짜없음 / 기간설정`
- 단일 모드 (default): 시작 chip 1개, `startDate = dueDate` 자동 동기
- 기간 모드 (기간설정 ON, 또는 편집 시 두 날짜 다르면 자동): chip 2개 + `~` 구분자
- 날짜 chip 포맷: 올해는 `M.d (E)`, 다른 해는 `yyyy.M.d (E)`. 비어있으면 회색 "날짜 없음"
- DatePickerSheet에 "날짜 없음으로 설정" destructive 버튼 (취소/확인은 X/V)
- 마감일 default = baseDate + 1
- 자동 포커스 120ms delay (편집 모드에선 비활성)
- 삭제 확인은 화면 중앙 **alert**

**ItemRow** — 체크박스 + 제목 + D-day(우측 같은 줄) + priority 배지(상=빨강, 하=파랑, 중/없음은 배지 없음). 완료 시 회색 처리(취소선 없음). 행 탭 = 편집

**+ FAB** — 우측 하단 floating circle. baseDate를 sheet에 전달
- TodayView: baseDate = displayedDate
- ArchiveView: baseDate = nil (someday)
- ListView: baseDate = nil

**활동 로그 (`ItemEvent`)**
- 자동 기록 지점: AddItemView.save (.created/.updated), AddItemView.deleteItem (.deleted), ItemRow.toggleDone (.completed/.uncompleted)
- itemTitle은 스냅샷 — 원본 Item 삭제돼도 표시 가능
- Settings → 활동 로그 → 시계열 역순 List (timestamp desc)

## 미구현 (다음 후보)
- 루틴(반복) 입력 + Streak 표시
- Not Todo 입력 + 남은 시간 표시
- 카테고리·태그 관리 UI + 필터
- 3단계 계층 구조 (parent/children)
- Local Notification (알림 + 권한)
- WidgetKit (오늘 할일, Not Todo 위젯)
- Week View / Month View / 달력 뷰
- 목록·보관함의 카테고리 필터

## 디자인 / 코드 가이드라인
- **꼭 필요한 기능만, 최대한 단순화. 입력 편의성 우선.**
- 사용자 멘탈 모델 우선. 데이터 모델은 백킹 — 예: 단일 날짜 모드 ↔ 기간 모드 분리.
- 새 Core Data 변경: 모든 attribute optional + 양방향 inverse + Nullify/Cascade 신중히 결정 (CloudKit 호환)
- 상태 변경 지점에서 일관되게 `ItemEvent.log(_:on:in:)` 호출
- 한국어/영어 분기는 `Locale.preferredLanguages.first?.hasPrefix("ko")` 사용. `Locale.current.language.languageCode`는 실기기에서 신뢰 X
- iOS 26+ API는 `#available(iOS 26.0, *)` 가드 (deployment 17.6 유지)
- UIKit Programmatic 도입 자제. 정말 필요할 때만 `UIViewRepresentable`
- 회사·집 동기화는 git remote 사용 (이 파일도 같이 commit)

## 알려진 제약 / 노이즈
- **첫 키보드 활성화 ~5초**: iOS 시스템의 텍스트 입력 세션 초기화 비용. 워밍업 트릭은 부작용(키보드 잠시 떠보임)이 있어 적용 안 함.
- **iOS 17~25 toolbar capsule**: 같은 placement의 ToolbarItem들이 단일 capsule로 묶이는 시스템 디자인. `ToolbarSpacer`는 iOS 26+ only.
- 콘솔 노이즈 (`remoteTextInputSession…`, `Gesture: System gesture gate timed out`, `Result accumulator timeout` 등)는 iOS 자체 이슈로 무시.

## 사용자 컨텍스트
- 익숙: Swift, Java. native 개발 선호 (크로스플랫폼 X).
- 응답 스타일: 짧고 빠른 결정. UX 디테일에 민감.
- 진행 방식: 기능 단위로 만들고 → 실기기에서 확인 → 짧은 피드백 → 반영.
- 메모리 시스템은 머신 로컬에 저장됨. 회사(맥미니)와 집(맥북) 양쪽에서 작업하므로 이 CLAUDE.md가 컨텍스트 동기화의 1순위.
