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

### Item
- 일반: title, **notes**(작성 시 메모), **comment**(완료/종료 후 코멘트), kind, priority, status, isSomeday, startDate, dueDate, completedAt, sortOrder, createdAt, updatedAt
- 시간대: **startTimeOfDay**, **dueTimeOfDay** (오전/오후/저녁/none, 단일 모드면 둘 동기)
- self-relation: parent/children (3단계 계층은 앱 로직에서 강제)
- 관계: category, tags, recurrenceRule, reminders, completions, events

### RecurrenceRule
- frequency, interval, weekdayMask, **dayOfMonthMask (Int64, bit 0~30=일자, bit 31=말일)**, **monthMask (Int16, 0=모든 월)**, countPerWeek (legacy), dayOfMonth (legacy), startDate (legacy, 미사용), endDate (legacy, 미사용)
- **Item.startDate를 anchor로 사용**, Item.dueDate를 반복 종료일로 사용
- helper: `selectedWeekdays/Days/Months`, `includesLastDay`, `occurs(on:startDate:endDate:)`, `nextOccurrence(after:startDate:endDate:)`, `make(in:)`

### RoutineCompletion
- id, date, done, item — 각 발생일의 완료 기록. Streak 계산 기반.

### Category / Tag / Reminder
- Category: name, colorHex, iconName, sortOrder
- Tag: name, colorHex(현재 단일 색)
- Reminder: fireDate, offsetMin, anchor, repeats

### ItemEvent (활동 로그)
- timestamp, action, itemTitle(snapshot), note, item(Nullify) — Item 삭제돼도 보존

