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
- 일반: title, **notes**(작성 시 메모), kind, priority, status, isSomeday, sortOrder, createdAt, updatedAt, completedAt
- 캘린더 날짜 (UTC anchor — Timezone 정책 참조): **startDate**, **dueDate**, **recurrenceEndDate**
- 시각 (wall-clock 정수): **startHour** (Int16?, 0~23 — Todo·NTD 공통), **dueHour** (Int16?, 0~24 — Todo만)
  - **단순화 모델**: accessor `startHourInt`/`dueHourInt`는 non-optional Int. nil 데이터는 0(start)/24(due)로 default 해석. 신규 save는 항상 명시 값.
  - **24는 sentinel** — "시간 미설정 = 다음 날 0시" 의미. `Item.hasExplicitTime` = `dueHourInt < 24`.
  - 모든 dated 항목이 `(effectiveStartInstant, effectiveDueInstant)` 쌍으로 통합. `Item.localInstant(...)`는 hour=24를 다음 날 0시로 변환.
  - **NTD는 dueHour 미사용**이지만 AddItemView가 `dueHour=startHour`로 sync 저장 (재진입 시 hasTime=true 보장 위해). NTD 실제 종료는 duration 기반.
- 시간대 legacy (현재 UI 미사용): **startTimeOfDay**, **dueTimeOfDay** (오전/오후/저녁/none)
- NTD 전용: **ntdStartHour** (legacy, `startHour`로 통합), **ntdDurationHour** (Int16?, nil=미설정/한계까지)
- 포기 사유는 `RoutineCompletion.comment` + `ItemEvent.note`에 저장. Item 차원의 comment 필드는 제거됨.
- self-relation: parent/children (3단계 계층은 앱 로직에서 강제)
- 관계: category, tags, recurrenceRule, reminders, completions, events

### RecurrenceRule
- frequency, interval, weekdayMask, **dayOfMonthMask (Int64, bit 0~30=일자, bit 31=말일)**, **monthMask (Int16, 0=모든 월)**, countPerWeek (legacy), dayOfMonth (legacy), startDate (legacy, 미사용), endDate (legacy, 미사용)
- **Item.startDate를 anchor로 사용**, Item.dueDate를 반복 종료일로 사용
- helper: `selectedWeekdays/Days/Months`, `includesLastDay`, `occurs(on:startDate:endDate:)`, `nextOccurrence(after:startDate:endDate:)`, `make(in:)`

### RoutineCompletion (per-occurrence 기록)
- id, **date** (UTC anchor), **done**, **failed**, **comment**, item
- 의미:
  - `done=true, failed=false` → 성공 (자동 완성 / Todo 체크)
  - `done=false, failed=true` → 포기 (사용자 종료, NTD)
  - record 없음 → 미참여
- 1회성 NTD도 포기 시 동일하게 사용 — 1회성↔반복 전환 시 기록 보존
- Streak 계산 기반

### Category / Tag / Reminder / RecurrenceRule
- Category: id, name, colorHex, iconName, sortOrder, createdAt, updatedAt
- Tag: id, name, colorHex(현재 단일 색), createdAt, updatedAt
- Reminder: id, fireDate, offsetMin, anchor, repeats, createdAt, updatedAt
- RecurrenceRule: id, frequency, interval, weekdayMask, dayOfMonthMask, monthMask, createdAt, updatedAt, (legacy attrs)
- 모든 entity에 `id: UUID?` + `createdAt/updatedAt: Date?` — Firebase 마이그레이션 prep (last-writer-wins 충돌 해결, cross-platform ID stable). 자세한 정책은 "마이그레이션 prep" 섹션 참조.

### ItemEvent (활동 로그)
- timestamp, action, itemTitle(snapshot), **note**(부가 정보 — 포기 사유 등), item(Nullify) — Item 삭제돼도 보존