### Enum 매핑 (`Models/ModelEnums.swift`)
- **ItemKind**: 0=todo, 1=notTodo
- **Priority**: 0=none, 1=medium, 2=high, 3=low. `displayName` localized
- **Status**: 0=pending, 1=done, **2=deleted (was cancelled, 향후 소프트삭제용)**, **3=failed (NTD 사용자 종료)**
- **Frequency**: 0=daily, 1=weekly, 2=monthly (3=weekdays, 4=weekend, 5=weeklyCount는 legacy, 미사용)
- **TimeOfDay**: 0=none, 1=morning, 2=afternoon, 3=evening
- **ItemAction**: 0~7 (created/updated/completed/uncompleted/cancelled[legacy]/restored/deleted/**failed**). 모두 localized

## 폴더 구조
```
MyDays/MyDays/
├── MyDaysApp.swift                  @main App
├── Info.plist / MyDays.entitlements / MyDays.xcdatamodeld
├── Localizable.xcstrings            String Catalog (ko + en, ja/zh 추후)
├── Models/
│   ├── ModelEnums.swift             Priority/Status/Frequency/TimeOfDay/ItemAction/ItemKind
│   ├── Item+Helpers.swift           daysUntilDue, isOverdue, isCompletedForDate, currentStreak, daysUntilNextOccurrence, completeExpiredRoutines, make
│   ├── ItemEvent+Helpers.swift      log(_:on:in:note:)
│   ├── RecurrenceRule+Helpers.swift  itemFrequency, selectedWeekdays/Days/Months, includesLastDay, occurs, nextOccurrence, make
│   └── RecurrenceConfig.swift       Sheet ↔ Rule 임시 struct (apply(to:), init(from:))
├── Services/
│   └── PersistenceController.swift  shared singleton, CloudKit 스택
└── Views/
    ├── RootView.swift               TabView + 앱 시작/foreground 시 completeExpiredRoutines 호출
    ├── TodayView.swift              부모(date state) + TodayList(자식 fetch)
    ├── ListView.swift               전체 + 완료 토글 (eye/eye.slash)
    ├── ArchiveView.swift            isSomeday=YES 항목
    ├── SettingsView.swift           동기화/활동/정보
    ├── ActivityLogView.swift        시계열 ItemEvent 표시
    ├── AddItemView.swift            입력/편집/삭제 통합 시트
    ├── RecurrenceSheet.swift        반복 입력 시트
    ├── ItemRow.swift                체크박스/아이콘 + 제목 + statusIcons + 메모 (3줄 레이아웃)
    ├── DatePickerSheet.swift        X/V + 시간대 chips + 지우기
    └── ItemSheetMode.swift          enum new(baseDate:) / edit(Item)
```

## 구현 완료 (Phase 1)

### 탭바 4개 — 오늘 / 목록 / 보관함 / 설정

### 오늘 화면
- 일자 이동: 좌우 chevron toolbar 버튼. nav title: 오늘/내일/어제/M.d (E)
- "오늘로 점프" 버튼 (그제 이전이면 우측, 모레 이후면 좌측; 어제/오늘/내일은 표시 X). 한국어 "오늘" / 영어 "Now"
- iOS 26+에선 `ToolbarSpacer(.fixed, …)`로 점프 버튼과 chevron 분리. iOS 17~25는 capsule로 묶임 (fallback)
- 섹션 순서: **진행 중 Not Todo** / 마감 / 진행 중 / 시작 / **루틴**
  - 진행 중 Not Todo: placeholder (미구현)
  - 마감/진행 중/시작 predicate에 `AND recurrenceRule == nil` 추가 — 루틴은 루틴 섹션에만
  - 루틴 섹션은 `recurrenceRule != nil AND status != 2` fetch + view에서 `rule.occurs(on:startDate:endDate:)` 필터

### 보관함 — `isSomeday=YES AND status==0`
### 목록 — 진행 중 + 완료 토글 (default 숨김). `isSomeday=NO`로 someday 제외

### AddItemView (입력/편집/삭제 통합)
- chips 라인 (가로 스크롤): `오늘 / 내일 / 모레 / 날짜없음 / 기간설정`
- 단일 모드 (default): 시작 chip 1개, `startDate=dueDate` 자동 동기
- 기간 모드 (기간설정 ON, 또는 편집 시 두 날짜 다르면 자동): chip 2개 + `~`
- 날짜 chip 포맷: 짧은 `M.d (E)` 또는 `yyyy.M.d (E)` (다른 해). 시간대 표시
- DatePickerSheet: 캘린더 + 시간대 chips (오전/오후/저녁/미설정) + "지우기" 버튼. iOS sheet hosting의 nav bar는 `.toolbar(.hidden, for: .navigationBar)`로 숨김. detent는 `.height(480)` 고정
- 마감일 default = baseDate + 1
- 자동 포커스 120ms (편집 모드 비활성)
- 삭제 확인 alert (중앙)
- **반복(Recurrence) Section**: row 전체 탭 가능 (contentShape Rectangle)
  - 동적 요약 텍스트: Daily "매일" / "2일마다", Weekly "매주 화·목", Monthly "매월 1·15·말일" / "1·15·말일 of Jun·Dec" / "5 days/month"
  - 한국어: 일자 = "1일·15일", 영어: ordinal = "1st·15th"
  - 반복 시트 onSave 시 시작일 자동 ON (없으면 오늘)
- **Priority**: 깃발 아이콘 4개 (가로). 색상은 선택 무관 항상 표시 (red/orange/blue/secondary). 선택 시 회색 동그라미 배경. 새 항목 default = **none**
- 입력 폼에 `.scrollDismissesKeyboard(.interactively)` + `simultaneousGesture(TapGesture)` — 빈 영역 탭으로 키보드 dismiss

### RecurrenceSheet
- Frequency picker (segmented): 매일/매주/매월
- Daily: Stepper로 interval (1~365)
- Weekly: 요일 7개 멀티 (시스템 firstWeekday 시작). `shortWeekdaySymbols` 사용 (영어 Tue/Thu 구분 OK)
- Monthly: 1~31 grid + 말일 toggle + 1~12월 grid
- 기간(start/end) 입력은 **없음** — Item.startDate/dueDate 사용
- 편집 시 "반복 제거" destructive 버튼

### ItemRow (3줄 레이아웃)
- 줄 1: leadingControl + 제목(1줄, truncation tail) + 시간대(caption2) + D-day(caption, isOverdue면 red)
- 줄 2: 메모(notes, caption secondary, 1줄) — 옵션
- 줄 3: statusIcons (깃발/말풍선/🔥streak) — 항목 있을 때만
- leadingControl 분기:
  - 일반 todo: 체크박스 (status .pending↔.done 토글)
  - routine + routineCheckable=true (TodayView/ArchiveView): 체크박스 (그 날짜의 RoutineCompletion 토글)
  - routine + routineCheckable=false (ListView): **`repeat` 아이콘** (회색, 클릭 X)
- D-day 분기:
  - 일반 todo: `daysUntilDue`
  - routine + showRoutineDday=true (ListView): `daysUntilNextOccurrence`. 색상 항상 secondary (isOverdue는 routine에 적용 안 함)
  - routine + showRoutineDday=false (TodayView/ArchiveView): 표시 X
- 행 탭 = 편집 시트 (체크박스/leadingControl 영역 제외)

### 활동 로그 (ItemEvent)
- 자동 기록: AddItemView.save (.created/.updated), AddItemView.deleteItem (.deleted), ItemRow.toggleDone (.completed/.uncompleted)
- itemTitle은 스냅샷 — 원본 삭제돼도 표시 가능
- Settings → 활동 로그 → 시계열 역순 List

### 루틴 자동 종료
- RootView `.task` + `scenePhase == .active` 시 `Item.completeExpiredRoutines(in:)` 호출
- predicate: `recurrenceRule != nil AND status == 0 AND dueDate != nil AND dueDate < today`
- 매칭 → status = .done, completedAt = now, ItemEvent.log(.completed)

### Localization (B-2: key-based, all in catalog)
- `Localizable.xcstrings` (Source language `en`. `knownRegions = [en, Base, ko]`. developmentRegion = en)
- 키 네이밍: dot.case (예: `tab.today`, `add.section.recurrence`, `recurrence.summary.weekly_list`)
- SwiftUI `Text("key")`는 자동 LocalizedStringKey. 사용자 입력(Item.title 등)은 `Text(verbatim:)` 또는 String 분기
- 한국어/영어 분기 (코드): `Locale.preferredLanguages.first?.hasPrefix("ko")` 사용. 대표 케이스 = 매월 일자 포맷 (한국어 "1일" / 영어 NumberFormatter.ordinal "1st")
- DateFormatter는 `setLocalizedDateFormatFromTemplate("MdE")` 같이 로케일 자동
- 일본어/중국어는 catalog에 번역만 추가하면 됨

## 미구현 (다음 후보, 우선순위 순)

### 1. NTD (Not Todo) — 최우선
**Why NTD를 다음으로**: 기획안의 핵심 차별 기능. 위젯 표시도 NTD 중심. 모델 추가 변경 거의 없음 (Recurrence 인프라 활용 가능).

기획 합의 사항 (2026-05-21):
- NTD는 "유지 시간 중심" (Todo는 "완료 여부 중심"과 대비)
- 정확한 시작 시각 = Item.startDate (Date 타입 그대로, NTD는 시간 정밀도 활용. Todo는 startOfDay 관행)
- 목표 종료 시각 = Item.dueDate (목표 시간 = dueDate - startDate)
- 실제 종료 시각 = Item.completedAt
- 포기 사유 = Item.comment (완료 후 코멘트와 동일 attribute)
- Status: pending(진행 중) / done(자동 성공) / failed(사용자 종료/포기)
- ItemAction.failed 추가됨 (활동 로그용)
- NTD도 RecurrenceRule 활용 가능 (예: 매주 월 20:00부터 16시간 금식)
- 명칭: 영어 "Fast" / 한국어 "비움" (ItemKind.displayName에 추가 필요)

작업 단계:
1. ItemKind.displayName 추가 + catalog (`item_kind.todo`, `item_kind.not_todo`)
2. AddItemView에 kind toggle 또는 별도 시트 (NTD 입력)
   - NTD 시작 시각 (date+time picker, 분 단위)
   - 목표 시간 (분 또는 시간 입력)
   - RecurrenceRule (기존 sheet 활용)
3. TodayView "진행 중 Not Todo" 섹션 — 진행 중 NTD 실데이터 + live countdown
4. NTD 포기 시트 — 사유 선택지 (스트레스/다른 일정/한계 등) + 직접 입력 → Item.comment
5. NTD 자동 성공 처리 — Item.completeExpiredRoutines와 유사 패턴 (앱 foreground 시)
6. **WidgetKit 위젯** — 진행 중 NTD 카운트다운. 별도 단계

### 2. 알림 (Local Notification)
- UNUserNotificationCenter 권한 + Reminder 모델 활용
- Item의 reminders 관계로 스케줄링

### 3. 카테고리·태그 관리 UI
- Category 입력/편집 화면
- 목록·보관함에 필터 추가

### 4. 3단계 계층 구조
- AddItemView에 parent 선택 UI
- 표시(들여쓰기) — 깊이 제한 3단계 앱 로직

### 5. Week View / Month View / 달력 뷰
- TodayView의 일자 이동 외에 주/월 뷰 추가

### 6. iPad 최적화
- 합의: **앱 완성 후 일괄 작업**
- NavigationSplitView, 2-pane, Regular size class

## 디자인 / 코드 가이드라인

- **꼭 필요한 기능만, 최대한 단순화. 입력 편의성 우선.**
- 사용자 멘탈 모델 우선. 데이터 모델은 백킹.
- 새 Core Data 변경: 모든 attribute optional + 양방향 inverse + Nullify/Cascade 신중히 (CloudKit 호환)
- 상태 변경 지점에서 일관되게 `ItemEvent.log(_:on:in:)` 호출
- SwiftUI Text literal은 가능한 LocalizedStringKey 활용 (catalog 자동 추출). 동적 텍스트는 `String.localizedStringWithFormat(NSLocalizedString(...))` 또는 `String(localized:)`
- 사용자 데이터 표시는 `Text(verbatim:)` (localize 회피)
- 한국어/영어 분기는 `Locale.preferredLanguages.first?.hasPrefix("ko")` 사용. `Locale.current.language.languageCode`는 실기기에서 신뢰 X
- iOS 26+ API는 `#available(iOS 26.0, *)` 가드 (deployment 17.6 유지)
- UIKit Programmatic 도입 자제. 정말 필요할 때만 `UIViewRepresentable`
- 깃발 아이콘 (priority) 색상은 선택 여부 무관 항상 표시 (사용자가 색으로 식별)
- chip 스타일: 선택 시 fill, 미선택 시 stroke (lineWidth 동일 → layout shift 없음)

## 알려진 제약 / 노이즈

- **첫 키보드 활성화 ~5초**: iOS 시스템의 텍스트 입력 세션 초기화 비용. 워밍업 트릭은 부작용으로 미적용.
- **iOS 17~25 toolbar capsule**: 같은 placement의 ToolbarItem들이 단일 capsule로 묶이는 시스템 디자인. `ToolbarSpacer`는 iOS 26+ only.
- **TodayView navigation title이 작은 화면(17 Pro)에서 왼쪽으로 약간 치우침**: 좌우 toolbar item 폭 비대칭. invisible balance 시도했으나 capsule 늘어남으로 철회. 수용 결정.
- 콘솔 노이즈 (`remoteTextInputSession…`, `Gesture: System gesture gate timed out`, `Result accumulator timeout` 등)는 iOS 자체 이슈로 무시.

## 사용자 컨텍스트

- 익숙: Swift, Java. native 개발 선호 (크로스플랫폼 X).
- 응답 스타일: 짧고 빠른 결정. UX 디테일에 민감.
- 진행 방식: 기능 단위로 만들고 → 실기기에서 확인 → 짧은 피드백 → 반영.
- 메모리 시스템은 머신 로컬에 저장됨. 회사(맥미니)와 집(맥북) 양쪽에서 작업하므로 이 CLAUDE.md가 컨텍스트 동기화의 1순위.
- 두 기기 모두 동일 경로 `/Users/diokim/Work/mywork/mydays/mydaysiOS/MyDays` 사용 권장 (메모리 sanitized path 동일).
</content>