### Enum 매핑 (`Models/ModelEnums.swift`)
- **ItemKind**: 0=todo, 1=notTodo. `displayName` localized ("할일"/"절제 목표" / "Todo"/"Fast")
- **Priority**: 0=none, 1=medium, 2=high, 3=low. `displayName` localized
- **Status**: 0=pending, 1=done, **2=deleted (legacy/soft-delete 예약)**, **3=failed (NTD 포기 또는 1회성 NTD 사용자 종료)**
- **Frequency**: 0=daily, 1=weekly, 2=monthly (3=weekdays, 4=weekend, 5=weeklyCount는 legacy, 미사용)
- **TimeOfDay**: 0=none, 1=morning, 2=afternoon, 3=evening
- **ItemAction**: 0~7 (created/updated/completed/uncompleted/cancelled[legacy]/restored/deleted/**failed**). 모두 localized

## Timezone 정책 (중요)

**달력 날짜 의미** 필드는 **UTC 자정 anchor**로 저장 → 어느 timezone에 있든 같은 라벨 유지.

| 필드 | 의미 | 비교/연산 |
|---|---|---|
| `Item.startDate` | 캘린더 날짜 | `Calendar.gmt` |
| `Item.dueDate` | 캘린더 날짜 | `Calendar.gmt` |
| `RoutineCompletion.date` | 캘린더 날짜 | `Calendar.gmt` |
| `Item.completedAt` / `createdAt` / `updatedAt` | instant | `Calendar.current` (실제 시각) |
| `ItemEvent.timestamp` | instant | `Calendar.current` |
| `Reminder.fireDate` | instant | `Calendar.current` |
| `Item.ntdStartHour` | wall-clock 시 (정수) | local에서 해석 |

### CalendarDate helpers (`Models/CalendarDate.swift`)
- `Calendar.gmt`: UTC 고정 그레고리안 캘린더
- `Date.calendarDateAnchor`: local에서 읽은 (y,m,d)를 UTC 자정 instant로 정규화 (DatePicker 결과 저장 시)
- `Date.localCalendarSameDay`: UTC anchor → local 같은 (y,m,d) 자정 (DatePicker 초기값 표시 시)
- `Date.todayCalendarAnchor`: local 기준 "오늘"의 UTC anchor — 비교 기준점

### DateFormatter
- 캘린더 날짜 표시: `formatter.timeZone = TimeZone(identifier: "UTC")` (또는 .gmt) 강제
- instant 표시 (활동 로그 등): `Calendar.current` 그대로

### NTD 시각 정책 (wall-clock semantics)
- NTD startDate는 calendar date(UTC anchor) + ntdStartHour(wall-clock 정수)
- 실제 시작 instant = "startDate의 (y,m,d) + 현지 hour:00"
- 여행 시 현지 hour로 자연 작동 (예: 매주 월 20시 단식은 어디서나 현지 20시 시작)
- `Item.ntdStartInstant(on:)` / `ntdEndInstant(on:)` 활용

## 폴더 구조
```
MyDays/MyDays/
├── MyDaysApp.swift                  @main App
├── Info.plist / MyDays.entitlements / MyDays.xcdatamodeld
├── Localizable.xcstrings            String Catalog (ko + en, ja/zh 추후)
├── Models/
│   ├── ModelEnums.swift             Priority/Status/Frequency/TimeOfDay/ItemAction/ItemKind
│   ├── CalendarDate.swift           Calendar.gmt / Date.{calendarDateAnchor,localCalendarSameDay,todayCalendarAnchor}
│   ├── Item+Helpers.swift           daysUntilDue, isOverdue, isCompletedForDate, currentStreak, daysUntilNextOccurrence, completeExpiredRoutines, completeFinishedNTDs, ntd{StartInstant,EndInstant,State,Occurs,InProgressOccurrenceDate,RelevantOccurrenceDate,CountdownLabel,OccurrenceCalendarRange,OccurrenceStartCandidates,LastCompletionInstant}, hasRoutineRecord, routineRecord, formatNTDDuration, todoSection, isSingleSchedule, effective{StartInstant,DueInstant,DueDate}, nextCountdownInstant, isInProgress, occurrenceStartDate, referenceOccurrenceStartDate, make
│   ├── ItemEvent+Helpers.swift      log(_:on:in:note:)
│   ├── RecurrenceRule+Helpers.swift  itemFrequency, selectedWeekdays/Days/Months, includesLastDay, occurs, nextOccurrence, make
│   └── RecurrenceConfig.swift       Sheet ↔ Rule 임시 struct (apply(to:), init(from:))
├── Services/
│   ├── PersistenceController.swift  shared singleton, CloudKit 스택, deleteAllData (개발용)
│   ├── NotificationService.swift    UNUserNotificationCenter wrapper (delegate, schedule, cancel)
│   └── SpeechRecognizer.swift       SFSpeechRecognizer + AVAudioEngine wrapper (ko-KR, on-device)
└── Views/
    ├── RootView.swift               TabView + .task/scenePhase에서 completeExpiredRoutines + completeFinishedNTDs 호출
    ├── TodayView.swift              부모(displayedDate UTC anchor) + TodayList(섹션 fetch + NTD 필터)
    ├── ListView.swift               전체 + 완료 토글. 완료 섹션 = status 1 OR 3 (NTD failed 포함)
    ├── ArchiveView.swift            isSomeday=YES 항목 + 하단 QuickEntryBar
    ├── SettingsView.swift           동기화/활동/정보 + Dev: 모든 데이터 삭제 + App Icon export
    ├── ActivityLogView.swift        시계열 ItemEvent 표시 (note 포함)
    ├── AddItemView.swift            입력/편집/삭제 통합. kind picker, NTD 입력 분기, 활동 기록 표시
    ├── ItemRow.swift                Todo/Routine/NTD 통합 row (D-day, status icons, AdaptiveCountdownSchedule)
    ├── NTDRow.swift                 TodayView NTD 전용 row (Adaptive schedule, statusIcons, (x) 포기 버튼)
    ├── AdaptiveCountdownSchedule.swift  target instant 기반 가변 갱신 (1s/30s/60s)
    ├── QuickEntryBar.swift          보관함 하단 floating 입력 바 (TextField + mic + (+))
    ├── AppIconBuilder.swift         앱 아이콘 시안 SwiftUI 렌더 + PNG export (dev)
    ├── RecurrenceSheet.swift        반복 입력 시트
    ├── DatePickerSheet.swift        X/V + 시간대 chips(NTD에선 숨김) + 지우기. UTC anchor 정규화 내장
    ├── StartHourPickerSheet.swift   NTD 시작 시간 (12h/24h 자동, 24-item duplicate wheel)
    ├── DurationPickerSheet.swift    NTD 목표 시간 (일+시 2 wheel + 미설정 toggle)
    ├── NTDGiveUpSheet.swift         포기 사유 (chip 4종 + 직접 입력)
    └── ItemSheetMode.swift          enum new(baseDate: Date?) / edit(Item)
```

## 구현 완료

### 탭바 4개 — 오늘 / 목록 / 보관함 / 설정

### 오늘 화면 (TodayView)
- **일자 이동**:
  - 좌우 chevron toolbar 버튼
  - **좌우 swipe** (List 세로 스크롤과 공존, `.simultaneousGesture` 사용. 임계: |h|>60pt + 수평 우세 |h|>|v|*2). 오른쪽 swipe → 이전 일자, 왼쪽 swipe → 다음 일자.
  - 하단 leading "오늘" 버튼 (항상 노출 — 상태로 색 구분):
    · 오늘: accent fill + 흰 글자 (현재 위치 indicator)
    · 다른 날: systemGray4 fill + secondary 글자 (탭하면 jump)
- **슬라이드 transition**: ZStack + `.id(displayedDate)` + `.animation(.easeInOut(duration: 0.22), value: displayedDate)`. forward 이동 시 새 view 우측에서 진입 / 기존 좌측 퇴장, backward 반대.
  - 방향 전환 시 `navigateTo(_:forward:)`가 한 박자 먼저 `lastNavigationForward` 업데이트 후 다음 run loop에 `displayedDate` 변경 — old view의 removal transition이 새 방향으로 re-capture되도록.
- **navigation title**: 항상 절대 날짜 포맷 "M월 d일 (E)" (UTC formatter). 상대 마커(어제/오늘/내일)는 제거 — 하단 "오늘" 버튼의 색이 그 역할.
- `displayedDate`는 UTC anchor (`.todayCalendarAnchor` default)
- **자정 넘김 자동 갱신**: `lastKnownToday` 추적 + `.NSCalendarDayChanged` 알림 + `scenePhase==.active` 트리거. displayedDate가 lastKnownToday ±1일 범위(어제/오늘/내일)였으면 dayDelta만큼 forward shift. 모레+ 이후는 절대 날짜 유지.
- 섹션 순서: **절제 목표** (NTD) / **할일** (Todo) / **루틴** — 3-섹션 모델. 할일 섹션은 시작·진행 중·마감 모두 통합 (.start→.inProgress→.due 순서). 라벨로 "X시 시작/종료" / "종료" / "5월 26일 종료" / "오늘 종료" 등 노출.
- **Todo 라벨 원칙** (1회성/기간/반복 통일, ItemRow.scheduleLabel):
  1. 일정 정보 기반만 — `Item.completedAt` 무시 (완료 항목도 schedule-based 라벨로 표시).
  2. 시각 설정 + 시작/종료가 real today → "X시 시작" / "X시 종료" (원칙 3 우선). 그 외 → d-day section.
  3. **today mode** (mode=.today, TodayView):
     - 단일 (startDay==dueDay): 라벨 없음 (nil) — 일자/요일은 view date 자체가 표시
     - 기간 (startDay!=dueDay):
       · view=today + 종료일=today → "오늘 종료"
       · 그 외 → "M월 d일 종료" (절대 종료일자, D-N 아님)
  4. **list mode** (mode=.list, ListView): 기존 D-N 중심 ("D-3" / "종료 D-3" / "오늘 종료" 등)
  5. 반복은 적용 occurrence start를 anchor로 1회성처럼 처리 (`Item.referenceOccurrenceStartDate(viewDate:)`). list mode에선 다음 future occurrence 사용.
  - NTD는 별도 라벨 경로 (`ntdListLabel`/`ntdListModeLabel`) — 원칙 적용 안 함 (실시간 카운트다운 + 절제 목표 정체성).
  - 모든 Todo predicate에 `kind == 0` 추가 — NTD는 NTD 섹션에서만
  - 루틴: `recurrenceRule != nil AND status != 2 AND kind == 0` fetch + `rule.occurs(...)` 필터
  - NTD section (`ntdsForDate`): kind==1 fetch + **range 기반 노출** 규칙
    - displayedDate가 occurrence의 [start, end calendar date] 범위 안에 있으면 표시 — 완료/포기 무관
    - end calendar date 결정 (`Item.ntdOccurrenceCalendarRange`):
      - duration 설정됨: 계획된 종료 instant의 local 일자
      - duration 없음 + RC.completedAt 있음: RC.completedAt의 local 일자
      - duration 없음 + 1회성 종료: item.completedAt의 local 일자
      - duration 없음 + **반복** + RC 없음: 다음 occurrence start instant (implicit auto-end — 안 그러면 lookback 모든 occurrence가 today를 cover)
      - duration 없음 + 1회성/마지막 진행 중: now
    - 후보 occurrence start dates (`Item.ntdOccurrenceStartCandidates(coveringDate:)`):
      - 1회성: startDate 1개
      - 반복: lookback 내 forward iterate — duration 설정 시 ceil(duration/24)+1일, 미설정 시 31일
      - **주의**: `RecurrenceRule.nextOccurrence(after:)`는 referenceDate를 *포함* 검사 (이름과 달리). cursor를 `next + 1일`로 advance해야 같은 occurrence 재반환 무한 루프 회피.
    - **모든 매치 occurrence 노출** (multi-day 겹침 시 같은 Item이 여러 줄로 표시. 그룹핑은 view layer에서)
  - 1회성 Todo 섹션 분류 (`Item.todoSection(on:now:)` 공용 helper, fetch는 displayedDay 구간 통합):
    - 모든 항목 `(effectiveStartInstant, effectiveDueInstant)` 쌍 보유 (시간 미설정 → 0시/24시 default).
    - **단일/기간 분기** (`Item.isSingleSchedule`):
      - 단일: 같은 날 + (dueHour==24 OR startHour==dueHour)
      - 기간: 그 외
    - **단일**: `now < startInst ? .start : .inProgress` — 마감 섹션 안 감, 사용자가 체크해야 사라짐
    - **기간** 4-branch:
      1. `now < startInst` → .start
      2. `displayedDay == dueDay` → .due (overdue 포함)
      3. `displayedDay < dueDay` → .inProgress
      4. `displayedDay > dueDay` → nil (이미 지난 항목)
    - past/future view에서도 동일한 now-기반 시간 비교 — 일관된 시간 흐름 해석.

### 보관함 (ArchiveView) — `isSomeday=YES AND status==0`
- **하단 QuickEntryBar** — 즉시 등록 inbox 패턴 (Reminders 유사).
  - 제목만 받아서 `isSomeday=true` Item 즉시 생성 (kind=todo). 상세는 나중에 row 탭해서 편집.
  - `.overlay(alignment: .bottom)`로 floating capsule — `.regularMaterial` + shadow. 탭 전환 시 위치 고정.
  - List에 `.contentMargins(.bottom, 96)`로 마지막 row 가림 방지.
  - (+) 버튼: 56pt accent circle + shadow (목록탭 FAB와 동일 사이즈/위치). 항상 활성 (opacity 없음).
    - 텍스트 있을 때: quickSave (등록 후 text="" + 키보드 dismiss)
    - 비어있을 때: `AddItemView(baseDate: nil)` 시트 열림 — 일정 chip "미정" preset
  - 키보드 dismiss: focus 시 mic 위치에 `keyboard.chevron.compact.down` 버튼 노출. List swipe도 `.scrollDismissesKeyboard(.immediately)`로 dismiss.
  - submit 시 항상 text clear + fieldFocused=false (Reminders 같은 keep-focus 패턴 아님 — 사용자 명시 요구).

### Multi-occurrence rendering (TodayView NTD / Routine 공통)
- **모델**: 같은 Item이 같은 일자에 여러 occurrence로 나올 수 있음 (multi-day span 겹침 또는 NTD duration 겹침).
- **수집**:
  - NTD: `ntdsForDate`가 모든 매치 occurrence 반환 (이전 break 제거).
  - Routine Todo: `routinesForDate`가 `Item.occurrenceStartsCovering(date:)`로 cover하는 모든 start dates 수집.
  - 결과 타입: `OccurrenceRow` (Identifiable wrapper, id = objectID + timestamp 조합).
- **정렬** (`sortedRoutines`):
  - 같은 Item의 occurrence들은 항상 **인접** (chronological 순서, 그룹 마지막=가장 최근).
  - Item 그룹 단위: pending occurrence 있는 그룹 먼저, 전부 done인 그룹은 섹션 끝.
  - Occurrence별 split하면 같은 Item이 pending/done bucket으로 쪼개져 인접 깨짐 → 그룹 단위 split.
- **정렬 snapshot** (`stableRoutineOrder @State`):
  - 첫 render의 `.onAppear`에서 sortedRoutines 결과를 ID 순서로 캡처.
  - 이후 체크 토글 시 cache 사용 → 즉시 reorder 회피.
  - date 변경 시 부모 `.id(displayedDate)`로 TodayList 재생성 → @State 초기화 → 다시 캡처.
- **그룹 렌더링** (List row 1개 per Item):
  - `ItemGroup` struct로 같은 Item의 연속 occurrence 묶음.
  - 그룹 = List row 1개. 내부 `VStack(spacing: 4)`로 occurrence stacking → List의 enforced row 높이 영향 회피 (.listRowInsets/negative padding/frame 모두 안 먹는 환경 우회).
  - 그룹 마지막 occurrence = full ItemRow/NTDRow. 위 row들 = compactMode=true (notes/statusIcons 숨김, NTDRow는 (x) 포기 버튼도 숨김).
  - 각 occurrence는 자체 Button(편집 시트 open) — VStack 안에서도 개별 tap 동작.
  - inter-group separator는 자동 (각 그룹 = List row 1개).
- **per-occurrence 완료**:
  - `ItemRow.canonicalCompletionDay`: routine은 `occurrenceStartOverride ?? referenceDate` 기준 (각 occurrence 독립 RC).
  - `isCompletedForDate`도 동일.
  - 1회성 Todo는 startDate 기준 (canonical event date) — multi-occurrence 무관.
- **라벨 차별화** (`ItemRow.occurrenceStartOverride: Date?`):
  - nil이면 referenceDate로 자동 (단일 occurrence).
  - 명시되면 그 occurrence start를 anchor로 라벨 계산 → 같은 Item의 여러 row가 서로 다른 종료일 라벨 표시.

### 목록 (ListView) — `isSomeday=NO`. 진행 중 + 완료 토글 (default 숨김). 완료 섹션 predicate = `(status==1 OR status==3) AND isSomeday==NO`
- 네비게이션 타이틀: "목록" (`.navigationBarTitleDisplayMode(.large)`). 섹션 헤더 제거 — 타이틀이 정체성 제공.
- 진입 시 `completeExpiredRoutines` + `completeFinishedNTDs` 호출
- ItemRow `.list` mode 사용 — leadingControl이 4-state 아이콘 (체크 불가), D-day 중심 라벨
- 하단 (+) FAB (56pt) — 기존 위치 유지. ArchiveView QuickEntryBar (+) 위치와 정확히 일치 (right 20pt, bottom 20pt)

### QuickEntryBar + SpeechRecognizer (보관함 inline 입력)
- **컴포넌트**: `Views/QuickEntryBar.swift`. props: `text: Binding<String>`, `onSubmit: () -> Void`, `onEmptyTap: (() -> Void)?`
- **레이아웃**: floating capsule (`.regularMaterial` + shadow). 내부 = `[TextField pill + (keyboard dismiss if focused) | mic if !focused | (+) 56pt accent]`
- **TextField**: 내부 `Capsule().fill(Color(.tertiarySystemFill))` 배경 — 외곽 capsule과 시각 구분
- **마이크 버튼**: 키보드 안 떠있을 때만 노출 (`!fieldFocused`). 키보드 활성 시엔 시스템 키보드 내장 dictation 사용 (inline·자연스러움). 우리 마이크는 hands-free 경로 — 키보드 띄우지 않고 voice만으로 등록
- **SpeechRecognizer** (`Services/SpeechRecognizer.swift`): SFSpeechRecognizer + AVAudioEngine wrapper
  - `@MainActor`, `@Published transcript/isRecording`
  - locale ko-KR 기본 → unavailable이면 .current fallback
  - iOS 17+ on-device 인식 자동 (supportsOnDeviceRecognition && requiresOnDeviceRecognition)
  - `requestPermissions()` async: SFSpeechRecognizer.requestAuthorization + AVAudioApplication.requestRecordPermission 둘 다 허용 시 true
  - Info.plist: `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`
- **음성 입력 흐름**:
  - mic 탭 → `keyboardPrefix = text.trimmed`로 기존 입력 보존 → recording 시작
  - transcript 변화 시 `text = keyboardPrefix + " " + transcript` (공백 합침)
  - 녹음 중 사용자가 text field 탭 → `.onChange(of: fieldFocused)`로 자동 stop (음성/키보드 동시 입력 충돌 방지)
  - 권한 거부 시 alert
- **submit 흐름**:
  - 등록 후 항상 `text = ""` + `fieldFocused = false` + `speech.resetTranscript()`
  - keepFocus 옵션 없음 (사용자 명시: dismiss 우선)

### AddItemView (입력/편집/삭제 통합)
- **kind picker** (segmented, 새 항목만 노출): Todo / 절제 목표(NTD)
- 편집 모드 타이틀: "할일 수정" / "비움 수정" (영어 "Edit Todo" / "Edit Fast")
- 새 항목 타이틀: "새 항목"
- chips 라인 (가로 스크롤): `미정 / 오늘 / 내일 / 기간 | 시간설정`
  - NTD에선 "미정"/"기간"/"시간설정" 숨김 — 단일 시작일 + 시간 필수
  - **시간설정** 독립 toggle — derived state (`dueHour < 24`). OFF면 시작/종료 라인의 시간 chip 모두 숨김 + save 시 `dueHour=24` sentinel. ON 전환 시 dueHour=startHour로 sync. wheel은 0~23만 노출 (별도 "시간 미설정" 옵션 없음).
- 단일 모드 (default): 시작 chip 1개, `startDate=dueDate` 자동 동기
- 기간 모드 (기간 ON, 또는 편집 시 두 날짜 다르면 자동): chip 2개 + `~`
- 날짜 chip 포맷: 짧은 `M.d (E)` 또는 `yyyy.M.d (E)` (다른 해). 시간대 표시(Todo만)
- DatePickerSheet: 캘린더 + 시간대 chips (Todo만) + "지우기"(NTD에선 비활성)
  - `showsTimeOfDay` 파라미터로 NTD 모드에선 시간대 chip 숨김
  - UTC anchor ↔ local 변환 내장 (init / onSelect)
  - detent `.height(480)`
- 마감일 default = baseDate + 1
- 자동 포커스 120ms (편집 모드 비활성)
- **활동 기록 section** (편집): `routineHistoryRecords` 최신 10건 — 날짜·시각·성공/포기·사유 표시
- **삭제 버튼** (편집): `.alert` 확인. 각 Button에 alert/dialog 부착 (Form 최상위 multi-alert stacking 회피).
- **종료하기 버튼은 없음**: 반복 항목 종료는 입력 폼에서 `반복 종료일`을 오늘/과거로 설정 → 다음 fetch에서 `completeExpiredRoutines`가 자동 done 처리. UI 단순화 목적 (사용자 결정).
- **반복(Recurrence) Section**: row 전체 탭 가능 (contentShape Rectangle)
  - 동적 요약 텍스트: Daily "매일" / "2일마다", Weekly "매주 화·목", Monthly "매월 1·15·말일" / "1·15·말일 of Jun·Dec" / "5 days/month"
  - 한국어: 일자 = "1일·15일", 영어: ordinal = "1st·15th"
  - 반복 시트 onSave 시 시작일 자동 ON (없으면 오늘)
- **Priority** (Todo만): 깃발 아이콘 4개 (가로). 색상은 선택 무관 항상 표시 (red/orange/blue/secondary). 선택 시 `Color(.secondarySystemFill)` 동그라미 배경 (다크/라이트 모두 명확). 새 항목 default = none
- 단일 chip 모드 + 반복 설정 시: dueDate=nil 저장 (무기한 반복). 기간 chip 모드에선 dueDate=종료일.
- 키보드 dismiss: `.scrollDismissesKeyboard(.immediately)` (스크롤 시 즉시). 이전엔 `simultaneousGesture(TapGesture)`도 있었으나 Form 하단 Button 탭과 충돌해 제거.
- 모든 .sheet에 `onChange(of:)`로 title focus 해제 (sheet 닫혀도 자동 복귀 안 되게)

### NTD 입력 — 시간 section
- 노출 조건: `kind == .notTodo`
- **시작 시간 / 목표 유지 시간**: 일정 section 내 row, 탭하면 inline wheel 확장 (sheet 아님)
  - **상호 배타**: 시작 시간(dateExpansion=.startTime) ↔ 목표 시간(durationExpanded). 한쪽 열면 다른 쪽 자동 접힘 — `toggleDateExpansion`이 `durationExpanded=false`, duration 버튼이 `dateExpansion=.none`로 sync.
- **시작 시간 wheel**
  - 시스템 시간 표시 설정 (12h/24h) 자동 감지 (DateFormatter "j" template로 'a' 포함 여부)
  - 24h 모드: 단일 wheel "0시"~"23시" / 12h 모드: 24-item ("오전 11시" / "오후 1시") — AM/PM 별도 wheel 없음 (lag 회피)
  - 1자리 시간(1~9)은 leading figure space(U+2007) padding + `.monospacedDigit()` → 스크롤 좌표 안 흔들림
  - default = 현재 시각의 다음 정각
- **목표 유지 시간 wheel**
  - 2 wheel: 일(0~30) + 시(0~23)
  - "미설정" toggle (한계까지)
  - default = 16시간 (대중적 단식). 열 때 isUnset=false 강제
- **반복 section 노출 조건** (`isRecurrenceSectionVisible`):
  - `hasStart=true` (일정 chip이 미정 아님)
  - NTD인 경우 추가로 `ntdDurationHour != nil`
- **NTD duration → nil 시 반복 자동 cleanup**: `.onChange(of: ntdDurationHour)`에서 nil 되면 `recurrenceConfig = nil`로 자동 제거 (미설정 NTD는 1회성 의미라 반복 불가).

### RecurrenceSheet
- Frequency picker (segmented): 매일/매주/매월
- Daily: Stepper로 interval (1~365)
- Weekly: 요일 7개 멀티 (시스템 firstWeekday 시작). `shortWeekdaySymbols` 사용 (영어 Tue/Thu 구분 OK)
- Monthly: 1~31 grid + 말일 toggle + 1~12월 grid
- 기간(start/end) 입력은 **없음** — Item.startDate/dueDate 사용
- 편집 시 "반복 제거" destructive 버튼

### ItemRow (3줄 레이아웃)
- 줄 1: leadingControl + 제목(1줄, truncation tail) + 시간대(caption2) + D-day/카운트다운(caption, isOverdue면 red)
- 줄 2: 메모(notes, caption secondary, 1줄) — 옵션 (compactMode 시 숨김)
- 줄 3: statusIcons (깃발 / 🔥streak / 알림 bell / 반복 repeat+요약 / NTD 목표 clock+duration) — today·list mode 공통 노출 (compactMode 시 숨김)
- **props**:
  - `referenceDate`: view 일자 (라벨 계산 기준)
  - `mode`: .today / .list
  - `occurrenceStartOverride: Date?`: multi-occurrence rendering 시 명시 — 라벨 + 완료 체크의 anchor (각 occurrence 독립 RC)
  - `compactMode: Bool`: 그룹 내 비-last row용 (notes/statusIcons 숨김)
  - 알림 아이콘: `bell` (line, not filled)
  - 반복: `repeat` 아이콘 + `rule.summaryText()`
  - NTD duration: `clock` 아이콘 + `formatDuration` (반복과 별도). duration 미설정 NTD는 노출 안 함
- **TimelineView wrap** — `AdaptiveCountdownSchedule`로 시각 라벨/색상 자동 갱신 (target 임박 시 1초/30초, 평소 60초)
- `mode: DisplayMode = .today` prop: `.today`(TodayView/ArchiveView) / `.list`(ListView). 라벨·체크 동작이 mode에 따라 갈림.
  - `routineCheckable`은 `mode != .list`로 derive
- leadingControl 분기:
  - **NTD** (`ntdStatusIcon`, 4-state):
    - pending + scheduled(시작 전): `stopwatch` outline + secondary (회색)
    - pending + inProgress: `stopwatch` outline + accent (파랑)
    - done: `stopwatch.fill` + accent
    - failed: `stopwatch.fill` + secondary (회색 filled)
    - 공유 helper: `ItemRow.ntdIconStyle(for:now:occurrenceDate:)` — NTDRow와 동일 규칙
  - 일반 todo: 체크박스 (status .pending↔.done 토글)
  - routine + routineCheckable=true: 체크박스 (그 날짜의 RoutineCompletion 토글)
  - routine + routineCheckable=false (목록탭) — NTD 4-state와 같은 의미:
    - pending + 오늘이 occurrence 아님: `arrow.triangle.2.circlepath.circle` outline + secondary (회색 라인)
    - pending + 오늘이 occurrence: `arrow.triangle.2.circlepath.circle` outline + accent (blue 라인)
    - done (반복 종료일 도과 자동 완료): `arrow.triangle.2.circlepath.circle.fill` + accent (blue filled)
    - failed: 같은 fill + secondary (실제 발생 드묾)
- D-day/시각 라벨 분기 (`scheduleLabel`):
  - mode=.today + NTD: `ntdListLabel` (현재 시간 기반 카운트다운)
  - mode=.today + Todo: 원칙 3 시각 라벨 우선 (시각 설정 + 시작/종료가 real today면 "X시 시작/종료"), 그 외 today mode d-day 규칙:
    · 단일 (startDay==dueDay): 라벨 없음 (nil)
    · 기간 + view=today + 종료일=today → "오늘 종료"
    · 기간 + 그 외 → "M월 d일 종료" (절대 종료일자, D-N 아님)
  - mode=.list: D-N 중심 ("D-3", "종료 D-3", "오늘 종료" 등)
- **단일 시각 (s==d, 같은 instant) 처리** — `Item.isInProgress` / `nextCountdownInstant` 둘 다 단일 시각 edge case 분기: 시작 후 occurrence day 자정까지 inProgress 유지 (오후 9시 단일 시각 routine을 9:15에 봐도 파란 라인). 자정에 transition.
- **1회성 NTD 완료/포기 라벨** (`ntdListLabel`):
  - status=done/failed: `Item.ntdLastCompletionInstant(on:)` 사용해 "%@ 종료" / "%@ 포기" — `Mdjm` 템플릿으로 항상 일자+시:분 포함 (예: "5/24 오후 2:32 포기"). 다일 NTD에서 어느 날 종료했는지 식별
- 행 탭 = 편집 시트 (체크박스/leadingControl 영역 제외)

### NTDRow (TodayView 절제 목표 섹션 전용)
- **AdaptiveCountdownSchedule** — target instant 기반 가변 갱신 (1분 미만 1s / 1시간 미만 30s / 그 외 60s). 배터리 saving.
- **props**: `item`, `occurrenceDate`, `compactMode: Bool` (그룹 내 비-last 시 statusIcons + (x) 포기 버튼 숨김)
- Layout: stopwatch icon(좌) + 제목 + trailingText(우, D-day 자리) + (x) 포기 버튼(우끝)
- 우측 (x): `xmark.circle` (secondary). pending/in-progress occurrence에만 노출. 탭 → NTDGiveUpSheet
- 좌측 stopwatch (ItemRow.ntdIconStyle 공유, 4-state):
  - scheduled: outline + secondary / inProgress: outline + accent / done: fill + accent / failed: fill + secondary
- trailingText 분기:
  - **완료/포기**: `Item.ntdLastCompletionInstant(on:)` 사용 "%@ 종료" / "%@ 포기" (Mdjm 템플릿). instant 없으면 fallback "목표 달성"/"포기됨"
  - 시작 전: "5시간 23분 후"
  - 진행 중 (목표 있음): "5시간 23분 남음"
  - 진행 중 (목표 미설정): "1시간 42분 경과"
  - 1분 미만: 초 단위
- **statusIcons** (제목 아래 줄) — ItemRow와 동일 패턴: 🔥streak / bell / repeat+요약 / clock+duration. duration 미설정 NTD는 clock 노출 안 함
- 🔥 streak: 반복 NTD의 RoutineCompletion done=true 누적

### NTDGiveUpSheet (포기 사유)
- preset chip 4개 (가로 스크롤): 스트레스 / 다른 일정 / 한계 / 컨디션
- 직접 입력 TextField (`axis: .vertical`, 1~4줄)
- 우선순위: customText 비어있지 않으면 customText, 아니면 selected chip의 localized 텍스트, 둘 다 없으면 nil
- 확인 시 onConfirm(comment: String?) 콜백

### 포기 처리 (1회성·반복 공통)
- `RoutineCompletion(date: occurrenceDate, failed: true, comment: 사유)` 생성
- 1회성: 추가로 `Item.status = .failed`, `completedAt = now` (ListView 완료 노출용)
- 반복: Item.status 유지 (rule 계속)
- `ItemEvent.log(.failed, note: 사유)` 호출 (activity log)
- 1회성→반복 전환 시에도 RoutineCompletion 기록 그대로 보존

### 완료 처리 (체크) — 통합 모델
- **모든 체크는 `RoutineCompletion` 생성**: 1회성/반복 동일. RC = 활동 기록의 단일 source.
  - 반복: RC.date = referenceDate (그 occurrence 날짜)
  - 1회성: RC.date = item.startDate (canonical event date)
- **1회성은 추가로 `Item.status`/`completedAt` cache 유지** — ListView 완료 섹션 fetch에서 빠른 분류용 (`status==1`). 반복은 .pending 그대로.
- 단일↔반복 전환 시 별도 마이그레이션 불필요 (RC가 체크 시점에 이미 생성됨). status reset만 처리.
- 활동 기록 section은 RC만 표시 (합성 row 없음).

### 반복 항목 종료 (Todo·NTD 공통)
- **명시적 "종료하기" 버튼은 두지 않음.** 사용자가 입력 폼에서 `반복 종료일(recurrenceEndDate)`을 오늘/과거로 지정 → 다음 fetch 시 `completeExpiredRoutines`가 `Item.status=done` + `completedAt=now`로 자동 처리.
- 기록(RoutineCompletion/streak/ItemEvent)은 보존.
- 1회성(Todo·NTD)은 별개 경로로 자동 완성됨.
- 향후 별도 종료 액션·버튼을 추가하지 말 것 — UI 단순화 원칙(사용자 결정).

### 활동 로그 (ItemEvent)
- 자동 기록: AddItemView.save (.created/.updated/.completed), AddItemView.deleteItem (.deleted), ItemRow.toggleDone (.completed/.uncompleted), NTDRow.giveUp (.failed), completeExpiredRoutines/completeFinishedNTDs (.completed)
- `note` 필드에 부가 정보 (포기 사유 등) 저장 → ActivityLogView에 caption으로 표시
- itemTitle은 스냅샷 — 원본 삭제돼도 표시 가능
- Settings → 활동 로그 → 시계열 역순 List

### 자동 종료/완성 처리
- 호출 지점: `RootView.task`, `scenePhase == .active`, `ListView.task`, `AddItemView.save()`
- `Item.completeExpiredRoutines(in:)`: 반복 항목(Todo·NTD) 중 `recurrenceEndDate + spanDays < today`이면 status=done. spanDays 보정 → multi-day occurrence가 자연 종료까지 진행 후 완료 (단순 `recurrenceEndDate < today` 만 보면 진행 중 occurrence가 미리 사라지는 버그)
- `Item.completeFinishedNTDs(in:)`:
  - 1회성 NTD (kind=1, recurrenceRule=nil, status=0, duration 설정됨): 종료 instant 지나면 Item.status=done + completedAt
  - 반복 NTD (kind=1, recurrenceRule!=nil): 최근 7일치 occurrence 검사, 종료됐는데 RoutineCompletion 없으면 `done=true` 기록 생성. Item.status 유지.
  - duration=미설정인 NTD는 자동 완성 대상 X (사용자 명시 종료 필요)

### 알림 (Local Notifications)
- `Reminder` 레코드 = anchor(start/due/absolute) + offsetMin (분, 음수=사전).
- **시각 있는 항목** (NTD / Todo hasTime=true): `alertOffsetOptionsWithTime = [0, -10, -30, -60]` (정시/10분/30분/1시간 전)
- **시각 미설정 Todo** (anchor = startDate 0시 기준): `alertOffsetOptionsNoTime = [540, 840, 1140, -180, -1620]` — 당일 오전 9시 / 당일 오후 2시 / 당일 오후 7시 / 1일전 9pm / 2일전 9pm
- NTD: 시작·종료 알림 default ON, Todo: 마감 알림 default OFF.
- **ID 체계**: `"{Reminder.id.uuidString}:{yyyyMMdd}"` — 1 Reminder당 다수 OS notification (occurrence별 1개)
- **Routine 알림 등록**: `Item.syncNotifications()`이 `nextOccurrenceDates(from:maxCount:)`로 future occurrence를 최대 4개 lookahead → 각 occurrence × Reminder 조합으로 등록
- **Refill**: `RootView`가 `.task`/`scenePhase==.active`에서 `Item.refreshAllRoutineNotifications(in:)` 호출 — 백그라운드에서 fire된 슬롯을 재충전 (long-term routine이 끊기지 않음)
- **Wall-clock semantics**: `UNCalendarNotificationTrigger`에 timezone 없는 DateComponents → 여행해도 현지 시간 보장
- **Cancel**: `Item.cancelAllNotifications()` + `cancelNotifications(forReminderID:)`는 prefix 매칭(`"{rid}:"`)으로 일괄 — orphan 방지
- **iOS pending 상한 64개**: occurrence window 4로 보수적 설정 (4 routines × 2 anchor × 4 occurrence = 32). 사용자 항목이 매우 많으면 향후 조정 필요
- **Foreground 배너**: `NotificationService`가 `UNUserNotificationCenterDelegate`로 등록 → `willPresent`에서 `[.banner, .sound, .list]` 반환. 앱이 열려있어도 시각/청각 피드백 + 알림 센터 누적. delegate setup은 `MyDaysApp.init()`에서 `NotificationService.shared` strict touch로 보장

### Settings — Dev section
- "모든 데이터 삭제" 버튼 → `PersistenceController.deleteAllData()`
- 모든 entity의 모든 객체를 fetch + `context.delete` → save (CloudKit propagation 보장)
- 출시 전 `#if DEBUG` 가드 또는 제거 필요
- **App Icon section**: `AppIconView` 시안 미리보기 + 1024×1024 PNG export (caches dir → ShareLink로 빼냄)
  - 색·아이콘 조정은 `Views/AppIconBuilder.swift` 안의 private 상수 변경
  - Asset catalog 텍스트 보기 이슈 발생 시 (Xcode 26 bug) → Xcode 재시작 or 우회: Finder로 직접 PNG를 `Assets.xcassets/AppIcon.appiconset/`에 복사 + Contents.json 편집

### Localization (key-based, all in catalog)
- `Localizable.xcstrings` (Source language `en`. `knownRegions = [en, Base, ko]`. developmentRegion = en)
- 키 네이밍: dot.case (예: `tab.today`, `add.section.recurrence`, `ntd.countdown.remaining`)
- SwiftUI `Text("key")`는 자동 LocalizedStringKey. 사용자 입력(Item.title 등)은 `Text(verbatim:)` 또는 String 분기
- 한국어/영어 분기 (코드): `Locale.preferredLanguages.first?.hasPrefix("ko")` 사용. `Locale.current.language.languageCode`는 실기기에서 신뢰 X
- DateFormatter는 `setLocalizedDateFormatFromTemplate("MdE")` 같이 로케일 자동. 캘린더 날짜 필드는 `timeZone = UTC` 추가
- 12h/24h 표시 감지: `DateFormatter.dateFormat(fromTemplate: "j", ...)` 결과의 'a' 포함 여부
- 일본어/중국어는 catalog에 번역만 추가하면 됨

## Firebase 마이그레이션 prep (진행 중)

3단계(Android 추가) 시점에 동기화를 CloudKit → Firebase로 전환할 때를 대비해 미리 준비한 항목들. 지금은 CloudKit으로 동작 중이지만 모든 변경은 Firebase 호환 모델을 유지한다.

### 완료된 준비
- **모든 entity에 `id: UUID?` 필드**: Core Data objectID는 local-only라 cross-platform sync에 못 씀. UUID가 stable cross-platform 식별자. 모든 entity의 `make()`/생성 지점에서 `id = UUID()` 설정 보장.
- **모든 entity에 `createdAt`/`updatedAt`** (또는 의미상 동등 필드):
  - `Item`: createdAt + updatedAt + completedAt
  - `Category` / `Tag` / `RecurrenceRule` / `Reminder`: createdAt + updatedAt
  - `RoutineCompletion`: completedAt (immutable record → createdAt 역할)
  - `ItemEvent`: timestamp (immutable log)
- **updatedAt bump 일관성**: Item 변경 지점(`toggleDone`, `cancel`, `AddItemView.save`, `completeFinishedNTDs`, `completeExpiredRoutines` 등)에서 모두 `updatedAt = now` 호출. RecurrenceRule.apply()도 자동 bump. Reminder upsert도 동일.
- **nil id 모니터링**: 부팅 시 `PersistenceController.logEntitiesWithMissingID()`가 id == nil row를 entity별로 카운트해 콘솔에 로그 출력. 백필은 안 함 — 출시 전 까지 사용자가 직접 모니터링.

### 남은 준비 (Firebase 도입 시점에)
- **Soft delete (tombstone)**: 현재 hard delete. Cross-device 환경에서 한쪽 오프라인 시 삭제 전파 안 되는 문제. `deletedAt: Date?` 추가 + 모든 fetch predicate에 `deletedAt == nil` 필터 — 영향 범위 큼, 도입 직전에 처리.
- **사용자 scope**: Firestore path `/users/{uid}/items/...`로 사용자 격리. 데이터에는 uid 불필요.
- **clock skew**: Firestore `serverTimestamp()` 또는 가벼운 서버 동기화로 처리. sync 레이어 작성 시.
- **Auth 화면**: Apple Sign In / Google Sign In. 첫 진입 화면 추가.
- **충돌 해결**: updatedAt 기반 last-writer-wins 또는 Firestore transaction. sync 엔진 작성 시.

### 마이그레이션 작업 추정 (3단계 시점)
- Auth + Firestore CRUD wrapper: 3~4일
- 동기화 엔진 (offline queue, conflict, observer): 1.5~2주
- 데이터 마이그레이션 + 테스트: 1주
- 합 ~3~4주

## 최근 완료 (2026-05-27 세션)

### Week strip + Month view (CLAUDE.md 미구현 1번 — 완료)
- `Views/WeekStripView.swift`: 7-cell 요일 strip (요일 + 날짜). 일자 탭 / ±7일 swipe / 슬라이드 transition.
  - 선택일 = solid accent circle. 오늘 = `opacity 0.5` accent circle (선택돼도 selection 우선).
  - `Calendar.current.firstWeekday` 기반 주 시작 (한국=일, 유럽=월).
- `Views/MonthGridView.swift`: 7×N grid (N=4~6 동적, 5주 월은 5행만).
  - 일자 cell 탭 / ±1개월 swipe / 월 단위 슬라이드 transition.
  - **인디케이터**: 단일일자 항목 = dot, 다일 항목 = horizontal bar(slot 할당, 같은 week 안에서 겹치면 stack).
  - **색상**: Todo는 priority 깃발 색(red/orange/blue/secondary), NTD는 항상 teal.
  - **state별 시각**:
    - dot: pending=hollow stroke, completed=filled+opacity 0.25, cancelled=filled+opacity 0.25 (dot에선 완료/취소 동일)
    - bar: pending=솔리드, completed=솔리드 opacity 0.25, cancelled=점선(StrokeStyle dash)
  - dot 최대 12개(6×2행), 초과 시 "+N" overflow.
  - 인접 월 cell도 indicator 렌더 (월 경계는 날짜 숫자 텍스트 dim으로만 구분).
  - HStack(spacing: 0, alignment: .top) 사용 — bar 연속성 + 같은 row cell 정렬.
- TodayView 통합:
  - `@State viewMode: TodayViewMode = .day` — `.day`/`.month` 분기로 `.safeAreaInset(edge: .top)`에 WeekStripView ↔ MonthGridView 교체.
  - Toolbar `calendar` 버튼 = D/M 토글. M 모드 아이콘 = `list.bullet`.
  - navigationTitle: D = "M월 d일 (요일)" / M = "yyyy년 M월".
  - `shiftMonth(±1)` helper로 본문 ZStack 슬라이드도 함께 발동.

### 특정일 이동 (Jump to date)
- Toolbar ellipsis 메뉴에 "특정일로 이동" 항목 (`calendar.badge.clock`).
- DatePicker(`.graphical`) sheet + 우측 상단 **"이동"** confirmation 버튼.
- 자동 닫힘 방식은 wheel scroll과 일자 탭 onChange 구분 못해서 명시적 confirm으로 결정.
- D/M 모드 양쪽에서 사용 가능. local Date ↔ UTC anchor 변환은 `localCalendarSameDay`/`calendarDateAnchor`.

### Lock screen widget (NTD 전용)
- `MyDaysWidget/MyDaysNTDLockWidget.swift`: accessoryRectangular. 자동 회전 (60초 cycle, 30분 window).
  - 3-line layout: icon + 제목 / 큰 카운트다운 (widgetAccentable) / 상태 라벨 "남음/진행/대기".
  - 카운트다운 포맷: "1일 5시간 30분" 형태 (초 안 보임 — iOS가 잠금화면 초를 "--"로 가림).
- `MyDaysWidget/MyDaysNTDLockCircleWidget.swift`: accessoryCircular. 동일 패턴 + 압축 layout.
  - 3-stack: icon (10pt) + HH:mm 카운트다운 (14pt bold) + 상태 라벨 (9pt).
  - `AccessoryWidgetBackground()` 사용 — 캘린더 widget과 같은 원형 배경 효과.
- 둘 다 `NTDLockProvider.fetchRelevantNTDSnapshots(now:)` 공유 — kind 필터 NTD 한정.
- `MyDaysWidgetBundle`에 등록.

### Firebase 마이그레이션 prep (완료 — 상세는 "Firebase 마이그레이션 prep" 섹션 참조)
- 모든 entity에 `id: UUID?` 보유 + 생성 지점 `id = UUID()` 보장.
- `Category`/`Tag`/`RecurrenceRule`/`Reminder`에 `createdAt`/`updatedAt` 필드 추가 (Item·ItemEvent·RC는 이전부터 보유).
- 모든 변경 지점에서 `updatedAt = now` 일관 적용.
- `PersistenceController.logEntitiesWithMissingID()` 부팅 시 nil id row 콘솔 로그 (백필 X).

### 기타 폴리시 (이번 세션)
- ArchiveView/ListView 완료 섹션 토글 아이콘: `checklist`/`checklist.unchecked` (eye/eye.slash 대체).
- 완료 항목 라벨: list mode + 1회성 + done/failed인 Todo는 d-day 자리에 "%@ 완료" / "%@ 취소" (completedAt 시각). `todo.label.done_at_format`, `todo.label.cancelled_at_format` 추가.
- Widget 항목 fetch 최대 10개. budget 기반 cell 자르기 (deterministic 높이 추정 — `widgetContentHeight=142`, `headerHeight=64`, `ntdItemHeight=36`, `todoItemHeight=22`).

## 최근 완료 (2026-05-28 세션)

### 반복 일정 고도화 (Recurrence)
- `Frequency.yearly = 6` 추가. interval(매 N주/N개월/N년) 모든 frequency에 적용. 매년: `nextYearlyOccurrence` year-skip search.
- 매월에 sub-tab `일자지정/조건지정` 추가:
  - **일자지정**: 1~31 grid (기존)
  - **조건지정**: 순번(첫번째~다섯번째/마지막) × 대상(요일 7 + "날") 2행 chip — `weekdayOrdinal` 필드 추가 (Int16?)
- "매월+monthMask≠0" 기존 데이터는 RecurrenceConfig.init이 자동으로 `.yearly`로 노출. 점진적 마이그.
- **DTSTART는 RRULE 매칭 무관 항상 occurrence** (iCal RFC 5545) — `occurs(on:startDate:endDate:)` 시작점에 `if day == startDay { return true }` 추가. 모든 frequency 영향.
- summaryText interval 분기 — "매 2주 수", "2개월마다 1일" 등.

### 카테고리 (Phase A+B 완료)
- `Models/CategoryColor.swift` — iOS system 8색 vivid 팔레트 (red/orange/yellow/green/teal/blue/purple/brown). 앱 tint(TintPreset)와 별도.
- `Models/CategoryIcon.swift` — 18개 SF Symbol preset (life 12 + work/project 6: meeting/document/chart/email/call/folder).
- `Views/CategoryListView.swift` + `CategoryRowView` — `@ObservedObject` 패턴으로 attribute 변경 즉시 반영.
- `Views/CategoryEditSheet.swift` — name + color(8열 LazyVGrid) + icon(6열 LazyVGrid 3행).
- `Views/CategoryPickerSheet.swift` — sheet 기반 picker (Menu의 styling 제약 회피, filled circle + white icon).
- SettingsView에 "분류" 섹션 → "카테고리 관리" NavigationLink.
- AddItemView 카테고리 picker chip (등록 카테고리 0개면 hide).
- ItemRow/NTDRow 제목 앞 3pt × 14pt **세로 bar** (category 색).
- ListView/ArchiveView **카테고리 필터** (`line.3.horizontal.decrease.circle` Menu) — `nil`=모두 + 카테고리들. 필터 활성 시 section header에 카테고리 표시.
- ListView/ArchiveView **그룹핑 모드** (`square.stack` toggle) — 활성 항목 카테고리별 섹션 분리 + 미분류 마지막. 완료는 그룹핑 무시.
- 필터 ↔ 그룹 **상호 배타**: 그룹 ON→filter clear / 특정 카테고리 필터→group OFF.

### 앱 테마 (TintPreset + 다크 모드 선택)
- `Models/AppTheme.swift` — `TintPreset` (Blue 기본 + 7색: coral/peach/mustard/sage/slate/forest/wine) + `AppearanceMode` (system/light/dark).
- `@AppStorage` 키 (`AppThemeKey.tintPreset`, `AppThemeKey.appearanceMode`) — Settings에서 변경, root `.tint() + .preferredColorScheme()`.
- SettingsView "앱 색상" 섹션 — 8 색 circle chips + 라이트/다크/시스템 chip row.
- 입력폼/취소시트 등 "취소·닫기" 버튼은 `.tint(.secondary)` — 테마 색 무관 중립 회색.

### NTD 아이콘 + Today 탭 아이콘
- NTD leading 체크 아이콘 `stopwatch` → `clock` 일괄 교체 (ItemRow/NTDRow/3개 widget).
- Today 탭 아이콘 `checklist` → `\(N).calendar` 동적 (오늘 day-of-month). NSCalendarDayChanged + scenePhase active 갱신.

### Lock Screen Widget — progress
- Circular widget: 테두리 progress arc (`Circle().trim()`) — 진행 중일 때만 표시. 목표시간 있으면 elapsed/total, 없으면 30일 기준 cap.
- Rectangular widget: 3번째 line에 직선 progress bar (Capsule + widgetAccentable). 2번째 line 상태+카운트다운을 홈 위젯 패턴(trailing Spacer + state + countdown)으로 재구성.
- 상태 문구 통일 — Lock rectangular widget이 widget.state.* 키 사용 (시작까지/종료까지/진행 중). 홈 widget의 "경과"도 "진행 중"으로 변경.

### iPad Stage 1 — NavigationSplitView
- RootView에서 `horizontalSizeClass` 분기:
  - **compact (iPhone)**: 기존 TabView 그대로
  - **regular (iPad/Mac Catalyst)**: NavigationSplitView 사이드바(SidebarItem 4항목 — 오늘/목록/보관함/설정) + 디테일
- `.tag(item)`로 selection 매칭. 디테일 view는 NavigationStack 내부에서 switch.
- Catalyst 변환 prep — NavigationSplitView가 Mac에서 native sidebar로 자동 변환.

### 카테고리 진행 중 사소 폴리시
- CategoryListView row tap 영역 — 빈 공간 포함 전체 row tappable (`.contentShape(Rectangle()) + frame(maxWidth: .infinity)`).
- CategoryPickerSheet 옵션도 동일 패턴.
- bar 양끝 round padding 등 MonthGridView 미세 시각 조정.

## 미구현 (다음 후보, 우선순위 순)

### 1. 활동 목표 (Activity Goal) — 3번째 핵심 기능 (다음 진행 예정)

**개념**: 기기 센서 데이터로 자동 판정되는 목표. Todo(사용자 체크)·NTD(사용자 포기)와 구분되는 자동 평가가 정체성.

**예시 (full scope)**:
- HealthKit: 매일 N보 걷기 / N km 뛰기 / N시 이전 자기 / N시간 이상 자기
- Screen Time: 특정 시간 window에 폰 N분 이상 사용 안 함

**MVP 범위 (Phase 1 — 합의)**:
- HealthKit 3종만: 걸음수, 거리, 수면 시간 (취침 시각·ScreenTime 보류)
- ScreenTime API는 entitlement·App Store 승인 복잡 + family/parental 시나리오 최적화라 self-tracking에 제약 큼 → 1차 출시 보류
- 취침 시각은 데이터 정확도 편차(Apple Watch 의존) + "잤다" 정의 모호 → 후순위

**데이터 모델 — 기존 Item entity 확장 (새 entity 추가 X, CloudKit 스키마 영향 최소화)**:
```
Item:
  kind: 0=todo, 1=ntd, 2=activity  ← 추가
  activityType: Int16?              ← 추가 (enum: steps/distance/sleep/...)
  activityTargetValue: Double?      ← 추가 (10000, 5.0, 8.0 etc.)
  activityComparison: Int16?        ← 추가 (gte=0, lte=1, between=2)
```
- `startDate`/`dueDate`/`recurrenceRule`/`startHour`/`dueHour` 재활용:
  - 일자: 기존 그대로
  - 시간 window: `startHour`~`dueHour` 재활용 (예: 22~23시 = "10pm~11pm 평가 window"). 별도 필드 추가 X.
- `RoutineCompletion` 재활용: 자동 평가 결과를 `done=true`로 기록. 사용자 수동 체크 없음 (시스템 평가).

**평가 방식 — iOS 백그라운드 제약 고려**:
- 일별 목표: `scenePhase==.active` / app launch에서 활성 활동 목표 fetch + 평가 → RC 생성/업데이트.
- 시간 window 목표: window 종료 시점에 로컬 알림 trigger → 사용자가 앱 열면 평가 (HKObserverQuery로 일부 백그라운드 가능하지만 모든 항목 지원 X).
- 진행 중 표시: 가능한 한 최근 fetch 값으로 ("7,500 / 10,000 보" 식 progress).

**크로스 플랫폼 추상화**:
```swift
protocol ActivityDataProvider {
    func dailyValue(for type: ActivityType, on date: Date) async -> Double?
    func requestPermission(for type: ActivityType) async -> Bool
}
```
- iOS: `HealthKitProvider` (HKHealthStore + HKQuery).
- Android (이후): `HealthConnectProvider`.
- 모델 자체는 OS-independent.
- **합의**: iOS 먼저 구현 + 안정화 후 Android port. 동시 설계 시 lowest-common-denominator로 가서 OS 강점 사라짐.

**UI**:
- AddItemView: kind picker에 "활동 목표" 추가. type 선택 시 unit/comparison 동적 라벨 (예: steps → "이상", "보"; sleep → "이상", "시간").
- TodayView: NTD 섹션 옆 또는 별도 섹션. 진행률 bar 또는 "7,500 / 10,000 보" 텍스트. 자동 완료 시 체크 표시 (회색 + 라벨 dim).
- ItemRow: leadingControl을 활동 목표 전용 아이콘(달성 X = outline / 달성 O = fill)으로 분기.

**구현 순서 (Phase 1)**:
1. `Item` 모델 확장 — activityType / activityTargetValue / activityComparison + ItemKind enum 확장. CloudKit migration 1회.
2. `ActivityDataProvider` 프로토콜 + `HealthKitProvider` 구현 (걸음수·거리·수면 3종). 권한 요청 흐름.
3. AddItemView 활동 목표 입력 UI.
4. TodayView 활동 목표 노출 (4번째 섹션 또는 NTD에 통합 검토).
5. `MyDaysApp` launch / `scenePhase==.active`에서 활동 목표 평가 실행 → RC 생성.
6. window 목표 시 로컬 알림 trigger.
7. ItemRow leadingControl 분기.
8. (이후) Android port + Health Connect.

**결정 필요 (시작 전)**:
- MVP type 범위 — 위 3종 확정?
- 직접 완료 마킹 허용? (백업 경로 — 데이터 fetch 실패 케이스). 권장: 허용 (NTD처럼 사용자 override 가능)
- 데이터 부족(Apple Watch 없음 등) 사용자 안내 정책.
- HealthKit 권한 거부 사용자 처리 — 활동 목표 생성 비활성화 vs 생성은 허용하되 평가 불가 표시.

**참고**:
- HealthKit: `NSHealthShareUsageDescription` + entitlement 필요.
- HKObserverQuery + `enableBackgroundDelivery`로 백그라운드 wake-up 가능 (Steps·Sleep 지원). 단 빈도 제한.
- 권한 prompt UX 신중히 — 한 번에 여러 type 요청보다 type별 lazy 요청 권장.

### 2. 카테고리·태그 관리 UI
- Category 입력/편집 화면 (현재 모델은 있지만 UI 없음 — 생성 진입점 X).
- 목록·보관함에 category/tag 필터 추가.
- Tag도 동일 (다중 선택 가능 모델).
- 새 생성 지점에서 `id = UUID()` + `createdAt`/`updatedAt = now` 필수 (Firebase prep).

### 3. 3단계 계층 구조 (parent/children)
- AddItemView에 parent picker.
- 표시(들여쓰기) — 깊이 제한 3단계 (앱 로직, Core Data는 unlimited).
- 부모 완료 시 자식 처리 정책 결정 필요.

### 4. 알림 후속 개선
- 알림 탭 → 항목 편집 화면 deep link.
- 권한 거부 후 Settings 재안내 경로.
- pending 한계(64) 초과 시 graceful 처리.

### 5. 항목별 활동 기록 view
- 현재 AddItemView 활동 기록 섹션은 최근 10건만.
- 별도 화면에서 전체 시계열 (Todo/NTD 공통).
- ActivityLogView ↔ RoutineCompletion 이원화 유지 (lifecycle vs per-occurrence).

### 6. Month view Phase 3 — grid 인프라 재활용
- 반복 NTD/Todo 전용 history view에 같은 grid 컴포넌트 사용 (성공/실패 색 dot 등 indicator만 교체).
- MonthGridView를 prop 기반(`cellDecorator: (Date) -> some View`)으로 일반화 필요.

### 7. iPad 최적화
- 합의: **앱 완성 후 일괄 작업**.
- NavigationSplitView, 2-pane, Regular size class.

### 폴리시 / 후속
- SpeechRecognizer Phase B 발전 — 자체 mic UI 풍부화 (waveform 등). 현재는 hands-free 용.
- Settings "모든 데이터 삭제" 버튼 출시 전 `#if DEBUG` 가드 또는 제거.
- `completeExpiredRoutines` 호출 위치(현재 4곳) 성능 측정 후 최적화 후보 — 현재 보류.

## 디자인 / 코드 가이드라인

- **꼭 필요한 기능만, 최대한 단순화. 입력 편의성 우선.**
- 사용자 멘탈 모델 우선. 데이터 모델은 백킹.
- 새 Core Data 변경: 모든 attribute optional + 양방향 inverse + Nullify/Cascade 신중히 (CloudKit 호환). NSNumber? for "nil/0 구분 필요" Int.
- 상태 변경 지점에서 일관되게 `ItemEvent.log(_:on:in:note:)` 호출. 포기 사유 등 부가 정보는 `note`로.
- 캘린더 날짜 비교/연산은 항상 `Calendar.gmt`. `Calendar.current`는 instant 처리·UI hour cycle 감지 등에서만.
- SwiftUI Text literal은 가능한 LocalizedStringKey 활용. 동적 텍스트는 `String.localizedStringWithFormat(NSLocalizedString(...))` 또는 `String(localized:)`
- 사용자 데이터 표시는 `Text(verbatim:)` (localize 회피)
- 한국어/영어 분기는 `Locale.preferredLanguages.first?.hasPrefix("ko")`. `Locale.current.language.languageCode`는 실기기에서 신뢰 X
- iOS 26+ API는 `#available(iOS 26.0, *)` 가드 (deployment 17.6 유지)
- UIKit Programmatic 도입 자제. 정말 필요할 때만 `UIViewRepresentable`
- 깃발 아이콘 (priority) 색상은 선택 여부 무관 항상 표시 (사용자가 색으로 식별)
- chip 스타일: 선택 시 fill, 미선택 시 stroke (lineWidth 동일 → layout shift 없음)
- 선택 상태 배경: `Color(.secondarySystemFill)` 권장 (다크·라이트 모두 명확)
- 다중 `.alert`을 같은 view에 부착하면 두 번째가 무시되는 SwiftUI 동작 → 각 Button에 부착하거나 `.alert + .confirmationDialog` 조합 사용

## 알려진 제약 / 노이즈

- **첫 키보드 활성화 ~5초**: iOS 시스템의 텍스트 입력 세션 초기화 비용. 워밍업 트릭은 부작용으로 미적용.
- **iOS 17~25 toolbar capsule**: 같은 placement의 ToolbarItem들이 단일 capsule로 묶이는 시스템 디자인. `ToolbarSpacer`는 iOS 26+ only.
- **TodayView navigation title이 작은 화면(17 Pro)에서 왼쪽으로 약간 치우침**: 좌우 toolbar item 폭 비대칭. invisible balance 시도했으나 capsule 늘어남으로 철회. 수용 결정.
- **SwiftUI wheel Picker 무한 회전 미지원**: 12h 모드 시간 선택은 1~12를 두 번 노출 + cell에 "오전/오후" 포함하여 lag 회피. 진정 무한 wheel 필요 시 UIPickerView 커스텀 필요.
- **SwiftUI .alert 다중 부착 한계**: 같은 view에 두 개 stacking 시 두 번째 무시. Button별 부착 또는 .alert + .confirmationDialog 조합으로 해결.
- **AddItemView simultaneousGesture(TapGesture)**: Form 하단 Button 탭과 충돌. 빈 영역 탭 dismiss 포기, scroll dismiss로 대체.
- **ItemRow NTD 카운트다운 자동 갱신 없음**: TimelineView 미부착. 다음 fetch 갱신 시까지 stale 가능.
- 콘솔 노이즈 (`remoteTextInputSession…`, `Gesture: System gesture gate timed out`, `Result accumulator timeout` 등)는 iOS 자체 이슈로 무시.
- **`updateTaskRequest failed for com.apple.coredata.cloudkit.activity.export.…`** + `BGSystemTaskSchedulerErrorDomain Code=3` — Core Data+CloudKit이 동적 UUID로 BGTaskScheduler 등록 시도하다 dev/Xcode 환경에서 거부됨. CloudKit sync 자체는 push notification으로 정상 동작. 출시 빌드에선 거의 안 보임.

## 사용자 컨텍스트

- 익숙: Swift, Java. native 개발 선호 (크로스플랫폼 X).
- 응답 스타일: 짧고 빠른 결정. UX 디테일에 민감.
- 진행 방식: 기능 단위로 만들고 → 실기기에서 확인 → 짧은 피드백 → 반영.
- 메모리 시스템은 머신 로컬에 저장됨. 회사(맥미니)와 집(맥북) 양쪽에서 작업하므로 이 CLAUDE.md가 컨텍스트 동기화의 1순위.
- 두 기기 모두 동일 경로 `/Users/diokim/Work/mywork/mydays/mydays_ios/MyDays` 사용 권장 (메모리 sanitized path 동일).
- 코드 수정 시 주석 잘 달기 — 특히 timezone, NTD 의미, SwiftUI 우회 사유 등 비-자명한 부분.
