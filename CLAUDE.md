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
- 시각 (wall-clock 정수): **startHour** (Int16?, 0~23 — Todo·NTD·습관 공통), **dueHour** (Int16?, 0~24 — Todo만)
  - **단순화 모델**: accessor `startHourInt`/`dueHourInt`는 non-optional Int. nil 데이터는 0(start)/24(due)로 default 해석. 신규 save는 항상 명시 값.
  - **24는 sentinel** — "시간 미설정 = 다음 날 0시" 의미. `Item.hasExplicitTime` = `dueHourInt < 24`.
  - 모든 dated 항목이 `(effectiveStartInstant, effectiveDueInstant)` 쌍으로 통합. `Item.localInstant(...)`는 hour=24를 다음 날 0시로 변환.
  - **NTD는 dueHour 미사용**이지만 AddItemView가 `dueHour=startHour`로 sync 저장 (재진입 시 hasTime=true 보장 위해). NTD 실제 종료는 duration 기반.
  - **습관은 startHour=0/dueHour=24 고정** (종일 의미). 시각 UI 비노출.
- 시간대 legacy (현재 UI 미사용): **startTimeOfDay**, **dueTimeOfDay** (오전/오후/저녁/none)
- NTD 전용: **ntdDurationHour** (Int16?, nil=미설정/한계까지, 최대 24시간)
- **목표 공통(절제/활동/집중/습관) — 사용자 지정 아이콘·색** (카테고리 미사용):
  - **iconName** (String?) — semantic identifier (예: "run", "fast", "water"). Android 호환 — SF Symbol 이름 직접 저장 아님. iOS는 `GoalIcon.symbolName`으로 매핑.
  - **iconColorHex** (String?) — `CategoryColor` rawValue ("red", "blue" 등) 재활용.
- **활동(activity) 전용**:
  - **activityTargetValue** (Double?) — 목표 수치 (예: 100, 10000)
  - **activityUnit** (String?) — "회", "L", "km", "보"
  - **activitySourceType** (Int16?) — 0=manual, 1=steps, 2=distance, 3=calories, 4=flights (1~4=HealthKit)
- **집중(focus) 전용** — 활동 모델 재활용. `activityTargetValueDouble`=target 분, `RC.valueRecorded`=누적 분, `activityUnit="분"`. 별도 필드 없음.
- 포기 사유는 `RoutineCompletion.comment` + `ItemEvent.note`에 저장. Item 차원의 comment 필드는 제거됨.
- self-relation: parent/children (3단계 계층은 앱 로직에서 강제)
- 관계: category(Todo 전용), recurrenceRule, reminders, completions, events, checklistItems

### RecurrenceRule
- frequency, interval, weekdayMask, **dayOfMonthMask (Int64, bit 0~30=일자, bit 31=말일)**, **monthMask (Int16, 0=모든 월)**, countPerWeek (legacy), dayOfMonth (legacy), startDate (legacy, 미사용), endDate (legacy, 미사용)
- **Item.startDate를 anchor로 사용**, Item.dueDate를 반복 종료일로 사용
- helper: `selectedWeekdays/Days/Months`, `includesLastDay`, `occurs(on:startDate:endDate:)`, `nextOccurrence(after:startDate:endDate:)`, `make(in:)`

### RoutineCompletion (per-occurrence 기록)
- id, **date** (UTC anchor), **done**, **failed**, **comment**, **valueRecorded** (Double? — 활동 누적값), completedAt, item
- 의미:
  - `done=true, failed=false` → 성공 (자동 완성 / Todo·습관 체크 / 활동 target 달성)
  - `done=false, failed=true` → 포기 (사용자 종료, NTD)
  - record 없음 → 미참여
- 1회성 NTD도 포기 시 동일하게 사용 — 1회성↔반복 전환 시 기록 보존
- Streak 계산 기반

### Category / Reminder / RecurrenceRule / ChecklistItem / ChecklistCheck
- **Category (Todo 전용 — 목표는 미사용)**: id, name, colorHex, iconName, sortOrder, createdAt, updatedAt, defaultTodo{Timed,Untimed}{Start,Due}AlertOffset 4종
  - 2026-05-30: `isDefaultForNTD`, `defaultNtdStart/DueAlertOffset` 필드 제거 (목표는 카테고리 미사용 정책)
- Reminder: id, fireDate, offsetMin, anchor, repeats, createdAt, updatedAt
- RecurrenceRule: id, frequency, interval, weekdayMask, dayOfMonthMask, monthMask, createdAt, updatedAt, (legacy attrs)
- ChecklistItem: id, title, sortOrder, createdAt, updatedAt, **deletedAt** (soft delete), item(Cascade), checks(→ ChecklistCheck Cascade)
- ChecklistCheck: id, occurrenceDate(UTC anchor), completedAt, checklistItem(Nullify)
- **Tag entity는 제거됨 (2026-05-29)** — 사용자 결정. 향후 검색 기능에서 notes의 `#xxx` 패턴으로 처리 (별도 entity 없이 텍스트 기반).
- 모든 entity에 `id: UUID?` + `createdAt/updatedAt: Date?` — Firebase 마이그레이션 prep (last-writer-wins 충돌 해결, cross-platform ID stable). 자세한 정책은 "마이그레이션 prep" 섹션 참조.

### ItemEvent (활동 로그)
- timestamp, action, itemTitle(snapshot), **note**(부가 정보 — 포기 사유 등), item(Nullify) — Item 삭제돼도 보존

### Enum 매핑 (`Models/ModelEnums.swift`)
- **ItemKind**: 0=todo, 1=notTodo(절제), **2=activity(활동)**, **3=focus(집중)**, **4=habit(습관)**
  - `displayName` localized. `isGoal` = `self != .todo` (절제+활동+집중+습관 통합 그룹).
  - `goalTypeSymbolName` — sub-picker용 SF Symbol (절제=hand.raised.fill, 활동=figure.run, 집중=timer, 습관=checkmark.square.fill)
  - `isAvailableForInput` — 모든 case true (4-type 모두 입력 가능).
- **Priority**: 0=none, 1=medium, 2=high, 3=low. `displayName` localized
- **Status**: 0=pending, 1=done, **2=deleted (legacy/soft-delete 예약)**, **3=failed (NTD 포기 또는 1회성 NTD 사용자 종료)**
- **Frequency**: 0=daily, 1=weekly, 2=monthly (3=weekdays, 4=weekend, 5=weeklyCount는 legacy, 미사용)
- **TimeOfDay**: 0=none, 1=morning, 2=afternoon, 3=evening
- **ItemAction**: 0~7 (created/updated/completed/uncompleted/cancelled[legacy]/restored/deleted/**failed**). 모두 localized
- **ActivitySourceType**: 0=manual, 1=steps, 2=distance, 3=calories, 4=flights (1~4 모두 HealthKit). `displayName` localized.
- **GoalIcon** (`Models/GoalIcon.swift`): 12 case enum + `symbolName` accessor. **rawValue("run", "fast", ...)가 DB에 저장** (cross-platform 호환). iOS는 symbolName으로 SF Symbol 매핑.

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
| `Item.startHour` | wall-clock 시 (정수, Todo/NTD/Activity 공통) | local에서 해석 |

### CalendarDate helpers (`Models/CalendarDate.swift`)
- `Calendar.gmt`: UTC 고정 그레고리안 캘린더
- `Date.calendarDateAnchor`: local에서 읽은 (y,m,d)를 UTC 자정 instant로 정규화 (DatePicker 결과 저장 시)
- `Date.localCalendarSameDay`: UTC anchor → local 같은 (y,m,d) 자정 (DatePicker 초기값 표시 시)
- `Date.todayCalendarAnchor`: local 기준 "오늘"의 UTC anchor — 비교 기준점

### DateFormatter
- 캘린더 날짜 표시: `formatter.timeZone = TimeZone(identifier: "UTC")` (또는 .gmt) 강제
- instant 표시 (활동 로그 등): `Calendar.current` 그대로

### NTD 시각 정책 (wall-clock semantics)
- NTD startDate는 calendar date(UTC anchor) + startHour(wall-clock 정수)
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
│   ├── SpeechRecognizer.swift       SFSpeechRecognizer + AVAudioEngine wrapper (ko-KR, on-device)
│   ├── HealthKitService.swift       HKHealthStore wrapper. fetchTodayValue / requestAuthorization (steps/distance/calories/flights)
│   ├── Item+HealthKitSync.swift     scenePhase=.active 시 auto-source activity 항목 RC.valueRecorded sync (main target only)
│   ├── FocusSessionManager.swift    singleton ObservableObject. single-active 세션, elapsed 누적 (10분 미만 폐기)
│   └── Item+FocusSession.swift      addFocusMinutes / focusCurrentMinutes — RC.valueRecorded에 분 단위 누적 (main target only)
└── Views/
    ├── RootView.swift               TabView + .task/scenePhase에서 completeExpiredRoutines + completeFinishedNTDs + syncHealthKitActivities 호출
    ├── TodayView.swift              부모(displayedDate UTC anchor) + TodayList(섹션 fetch + NTD 필터)
    ├── ListView.swift               전체 + 완료 토글. 완료 섹션 = status 1 OR 3 (NTD failed 포함)
    ├── ArchiveView.swift            isSomeday=YES 항목 + 하단 QuickEntryBar
    ├── SettingsView.swift           동기화/활동/정보 + Dev: 모든 데이터 삭제 + App Icon export
    ├── ActivityLogView.swift        시계열 ItemEvent 표시 (note 포함)
    ├── AddItemView.swift            입력/편집/삭제 통합. kind picker (4-type 목표) + 활동/집중 target·source 입력 + 활동 기록 표시
    ├── ItemRow.swift                Todo/Routine/NTD/habit/activity/focus 통합 row. type별 trailing 분기 (habit=체크, activity=progress+(+N), focus=progress+▶)
    ├── NTDRow.swift                 TodayView NTD 전용 row (Adaptive schedule, statusIcons, (x) 포기 버튼)
    ├── FocusSessionView.swift       집중 fullScreen UI. CoreMotion 흔들림 감지 + scenePhase=.background 자동 종료 + idleTimer disable
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

### 동기화 토글 정책 (CloudKit ↔ Firebase, 2026-05-29 결정)
**왕복 전환 지원**. 단순 토글 의도가 아니라 기기 lifecycle (iPhone↔Android↔iPhone) 시나리오 대응.

- **Phase 1 (현재)**: CloudKit 자동 (NSPersistentCloudKitContainer). 토글로 OFF만 가능 (`cloudKitContainerOptions = nil`, local-only).
- **Phase 3 (Android 추가)**:
  - 첫 진입 시 선택: "iCloud / Firebase" (각 폰 별도, 동기 X)
  - Settings에 "동기화 방식 변경" 토글 → 변경 시 alert + migration UX
  - **각 전환 = migration 이벤트** (가볍지 않음 — 데이터 일괄 upload).
- **전환 흐름** (예: CK → FB):
  1. 사용자가 "Firebase로 전환" 누름 → 경고 dialog (현재 폰 data를 FB로 push, 다른 기기는 별도 설정 필요).
  2. CK options 끊기 (`cloudKitContainerOptions = nil`).
  3. Local DB → FB 일괄 upload (auth 후).
  4. 이후 변경은 FB sync layer만.
  - CK 클라우드 데이터는 Apple이 보존 — 사라지지 않음. 다시 CK로 돌아갈 때 살아있음.
- **재전환 (FB → CK 등) 충돌 해결**:
  - CK 클라우드 쪽 옛 데이터(전환 전 잔여) + 폰의 현재 데이터 → `updatedAt` 기반 last-writer-wins.
  - 모든 entity의 `updatedAt` 일관 갱신 정책으로 이미 대비됨 ("Firebase 마이그레이션 prep" 섹션 참조).
- **다른 기기**: 각자 별도로 토글. 한 기기에서 토글했다고 다른 기기 자동 전환 X (자동화 시 위험).
- **데이터 안전망**: JSON export 기능 별도 제공 (사용자 수동 백업 가능).

### 마이그레이션 작업 추정 (3단계 시점)
- Auth + Firestore CRUD wrapper: 3~4일
- 동기화 엔진 (offline queue, conflict, observer): 1.5~2주
- 데이터 마이그레이션 + 테스트: 1주
- **양방향 토글 + 충돌 해결**: 추가 1주 (Phase 1만 가는 게 아니라면)
- 합 ~3~4주 (편도) 또는 ~4~5주 (양방향)

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

### Widget budget 최적화 (3 위젯 공통)
- **Tiered granularity timeline** — 다음 transition(NTD 시작/종료 instant)까지 거리 기반 step:
  - `> 1h`: 30분 step / `20m~1h`: 5분 step / `< 20m`: 1분 step
  - transition 없음 (duration 미설정 NTD / 빈 상태): 1시간 step (fallback)
- Transition 시점은 step 무시하고 entry에 강제 포함 — 시작 전 → 진행 중 → 종료 state flip 보장.
- Horizon 6시간, `reloadAt = entries.last + 60s`. Timeline당 ~13~30 entries, 일일 reload ~4~10회 — Apple budget(~40~70/day) 안에 여유.
- **Home widget만 <1분일 때 시스템 라이브 카운트다운** 사용:
  ```swift
  if remaining > 0 && remaining <= 60 {
      Text(timerInterval: entry.date...target, countsDown: true, showsHours: false)
  } else {
      Text(verbatim: formatDuration(for: snap, now: entry.date))
  }
  ```
  - `Text(timerInterval:)`는 시스템이 budget 없이 직접 갱신.
  - Lock 위젯은 OS가 잠금화면 초를 `--`로 가려서 의미 없음 → pre-computed `formatDuration` 유지.
- Progress bar/arc도 entry.date 기반 (별도 inner TimelineView 제거 — budget 차감 회피).

### 오늘탭 카테고리 필터 (ListView 패턴 이식)
- TodayView에 `@State filterCategoryID: UUID?` + `@FetchRequest categories` + `categoryFilterMenu` 추가. ListView/ArchiveView와 동일 UX (`line.3.horizontal.decrease.circle` Menu).
- `categoryFilter` prop으로 TodayList + MonthGridView에 전파. MonthGridView는 `filteredItems` computed로 dot/bar 인디케이터 적용.
- TodayList `matchesCategoryFilter` helper를 `ntdsForDate` / `routinesForDate` / `todoActivityRows` 모두에 적용. (초기에 todoActivityRows 누락 → 필터 미동작 버그 fix).
- **필터 활성 시 신규 항목 카테고리 자동 preset**: `ItemSheetMode.new(baseDate:categoryID:)` 추가 + `AddItemView(editing:baseDate:categoryID:)`에서 `_selectedCategoryID = State(initialValue: categoryID)`. TodayView/ListView/ArchiveView (QuickEntryBar quickSave 포함)의 모든 신규 시트 진입에 적용.

### Section header 카테고리 아이콘 (오늘/목록/보관함 통일)
- 필터 활성 시 section header에 filled circle + white SF Symbol 표시 (카테고리 색상). 명칭은 표시 안 함 (오늘탭 정책 — 단순화 우선).
- 크기 통일: `font: .system(size: 11, weight: .semibold)`, `frame: 20×20`. (기존 ListView/ArchiveView는 18×18이었음 → 20×20으로 맞춤.)
- 위치: 섹션 타이틀 바로 오른쪽 (`HStack(spacing: 6)`, Spacer 없음 — 완전 우측 정렬 X).
- ListView/ArchiveView는 그룹 모드일 때 이름과 함께 표시 (카테고리별 섹션 분리이므로 식별 필요).

### Row 카테고리 bar 정렬
- 제목 앞 3pt × 14pt 세로 bar (카테고리 색). 기본 baseline 정렬 시 위로 튀어 보이는 문제 해결:
  ```swift
  .alignmentGuide(.firstTextBaseline) { d in d.height * 0.9 }
  ```
- ItemRow + NTDRow 동일 적용. multiplier 0.9로 정착 (0.8 너무 내려감, 0.85 살짝 부족).

### 빈 상태 / 라벨 변경
- `today.section.not_todo` 한글: "절제 목표" → "목표" (영문 "Fast" 유지)
- `today.empty.not_todo`: "진행 중인 목표 활동이 없습니다" / "No active fasts"
- `today.empty.todo`: "진행 중인 할일 일정이 없습니다" / "No active todos"
- `archive.empty`: "보관 중인 할일이 없습니다" / "No archived tasks"

## 최근 완료 (2026-05-29 세션)

### 체크리스트 기능 (신규)
- 데이터 모델 (entity 2개 추가):
  - `ChecklistItem`: id, title, sortOrder, createdAt, updatedAt, **deletedAt** (soft delete), item(Cascade), checks(→ ChecklistCheck Cascade).
  - `ChecklistCheck`: id, occurrenceDate(UTC anchor), completedAt, checklistItem(Nullify).
  - Item에 `checklistItems` 관계 추가.
- 표시 정책 = **합집합**: active(deletedAt==nil) ∪ (soft-deleted 중 그 occurrence에 check 있는 것). 부모 항목 삭제 시에도 historical check 보존됨.
- occurrenceDate 규약:
  - **반복**: 각 occurrence start date (UTC anchor) — per-occurrence 기록.
  - **1회성/Someday**: `Item.nonRoutineChecklistOccurrence` sentinel (`Date.distantPast`의 UTC startOfDay) — 단일 bucket. `item.startDate`가 바뀌어도 매칭 보존. 1회성↔반복 전환 시 자동 마이그 X (DB 보존만 됨, 원상태 돌리면 복원).
- 헬퍼 (`Models/ChecklistItem+Helpers.swift`):
  - `markDeleted()`, `isActive`, `isChecked(forOccurrence:)`, `checkRecord(forOccurrence:)`.
  - `Item.checklistOccurrenceDate(occurrenceStartOverride:referenceDate:)`, `displayedChecklist`, `checklistProgress`, `hasDisplayableChecklist`, `toggleChecklistCheck`.
- AddItemView 입력 UI (`checklistSection`):
  - draft 배열 hold + save 시 `reconcileChecklist(item:)`로 동기화 (Reminder 패턴 동일).
  - 빈 제목 draft는 save에서 skip. minus 버튼은 draft 배열에서만 제거 → save에서 existing은 `deletedAt` 마킹.
  - TextField submit으로 연속 입력 (`.submitLabel(.continue)` + `onSubmit`): 입력 있으면 새 draft 자동 추가 + 포커스 이동, 빈 draft에서 submit하면 그 draft 제거 + 키보드 dismiss.
  - `+ 항목 추가` 버튼 row 전체 hit area: `.frame(maxWidth: .infinity, alignment: .leading) + .contentShape(Rectangle())`.
- ItemRow chip + inline expand:
  - **Non-compact**: statusIcons 줄 맨 앞에 chip(`☑ N/M ›`).
  - **Compact** (그룹 routine): title 바로 아래 별도 줄.
  - Expand는 rowContent **밖 sibling**으로 부착 (`.padding(.leading, 40)`으로 leadingControl 폭+spacing만큼 indent). 안에 두면 inner VStack이 height 흡수해 title이 center로 떠 보임.
  - 체크박스 토글: `Item.toggleChecklistCheck` + 부모 `item.updatedAt = now`도 함께 갱신 — `@ObservedObject(item)`가 child ChecklistCheck 변경을 자동 관찰 못해 row body 재평가 안 되는 문제 회피.

### ItemRow 체크리스트 expand 애니메이션 (정착)
- 모든 expand 애니메이션 **제거** — 사용자가 instant 변경 + title 상단 고정을 원함.
- `rowContent`에 `.animation(nil, value: checklistExpanded)` 한정 부착 — title 자리이동 보간 차단.
  - **주의**: outer VStack에 부착하면 FetchRequest의 row 제거(완료 체크 fade-out) 애니메이션까지 같이 죽음 → 체크리스트 있는 항목 완료 시 row가 안 사라짐.
- chip에 `.transaction { animation = nil; disablesAnimations = true }` — 외부 ambient animation(List row resize 등)이 chip 텍스트/아이콘을 위/아래로 끌고 가는 현상 완전 차단.
- chevron은 단순 `.rotationEffect(.degrees(checklistExpanded ? 90 : 0))` (애니메이션 없이 즉시 회전).
- 시도하다 폐기한 것들 (참고용 — 같은 함정 피하기):
  - `.transition(.opacity)` + `withAnimation`: title이 위로 보간되어 어색.
  - `.scale(scale: 0, anchor: .top)`: uniform이라 너비도 줄어 어색.
  - 커스텀 `.scaleEffect(x:1, y:scale)` (VerticalRevealModifier): scaleEffect는 layout 안 변해 row 높이가 한 번에 늘어남.
  - `.frame(maxHeight: .infinity)`: `.infinity`는 SwiftUI 보간 불가 → 즉시 변함.
  - `.frame(height: estimatedHeight)`: List row가 ambient animation으로 chip만 끌고 감.

### ItemRow 완료 체크 버그 fix
- `pendingCompletion` 영구 유지 버그: `performComplete`의 0.5s deferred mutation 끝 + `toggleDone` uncheck path에서 `pendingCompletion = false` 명시 → uncheck 즉시 시각 반영.
- 체크리스트 있는 항목 완료 fade-out 안 됨: `.animation(nil, value:)` scope를 outer VStack → rowContent로 한정 (위 항목 참조).

### Widget budget 재조정 (tier granularity)
- Tier 변경: 3시간/1시간/20분 경계로 4단계 + 미설정.
  - `> 3h`: 30분 step / `3h ~ 1h`: 10분 step / `1h ~ 20m`: 5분 step / `< 20m`: 1분 step / transition 없음: 1h step.
  - 멀리 있는 시점은 30/10분 정밀도면 충분, 가까울수록 fine-grained. budget 영향 없음 (reload 4/day 유지).
- `formatDuration` 3시간 cutoff: `hours >= 3`이면 분 단위 제거 ("5시간 30분" → "5시간"). 1h~3h(5min step 영역)는 분 노출. tier가 10/30분 step인 구간에서 분 정확도가 떨어져 혼란 주는 문제 해결.

### 위젯 카테고리 아이콘 + 앱 tint
- `ItemSnapshot`에 `categoryIconName: String?` + `categoryColorHex: String?` 추가. 3 snapshot 생성 지점 + Lock widget fetch에서 populate.
- Home widget:
  - 카테고리 있음: `categoryIconName` symbol (색은 모든 항목 통일 app tint — 카테고리 색상별로 표시하면 무지개라 시각 균형 깨짐).
  - 미설정: `clock`/`circle` + 앱 tint.
- Lock widgets: icon symbol만 카테고리 적용, 색은 시스템 tint(widgetAccentable)에 위임.
- 위젯 process에서 사용자 tint 읽기 — App Group 공유 UserDefaults (`group.io.snapplay.MyDays`, entitlement 양쪽 이미 보유):
  - `UserDefaults.appShared` static 추가, `TintPreset.currentColor` helper.
  - 모든 `@AppStorage(AppThemeKey.*)` 사용처에 `store: .appShared` 명시 (MyDaysApp / SettingsView / AppTintModifier).
  - pbxproj: widget target에 `AppTheme.swift`, `CategoryColor.swift` 멤버십 추가 (membershipExceptions에 명시).

### Category 알림 default Todo 4종 재구성
- `defaultTodoTimedAlertOffset` 1개 → `defaultTodoTimedStartAlertOffset` + `defaultTodoTimedDueAlertOffset` 분리. Untimed start/due와 함께 총 5종(NTD 2 + Todo 4).
- AddItemView: 카테고리 선택/변경 + `hasTime` 토글 + 기간 chip ON 시 `reapplyTodoAlertDefaults()` → 카테고리 default 재적용. 옵션 세트(withTime/noTime)가 달라 nil reset만 하면 카테고리 의도 잃음 — 사용자가 명시 설정 안 했어도 카테고리 default 유지.

### CategoryIcon 정리
- 사용자 피드백 반영: pawprint → `pawprint.fill`, 제거: `pray`/`cat`, 추가: `hashtag`(`number`)/`pin`(`mappin.and.ellipse`), `dog` → `pawprint`, `programming`: `curlybraces` → `chevron.left.forwardslash.chevron.right`(`</>`).
- 그룹별 재정렬: 업무·생산성/건강·뷰티/생활·식사·장소/여가·여행/관계·SNS/동물·자연/기타. 총 36개.

### NTD progress capsule (trailing 영역)
- NTDRow의 trailing 영역(기존 카운트다운 텍스트 자리)을 capsule progress bar로 교체. **진행 중일 때만** 노출, 시작 전/완료/포기는 plain text.
- 140×22pt Capsule: 배경 `systemGray5` + accent.opacity(0.35) fill (leading→progress 비율) + 카운트다운 글자 trailing 정렬 overlay (`.padding(.trailing, 8)`, `minimumScaleFactor(0.85)`).
- 최소 가시 폭 4pt — progress > 0이면 매우 낮아도 살짝 보임.
- duration 없으면 30일 기준 cap (위젯 `progressArc`와 동일 정책).
- 글자 색 — 라이트: `Color.accentColor` semibold (black은 fill 톤과 부딪혀 어색), 다크: `.primary`(white) semibold (`@Environment(\.colorScheme)`로 분기).
- compactMode 무관 모든 row가 자기 trailing에 progress 표시 → 그룹 안 multi-day NTD에서 어제 occurrence 진행률 안 보이던 버그 자연 해결.

### iOS 26 floating 탭바 opaque 회귀 fix
- TodayView body 외곽 ZStack에 부착돼 있던 `.clipped()` 제거 → iOS 26 TabView가 scroll content edge 감지하면서 floating 탭바 반투명 동작 복원 (다른 탭과 일관). 슬라이드 transition overflow는 navigation bar / safeAreaInset / 화면 가장자리로 이미 자연 bound됨.
- 부작용 — safeAreaInset(WeekStrip/MonthGrid)의 암묵 backdrop이 사라져 List 본문이 비침: inset content에 `.background(Color(.systemBackground))` 명시 부착.
- 알려진 제약 / 노이즈 섹션에 회귀 방지용 기록 추가 (`.clipped()` 부착 금지).

### TodayView NavigationStack tint propagation 보강
- 증상: WindowGroup `.tint()`이 적용됐는데 TabView 내부 NavigationStack 본문(WeekStrip 선택일·FAB·ItemRow checkbox)에서 `Color.accentColor`가 시스템 blue로 fallback. toolbar/tabbar는 정상 themed였음 → iOS 26에서 일부 끊김.
- iPhoneLayout의 각 NavigationStack에 `.appTint()` 명시 적용. iPadLayout detail의 NavigationStack에도.

### Sheet `.appTint()` 적용 — 사용자 tint 보존
- `.graphical` DatePicker / sheet 안 NavigationStack 등 UIKit-bridged 컴포넌트가 sheet에서 root tint를 잃고 시스템 blue로 fallback되는 케이스 방어.
- `AppTheme.swift`에 `appTint()` ViewModifier (`@AppStorage(AppThemeKey.tintPreset)` 직접 읽고 `.tint()` 재적용) 추가.
- 다음 sheet/view root에 적용: AddItemView, RecurrenceSheet, CategoryPickerSheet, CategoryEditSheet, TodoCompleteSheet, CancelTodoSheet, NTDGiveUpSheet, DatePickerSheet, StartHourPickerSheet, DurationPickerSheet, TodayView 점프 sheet.

### UI 상태 영속화 (`UIStateKey`)
- 탭별 toggle/mode를 @AppStorage로 저장 — 앱 재실행 시 마지막 상태 복원.
- `TodayView`: `viewMode` (TodayViewMode를 `String` raw로 변경), `showCompleted`.
- `ListView` / `ArchiveView`: `showCompleted`, `groupByCategory`.
- 카테고리 필터(`filterCategoryID`)는 매 launch마다 초기화 — 사용자 결정 (저장 X).

### 오늘탭 전체/미완료 토글 + NTD 진행바
- `TodayView`에 `showCompleted` 토글 (checklist/unchecked icon, ListView/ArchiveView와 동일 패턴) default `true`.
- `TodayList.isFinishedOccurrence` 헬퍼로 NTD/Todo/Routine 공통 필터.
- NTD 진행바는 위 "NTD progress capsule" 항목 참조.

### 카테고리 NTD 기본값 + 알림 default 5종 (확장)
- Category에 `isDefaultForNTD` (exclusive, `markAsDefaultForNTD()` 헬퍼) + 5종 알림 default attribute.
- AddItemView 신규 NTD 진입 시 default 카테고리 preselect, 카테고리 선택/변경 시 알림 default 신규 항목 1회 적용 (편집 모드는 사용자 알림 보존).
- 위 "Category 알림 default Todo 4종 재구성"와 연계.

### 알림 → 오늘탭 routing + 권한 거부 안내
- NotificationService에 `didReceive` delegate + `Notification.Name.openTodayTabFromNotification` broadcast.
- RootView가 `@State selectedTab` + TabView selection binding으로 onReceive에 `.today` 전환 (iPad sidebar도 같이).
- AddItemView 알림 권한 거부 케이스 처리:
  - `NotificationService.currentAuthorizationStatus()` public method 추가 (prompt X).
  - 알림 section에 inline warning banner (status==.denied일 때만): bell.slash.fill + "설정 열기" 버튼.
  - 저장 시 권한 거부 + 알림 설정돼 있으면 alert dialog: 설정 열기 / 그대로 저장 / 취소.
  - foreground 복귀 시 권한 재확인.
- 권장: 항목 highlight 등 deep link는 미구현 — 단순 routing이 사용자 결정.

### Tag entity drop
- 사용자 결정 — 카테고리만으로 분류 충분. Tag entity와 Item.tags 관계 제거 (Swift 코드 미사용 상태였음).
- 향후 검색 기능 시 notes 내 `#xxx` 패턴으로 처리 — 별도 모델 불필요.

### 활동 기록 화면 (RC 기반, per-item + all-item)
- `Views/ActivityHistoryView.swift` — `init(item: Item?)` 단일 view, optional로 모드 분기.
- 정렬: `completedAt desc` (없으면 `date desc` fallback). 월 단위 Section grouping.
- Row: status dot (완료=accent ●, 포기=secondary ●) + 날짜·요일·시각 + 상태 라벨 + (포기) 사유 inline.
- per-item header: 항목 제목 + streak (반복) + 총 횟수.
- all-item row: 항목 제목 강조 (`.subheadline.weight(.semibold)`) + 날짜/상태 라인.
- Toolbar 필터: 상태(전체/완료/포기) `checkmark.circle` Menu + (all-item) 카테고리 `line.3.horizontal.decrease.circle` Menu.
- All-item `.searchable` — 제목 + notes substring (notes의 `#태그` 자연 매칭).
- Entry points: AddItemView 활동 기록 섹션 하단 "전체 보기" (record 1+ 시 노출, ZStack hidden NavigationLink + 중앙 Text overlay로 chevron 제거) + Settings → "활동 기록" (item=nil).
- 영문 "포기" → "Gave up" (NTD give-up 의미; "Cancelled"는 Todo cancel 별도).
- pop 시 tint 잃는 케이스 방어로 `.appTint()` 부착.

### iPad Stage 2 — 키보드 단축키 + 본문 폭 cap
- **키보드 단축키** (`RootView.swift`):
  - ⌘1~4: 탭 전환 (iPhone TabView selectedTab + iPad sidebar 동시 동기).
  - ⌘N: 현재 탭의 새 항목 sheet 열기 (`Notification.openNewItemForCurrentTab` broadcast, Settings 탭 제외).
  - invisible Button overlay (frame 0, opacity 0, hit-testing X)에 `.keyboardShortcut(...)` 부착.
  - `currentTab` computed: regular size class면 sidebarSelection, compact면 selectedTab.
  - 시뮬레이터에선 Simulator app menu(⌘1~4=Window scale)가 가로채기 가능 → 실기기에서 정상 동작.
- **본문 폭 cap** (`AppTheme.swift`):
  - `iPadContentWidth(_ maxWidth: 700)` ViewModifier — `@Environment(\.horizontalSizeClass) == .regular`에서만 frame cap + 가운데 정렬.
  - TodayView/ListView/ArchiveView의 List, SettingsView의 Form에 적용.

### Mac Catalyst 활성화
- `pbxproj`:
  - `SUPPORTS_MACCATALYST = YES` (main app + widget extension 둘 다).
  - `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO` — Designed for iPad 모드 비활성화. Catalyst만 사용.
  - `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"` — `macosx` 제외. Catalyst는 iOS SDK 변형이라 macosx 불필요.
- Today 탭 아이콘 `\(N).calendar` 동적 SF Symbol이 Catalyst에서 일부 N 렌더 누락 → `#if targetEnvironment(macCatalyst)` 분기로 정적 `calendar` fallback (iPhone TabView `todayTabIconName` + iPad sidebar `SidebarItem.icon()` 둘 다).
- 빌드 검증: Mac Catalyst variant 컴파일 성공. 실행은 Mac을 Apple Developer 계정에 등록 후 가능.
- 현재 iPad UI 그대로 Mac에서 실행 — Mac-native 폴리시 (3-column detail, inline editing 등) 미적용. Stage 3에서 진행.

## 최근 완료 (2026-05-30 ~ 2026-05-31 세션 — Phase A 목표 4-type taxonomy)

목표 모델을 단순 NTD 1종에서 **4-type taxonomy (절제 / 활동 / 집중 / 습관)** 로 재정의. Phase A에선 절제 + 습관만 활성화, 활동 + 집중은 placeholder.

### 정책 결정 (사용자 합의)
- **목표는 카테고리 미사용** — Item.iconColorHex/iconName을 사용자 지정으로 직접 보유. 카테고리 picker, default 알림 모두 Todo 전용으로 의미 좁힘.
- **활동 vs 건강 통합** — 별도 type 분리 안 함. "활동" 1개 type 안에서 source(manual/HealthKit) 선택. 걷기·물마시기 모두 활동.
- **습관 = 별도 type** (routine Todo로 흡수 X) — 정체성 명확화. 동작은 routine Todo와 같지만 멘탈 모델은 "장기 추적 목표".
- **단계적 도입**: Phase A (절제+습관) → Phase B (활동 manual) → Phase C (활동 HealthKit) → Phase D (집중 timer).
- **습관 cancel 액션 없음** — 매일 occurrence 독립이라 "안 한 거"는 단순 미체크. 사유 입력 부담 회피.
- **습관 시각 정책**: startHour=0/dueHour=24 고정 (종일 의미). 사용자에게 시각 UI 비노출, 저장 시 hardcoded.
- **체크 가능 일자**: 습관 trailing 체크 버튼은 **오늘 + 과거**만 (까먹고 안 한 거 사후 기록 가능). 미래 일자 hide.

### 데이터 모델 변경
- **Item 신규 필드**:
  - `iconColorHex: String?` (목표 공통, CategoryColor rawValue)
  - `iconName: String?` (목표 공통, semantic identifier — Android 호환)
  - `activityTargetValue: Double?` / `activityUnit: String?` / `activitySourceType: Int16?` (활동 전용, Phase B/C에서 사용)
- **Item 제거 필드**: `ntdStartHour` (legacy, startHour로 통합 완료 — 1차 정리)
- **RoutineCompletion 신규 필드**: `valueRecorded: Double?` (활동 누적값, Phase B에서 사용)
- **Category 제거 필드**: `isDefaultForNTD`, `defaultNtdStartAlertOffset`, `defaultNtdDueAlertOffset` (목표는 카테고리 미사용 정책)
- **ItemKind enum 확장**: `.activity=2`, `.focus=3`, `.habit=4` 추가
  - `isGoal` 헬퍼: `self != .todo` — 4 type 통합 그룹 판정
  - `goalTypeSymbolName` — sub-picker SF Symbol
  - `isAvailableForInput` — Phase A 활성 type 표시 (절제·습관 true, 활동·집중 false)

### 신규 모델
- **`Models/GoalIcon.swift`** — 12개 enum case + symbolName mapping. rawValue("run", "fast", "water" 등)가 DB 저장. 절제 6 + 활동 6 (fast/alcohol/smoke/caffeine/sweet/phone/run/walk/exercise/water/meditation/read).

### AddItemView 입력 폼 구조
- **2-level kind picker**:
  - Top section: 할일/목표 segmented
  - 별도 "목표 유형" section: **4 chip 가로 + 선택 type 이름·설명**
- **chip 디자인**: 48pt filled circle + 흰 icon (이름 미표시). 선택=accent, 미선택=systemGray3. 활동/집중은 회색 + 탭 disabled.
- **선택 type 이름·설명 영역**: 큰 폰트 이름(`.headline`) + 다음 줄 multiline 설명(`.subheadline`).
- **목표 색·아이콘 통합 section** (isGoal): icon grid 위 + color chip row 아래.
- **신규 항목 시 랜덤 color preset** — `_goalColor = State(initialValue: CategoryColor.allCases.randomElement())` (icon grid background 즉시 시각화).
- **canSave** — 목표일 때 icon + color 둘 다 필수.
- **handleKindChange habit 분기**: startHour=0, dueHour=24, ntdDurationHour=nil 고정.
- **save() kind switch** — habit은 priority=.none, 시각 0/24 fixed 저장.
- **schedule 섹션 chip 숨김**: NTD뿐만 아니라 habit도 미정/기간/시간설정 chip 숨김.

### TodayView 목표 섹션 통합
- `ntdItems` FetchRequest predicate: `(kind == 1 OR kind == 4) AND status != 2` — NTD + habit 통합 fetch.
- `allActiveTodos` / `routineItems`: `kind == 0`만 (habit 제외).
- `ntdsForDate` 분기: NTD는 `ntdOccurrenceRow` (multi-occurrence 단일 선택), habit은 `habitOccurrenceRow` (단순 rule.occurs / startDate 매칭).
- `goalRow` helper: kind별 row component 분기 — NTD→NTDRow, habit→ItemRow.
- **정렬** (`goalSortPriority`): bucket 0(미완료) → bucket 1(완료/포기). bucket 0 내 NTD inProgress(종료 가까운 순) → NTD scheduled(시작 빠른 순) → habit pending.
- 섹션 헤더 `suppressFilterIcon: true` — 목표 섹션은 카테고리 필터 무시이므로 필터 아이콘 미노출.
- **NTD 비-오늘 일자 정책**: 해당 일자에 **시작**하는 occurrence만 노출 (이전 일자 overflow는 hide).

### ItemRow / NTDRow
- **goalLeadingIcon** (목표 사용자 지정 아이콘): 20×20 circle + 11pt SF Symbol. 4-state 시각:
  - scheduled: 회색 outline + 회색 icon
  - inProgress: goalColor outline + goalColor icon
  - done: goalColor full bg + 흰 icon
  - failed: systemGray3 full bg + 흰 icon
  - `.offset(y: -3)` baseline 시각 보정 (SF Symbol과 ZStack baseline 차이).
- **leadingControl 분기**:
  - 목표 + iconName 있음 → goalLeadingIcon (display only)
  - legacy NTD (iconName 없음) → 기존 clock fallback
  - 나머지 → todoCheckbox / routineStatusIcon
- **습관 trailing 체크 버튼** (`habitTrailingCheck`):
  - `square` / `checkmark.square.fill` 토글
  - 오늘 + 과거 일자만 노출. 미래 일자 hide.
  - 완료 여부 무관 노출 (체크 해제용).
  - cancel mode 시 hide (habit은 cancel 액션 없음).
- **categoryBarColor**: 목표면 `iconColorHex`, Todo면 `category.colorHex` 사용.
- **habit clock 아이콘**: `ntdDurationText`의 `isNTD` guard로 habit에선 자동 nil → statusIcons 미노출.

### 목표 섹션 통합 영향
- **TodayView**: 절제 + 습관이 같은 "목표" 섹션. 활동/집중은 Phase B/D에서 추가.
- **ListView 그룹 모드**: "목표" 그룹 최상단 (`list.group.goals`). 카테고리 그룹들 + 미분류는 목표 제외 Todo만.
- **ListView 필터 모드**: 필터 활성 시 목표 별도 섹션 + 선택 카테고리 섹션 (목표 제외).
- **카테고리 필터 정책**: 목표는 카테고리 미사용 → 필터 항상 통과. `matchesCategoryFilter` (TodayView), `sortedActiveItems`/`filteredCompletedItems` (ListView), `filteredItems`/`filteredCompletedItems` (ArchiveView)에 `item.itemKind.isGoal` short-circuit.

### MonthGridView 성능 최적화
- `weekLayouts` / `dotIndicators(day:)`는 비싼 계산이지만 cell마다 재호출돼 42 × O(items × occurrences) 부담.
- body 진입 시 `let layouts = weekLayouts` + `dotsCache: [Date: DotsByDay]` 1회 계산해 cell에 inject.
- `cell(for:layouts:dots:)`로 시그니처 변경 — dict lookup만 수행.
- 매일 반복 NTD with 24h+ duration처럼 occurrence가 많은 경우 navigation 체감 속도 크게 개선.

### NTD auto-complete 버그 fix (사용자 발견)
- 사용자가 NTD startDate를 과거(예: 5/19)로 변경 시 `processRecurringNTD` / `processOneOffNTD`가 7일 lookback 윈도우에서 모든 occurrence를 "이미 종료"로 판정해 false done RC를 일괄 생성하던 버그.
- **fix**: occurrence의 종료 instant가 `item.createdAt`(생성 instant)보다 이전이면 skip. instant 단위 비교로 같은 날 늦은 시각 생성 + 이른 시각 occurrence end edge case도 처리.

### CategoryEditSheet / Category+Helpers 정리
- "절제 목표 분류" toggle + "절제 목표 알림 기본값" section 제거.
- Category+Helpers의 `defaultNtdStart/DueAlertInt`, `defaultForNTD(in:)`, `markAsDefaultForNTD(in:)` 메서드 제거.
- AddItemView `applyCategoryAlertDefaults`의 NTD 분기 제거 (목표는 카테고리 미사용).

### Phase B 이후 후보 (이번 phase 미구현)
- 활동 type 활성화 (manual count input + (+1) 버튼) — **완료 (2026-06-01 세션)**
- 활동 HealthKit 연동 (steps/distance/calories/flights) — **완료 (2026-06-01 세션)**
- 집중 type (timer + pause + 누적 시간 기록) — **완료 (2026-06-01 세션, single-session 모델)**
- 1회성 NTD/Todo 위젯 추가 (현재 ItemSnapshot의 routine만 지원)
- 활동 기록 화면(ActivityHistoryView)의 type별 그룹핑·통계 강화

## 최근 완료 (2026-06-01 세션 — Phase B+C+D 활동/집중 일괄 활성화)

Phase A에서 placeholder였던 활동·집중 type을 실제 동작하도록 구현. 4-type 목표가 모두 입력·렌더링·완료 처리 가능 상태.

### 활동(activity) — Phase B + C 통합
- **AddItemView 입력 UI**:
  - Source chip row: manual / steps / distance / calories / flights — 신규 항목만 변경 가능, 편집 모드에선 잠금(`locked`).
  - Manual 선택 시 quick-add chip row 노출 (`activityQuickStep` — target 기준 [1/2/5/10/20/50/100/200/500/1000/2000/5000/10000] 중 nice step 자동 선택).
  - Target input: 숫자 키패드, source별 단위 hint ("보"/"m"/"kcal"/"층"/사용자 입력).
  - Auto source 선택 시 save 시점에 `HealthKitService.requestAuthorization` 비동기 호출.
- **HealthKitService** (`Services/HealthKitService.swift`):
  - `HKHealthStore` wrapper, `@MainActor`. read-only(`toShare:[]`).
  - `fetchTodayValue(for:)` — 오늘(local startOfDay~다음 startOfDay) cumulativeSum.
  - `quantityType` 매핑: stepCount / distanceWalkingRunning / activeEnergyBurned / flightsClimbed.
  - 권한 status 직접 노출 안 함(privacy) — fetch nil → skip 패턴.
  - `isAvailable` 가드(Mac Catalyst·시뮬레이터에서 false 가능).
- **foreground sync** (`Services/Item+HealthKitSync.swift`):
  - RootView `.task` + `scenePhase==.active` 시 `Item.syncHealthKitActivities` 호출.
  - 오늘이 occurrence인 auto-source activity만 fetch → RC.valueRecorded **absolute set** (increment 아님 — HK는 day total).
  - 0.5 단위 미만 차이는 write skip (Core Data churn 회피).
  - target 도달 시 `done=true` flip. 1회성은 `item.status=done` + `completedAt` sync.
  - 별도 파일 분리 이유: HealthKit import가 widget target에 들어가면 빌드 실패. main app target 전용 멤버십.
- **manual increment** (`Item.incrementActivityValue`): (+N) 버튼 탭 시 RC.valueRecorded += step. target 도달 시 done flip + 1회성 status sync.
- **ItemRow `activityTrailingProgress`**:
  - 140pt progress capsule (NTD 진행바와 동일 시각) + 현재/target 텍스트 ("7500 / 10000").
  - Manual source: (+N) 버튼 (quick step). Auto source: heart(파동) 아이콘 (auto-sync 표시, 액션 없음).
  - 과거 일자: trailing 아이콘 숨김, progress bar만 (그날 결과 조회).
  - 미래 일자: trailing 액션 숨김 (`canInputTrailingAction` 가드).

### 집중(focus) — Phase D
- **데이터 모델**: 별도 필드 추가 안 함. 활동 모델 재활용 (`activityTargetValueDouble`=target 분, `RC.valueRecorded`=누적 분, `activityUnit="분"`).
- **FocusSessionManager** (`Services/FocusSessionManager.swift`):
  - Singleton ObservableObject. `@Published activeItem`, `sessionStartedAt`.
  - **Single-active**: 새 세션 시작 시 기존 active 자동 stop.
  - **wall-clock 기반**: 시작 instant만 RAM에 보존, 종료 시 `elapsed = now - start`.
  - **최소 10분 누적 조건**: elapsed < 10분이면 폐기. **예외**: 이 세션으로 target 도달 시 인정 (final stretch).
  - `focusOccurrenceDate` — 반복은 active/reference occurrence, 1회성은 item.startDate.
- **Item+FocusSession** (`Services/Item+FocusSession.swift`):
  - `addFocusMinutes(_:for:occurrenceDate:)` — RC.valueRecorded에 Double 누적 add (target 도달 시 done flip, 1회성은 status sync).
  - `focusCurrentMinutes(on:)` — 현재 누적 분 조회.
- **FocusSessionView** (`Views/FocusSessionView.swift`):
  - fullScreenCover Zen UI: 검은 배경 + 흐린 아이콘 + 제목 + "지금 집중하고 있어요" caption + 작은 종료 버튼.
  - **시간 표시 X** — zen 정책. target 도달 시 capsule(goalColor + 흰 글자) 강조 + haptic success.
  - **자동 종료 조건**:
    - `scenePhase==.background`: 잠금/홈/앱 전환/전화 받음 (inactive는 무시 — transient overlay).
    - CoreMotion 흔들림: `MotionObserver`가 device motion `userAcceleration` 3초 sliding window 평균 > 0.5g면 trigger.
  - `UIApplication.isIdleTimerDisabled = true` — 화면 자동 잠금 차단.
  - target 도달 자동 트리거: `(target - 누적)분` 후 single delayed Task(폐기 가능). 이전 5초 polling 대신 결정적 schedule.
- **ItemRow `focusTrailingProgress`**:
  - Activity와 동일 시각의 progress capsule (분 단위 "45/60").
  - ▶ 버튼 — 탭 시 `presentFocusSession = true` → fullScreenCover로 FocusSessionView.
  - 미래/과거 일자 ▶ 숨김.

### Enum / 타입 확장
- `ActivitySourceType`: 3종(manual/steps/distance) → 5종 (+ calories=`activeEnergyBurned`, flights=`flightsClimbed`).
- `ItemKind.isAvailableForInput`: 4-type 모두 true (Phase A 가드 제거).
- `ItemKind.goalTypeSymbolName`: 절제=`hand.raised.fill` (이전 `nosign`에서 변경), 습관=`checkmark.square.fill` (이전 `checkmark.circle.fill`에서 변경).
- `Item` accessor: `activityTargetValueDouble`, `activityTargetValueInt`, `activitySource`, `activityQuickStep(target:)`.

### Info.plist + entitlements
- `NSHealthShareUsageDescription` 추가 — "걸음수와 거리 데이터를 읽어와서 활동 목표 진행도를 자동으로 측정합니다."
- `com.apple.developer.healthkit = true`, `com.apple.developer.healthkit.access = []` (read-only).

### TodayView 통합
- `goalKindFilterOrder`: [notTodo, activity, focus, habit] — 사용자가 type별로 toggle 가능한 sub-filter.
- 목표 섹션 fetch: kind IN (1, 2, 3, 4) AND status != deleted.
- `goalRow` dispatch: NTD → NTDRow, habit/activity/focus → ItemRow (각 trailing UI는 ItemRow 내부 분기).
- `goalSortPriority`: NTD inProgress → NTD scheduled → habit/activity/focus pending → 완료/포기.

### 알려진 한계 (이번 phase 미구현)
- Activity HealthKit **background delivery 없음** — foreground sync만. 사용자가 앱 열어야 진행률 갱신. `HKObserverQuery + enableBackgroundDelivery`는 후속.
- Focus motion 임계치(0.5g, 3초 window)는 실측 미보정 — 실 사용자 피드백 후 조정.
- FocusSessionManager session start 시각이 RAM only — 앱 강제 종료/크래시 시 손실. foreground 종료가 곧 세션 종료라 일반 시나리오에선 무관.
- Mac Catalyst에선 HealthKit unavailable → activity HK source 입력 막혀야 함 (현재 chip 노출은 됨, fetch만 nil). UI 가드 추가 검토.
- ActivityHistoryView에 type별 그룹핑·통계 강화는 미진행.

## 최근 완료 (2026-06-01 회사 세션 — 위젯 재설계 + HK BG + 검색)

### 위젯 전면 재설계 — 시간 정보 제거, 4-type 통합
- **공통 표시 방식**:
  - 목표: 사용자 지정 아이콘 + progress capsule(타이틀 overlay) — 절제/활동/집중/습관 통일.
  - 할일: 카테고리 아이콘 + 타이틀 plain.
  - 모두 1줄, 시간 정보 없음.
- **새 ItemSnapshot 모델**: `bucket`(ongoing/scheduled/past), `progress`(0~1), `iconName`, `iconColorHex`.
  - 정렬: groupOrder(목표→할일) → bucket(진행중→예정→지남) → sortAnchor.
  - past 항목은 row 표시 X, 카운트에는 포함.
  - fetch: `isSomeday=NO + status != deleted` — boolean optional NULL semantics 회피 위해 메모리 필터.
- **classifyNTD**: 1회성/반복 분기 명확화. 1회성은 `Item.status` 기반(completedAt 오늘일 때만 past), 반복은 today RC 기반.
- **classifyTodo**: 1회성 `.done` / `.failed` 둘 다 가드, `completedAt` 오늘일 때만 past. 단일 일정 시간 지정 미완료는 시각 지나도 ongoing 유지(오늘탭 정책 통일).
- **Home Small / Medium**:
  - 헤더: 좌측 큰 일자(34pt) + 우측 vstack(요일 leading + 카운트 trailing). 카운트는 (scope) n/m + (checkmark.circle) n/m 1줄.
  - row 박스 height 미리 계산(`fitCount × rowHeight + ...`) → widget 바닥 정렬, 박스 안 row는 위 정렬. device별 widget 높이 차이는 헤더와 박스 사이 flex spacer가 흡수.
  - 진행바 fill opacity 0.35 + 타이틀 색 colorScheme 분기(라이트=fill color, 다크=primary) — ItemRow NTD capsule과 통일.
- **Lock Circular**: 큰 아이콘 + 두꺼운 원형 progress arc(4pt). 활성 목표 회전. `dropFirst(2)`로 LockRect와 중복 회피.
- **Lock Rectangular**: 원형 슬롯 2개 가로 배치(AccessoryWidgetBackground 대신 명시 Circle). top 2 고정(회전 없음) — LockCircle이 G3+ 회전이라 통합 시 G1·G2 + G3 (+G4 순환) 3~4개 분산 노출.
- **Adaptive timeline tier 재정의**: `>1h: 60min / 20m~1h: 10min / 5m~20m: 5min / <5m: 1min / 미설정: 60min` — 시간 라벨 없어 budget spare. horizon 6h.
- **WidgetCenter reload hook**: RootView `.task` + `.onChange(scenePhase=.active)`에서 호출. HK BG handler 끝에도 호출.

### HealthKit Background Delivery (`.immediate`) + 목표 달성 알림
- **HealthKitService.startBackgroundObservation(for:handler:)** — HKObserverQuery + enableBackgroundDelivery(.immediate). source별 1 observer(activeObservers dict 중복 방지). MyDaysApp.init()에서 4 source 일괄 등록.
- **Item.handleHealthKitBackgroundFire(for:completion:)** — `.immediate` event 시:
  - HK fetch → 활성 활동 항목 loop
  - **5% threshold**: `abs(current - prev) >= target × 0.05` 일 때만 reload + RC update.
  - 신규 target 달성(`!wasDone`): 무조건 reload + RC.done=true + 알림 fire (cap 제외).
  - 미세 변화: RC update 안 함 — 다음 누적 비교 정확도 유지(매번 갱신하면 비교 기준이 stale 갱신되어 5% 영영 안 도달).
- **알림 정책**: AddItemView 활동 type 알림 section에 toggle ("목표 달성 알림", default ON). focus는 알림 section 자체 없음(자체 timer 화면).
- **알림 fire**: `UNMutableNotificationContent` + immediate trigger. ID `activity_goal_reached:{itemID}:{epoch}` — 중복 회피.
- **데이터 모델**: `Item.notifyOnGoalReached: Bool?` 추가 (default ON 해석, nil도 ON).
- **entitlements**: `com.apple.developer.healthkit.access` (빈 array), `com.apple.developer.healthkit.background-delivery` 추가. Xcode capabilities UI에서 "HealthKit Background Delivery" 옵션 체크.

### 검색 모드 (목록탭) + `#태그` chip
- **진입**: 목록탭 toolbar 돋보기 버튼 → `searchPresented = true`.
- **Banner 패턴**: TodayView cancel/picker 모드와 통일. `safeAreaInset(edge: .top)` accent.opacity 0.12 배경 + 검색 입력 capsule(systemBackground 흰/검 자동 적응).
- **모드 종료**: toolbar 우상단 prominent checkmark 버튼 (banner cancel X). TodayView cancelMode 패턴 통일.
- **navigationTitle**: 일반 "전체 활동" .large / 검색 "활동 검색" .inline.
- **검색 범위**: title + notes CONTAINS[c]. predicate: `isSomeday=NO AND status != deleted AND (title CONTAINS[c] OR notes CONTAINS[c])`.
- **결과 list**: `SearchResultsList` inner struct — init에서 동적 predicate. 항상 List 컨테이너 유지(첫 char 입력 시 view tree 재구성으로 키보드 dismiss되는 문제 회피).
- **태그 chip section**: notes의 `#[\\p{L}\\p{N}_]+` regex 추출(Unicode-aware, 한국어/영문 통합). 검색어 유무 무관 항상 노출. chip 탭 시 `searchText = tag` replace 동작 → 즉시 검색.
- **스크롤 시 키보드 dismiss**: `.scrollDismissesKeyboard(.immediately)`.
- **listStyle**: normalList 그대로 `.insetGrouped`, SearchResultsList도 `.insetGrouped`. 태그 chip 위 약간 padding은 insetGrouped 자체 동작이라 수용.
- **결과는 별도 Section으로 묶음** — 태그 chip(no section)과 시각 분리.

### 기타 폴리시
- 카테고리 편집 화면: "할일 알림 기본값" 1개 section → "시작 알림 기본값" + "마감 알림 기본값" 2 section 분리.
  - row label: "시간 설정시" / "시간 미설정 시" (timed/untimed 공통).
- CategoryIcon: `pawprint.fill` → `pawprint` (outline).
- GoalIcon: 12 → 18로 확장. 목표 type 대표 4(맨 앞: abstain/run/focus/habit) + 절제 3 + 운동 4 + 활동/개인 7. AddItemView 입력 폼에 type 변경 시 자동 GoalIcon 선택 (`ItemKind.defaultGoalIcon`) — `userPickedGoalIcon` flag로 사용자 명시 선택 시는 보존.
- ItemKind.goalTypeSymbolName: 절제 `nosign`→`hand.raised.fill`, 집중 `timer`→`hourglass.bottomhalf.filled`.

## 미구현 (다음 후보, 우선순위 순)

### 1. 활동 목표 (Activity Goal) — 완료 (2026-06-01 세션)
- 4-type taxonomy 안에 통합 완료. HealthKit 4종(steps/distance/calories/flights) + manual 자동 측정 + foreground sync + .immediate background delivery + 목표 달성 알림.
- 자세한 구현은 "최근 완료 (2026-06-01 회사 세션)" 섹션 참조.
- **남은 후속**: ScreenTime / 수면 시각 type, ActivityHistoryView 통계 강화.

### 2. 검색 기능 + `#태그` (notes 내) — 완료 (2026-06-01 세션)
- 목록탭에 검색 모드 + 태그 chip section 구현.
- 자세한 구현은 "최근 완료 (2026-06-01 회사 세션)" 섹션 참조.
- **선택 후속** (v2+): 태그 overview 화면 (unique 태그 + 카운트), TextField `#` 입력 시 자동완성.

### 3. iPad 최적화 (Stage 1+2 완료, Mac Catalyst 활성화 완료, Stage 3 진행 예정)
- Stage 1 완료 (2026-05-28): NavigationSplitView 분기, 사이드바 selection 동작.
- Stage 2 완료 (2026-05-29): 키보드 단축키 (⌘1~4, ⌘N) + 본문 폭 cap (`.iPadContentWidth()`).
- Mac Catalyst 활성화 완료 (2026-05-29): pbxproj 설정 + Today 아이콘 fallback. 빌드/실행 OK.
- **Stage 3 (남음)**: 3-column NavigationSplitView (sidebar + content list + detail), AddItemView를 sheet 대신 detail pane에 inline 호스트, Mac-native 폴리시. 큰 작업 — 1.5~2주. 출시 v2 후보.

### 4. 알림 후속 개선 (완료)
- **완료 (2026-05-29)**: 알림 탭 → 오늘 탭 routing. 알림 권한 거부 안내 (AddItemView 저장 시 dialog + Settings 열기).
- **결정 (2026-06-01)**: 항목 highlight deep link는 진행 안 함 — 오늘탭 routing이 의도된 최종 동작. 사용자가 알림 탭 후 오늘탭에서 해당 항목을 직접 확인하는 흐름.
- **남음**: pending 한계(64) 초과 시 graceful 처리. 사용자 8개 미만 routine이면 무리 X — 실 사용자 데이터 보고 결정 (보류).

### 5. 활동 기록 화면 (완료, 2026-05-29)
- RC 기반 시계열 화면 — per-item (AddItemView "전체 보기") + all-item (Settings → 활동 기록). 자세한 구현은 "최근 완료" 섹션 참조.

### 5-b. 활동 보고서 (Premium 기능 — 보류)

**MVP 보고서 구성**:
- 첫 화면 (대시보드 — 기간 선택 가능, default 이번 달):
  - 요약 카드: 완료 N회 / 포기 M회 / 완료율 % / 현재 streak
  - 월간 추이 line chart (최근 6개월)
  - 요일별 완료율 bar chart
  - 카테고리별 완료율 비교
- 항목별 디테일 (각 routine·NTD 보고서) — per-item 활동 기록 화면 + 통계 카드

**가치 분류**:
| | 가치 | 비용 | MVP |
|---|---|---|---|
| 완료율 (기간) | ⭐⭐⭐ | 낮음 | ✓ |
| Streak | ⭐⭐⭐ | 낮음 | ✓ |
| 누적 횟수 | ⭐⭐ | 낮음 | ✓ |
| 월간 line chart | ⭐⭐⭐ | 중간 | ✓ |
| 요일별 bar | ⭐⭐⭐ | 중간 | ✓ |
| 카테고리별 | ⭐⭐ | 중간 | ✓ |
| 시간대 heatmap | ⭐⭐ | 높음 | Phase 2 |
| NTD 평균 지속 시간 | ⭐⭐ | 중간 | Phase 2 |
| 포기 사유 빈도 | ⭐⭐ | 낮음 | Phase 2 |
| Narrative 인사이트 (template) | ⭐ | 낮음 | Phase 2 |
| 활동 목표 통계 | — | — | 활동 목표 도입 후 |

**기술 메모**:
- **Charts framework** (iOS 16+) — Apple 공식, 가독성 좋음.
- 통계 계산은 view appear 시 — RC ~수천건이라도 ms 수준. 캐싱 불필요.
- 기간: 일/주/월/년. default = 이번 달.
- 데이터 부족 (routine 시작 ~7일 미만): "데이터 부족" 안내 (오해 방지).

**핵심 insight 우선**:
- "현재 streak + 월간 추이" 두 가지가 retention 핵심 — 매일 들어와 확인하는 motivation 제공.
- 단순 숫자 나열보다 **"내 패턴 발견 + 동기부여"** 정수.

### 6. Month view Phase 3 — grid 인프라 재활용
- 반복 NTD/Todo 전용 history view에 같은 grid 컴포넌트 사용 (성공/실패 색 dot 등 indicator만 교체).
- MonthGridView를 prop 기반(`cellDecorator: (Date) -> some View`)으로 일반화 필요.

### 폴리시 / 후속
- SpeechRecognizer Phase B 발전 — 자체 mic UI 풍부화 (waveform 등). 현재는 hands-free 용. **사용자 결정: 현 기능으로 마무리**.
- Settings "모든 데이터 삭제" 버튼 — 일반 사용자에게도 필요 (사용자 의견). UX 방식 별도 고민 중.
- `completeExpiredRoutines` 호출 위치(현재 4곳) 성능 측정 후 최적화 후보 — 현재 보류.
- Settings 활동 로그 화면 — 표시 문구 / UI 개선 필요 (사용자 의견). 별도 진행.
- pending 알림 64 한계 — **출시 후 모니터링 항목**으로 이동. 사용자 routine 8개 미만이면 무관. 실 사용자 데이터에서 알림 누락 보고 시 graceful degradation 추가.
- 알림 권한 거부 재안내 — 입력 폼 저장 시 dialog로 처리 완료 (2026-05-29). 추가 onboarding 안내는 우선순위 낮음.

## 다음 작업 분류 (2026-06-01 회사 세션 결정)

### 출시 1.0 우선 (소형 폴리시 + 유료 unlock 흐름 결정)
**작은 작업** (병행 가능):
- **빈 화면 디자인** — Case A(진짜 empty) 완료(2026-06-01 집 세션). B/C/D 회사에서 진행 예정. 세부는 "빈 화면 작업 상태" 섹션 참조.
- 활동 로그 화면 (Settings) UI 개선 + **로그 데이터 보관 기간 정책** 정의 (예: 90일/1년 자동 cleanup).
- 홈 위젯 large 사이즈 추가 검토 — small/medium 패턴 확장.
- tint 풀림 이슈 — 재현 시 그때 대응.

### 빈 화면 작업 상태 (Case A 완료, B/C/D 진행 예정)

**Case 분류**:
- **A** 진짜 empty (필터 없음 + 데이터 0개) — **완료**
- **B** 필터 결과 empty (카테고리/목표 유형 필터 + 매치 0, 검색 결과 0)
- **C** 토글 결과 empty (showCompleted=false + 미완료 0 = "모두 완료" 긍정 케이스)
- **D** Picker mode + 단일 항목 선택 + 그 일자 occurrence 없음

**Case A 구현 (집 세션)**:
- 공통 `Views/EmptyStateView.swift` — 96pt SF Symbol(accent) + body 폰트 메시지. 메시지 안 "(+)" 마커 자동 감지 → `plus.circle.fill` inline 교체.
- `String.LocalizationValue` 받아 `String(localized:)` + components 분할 + Text concat.
- 탭별:
  - TodayView: 양 섹션 다 empty + 필터 없음. 오늘=`today.empty.first`, 다른 일자=`today.empty.first.other`.
  - ListView: 필터 없음 + 활성 0개 + (완료 토글 OFF 또는 완료 0개). `list.empty.first`.
  - ArchiveView: 필터 없음 + 활성/완료 모두 0개. `archive.empty.first` ("아직 정리되지 않은 생각은 여기에 기록하세요.").
- 탭 아이콘 변경: 목록 `list.bullet` → `note.text`, 보관함 `archivebox` → `tray.full.fill`.

**Case B (필터/검색 결과 empty)** — 진행 예정:
- 대상: 모든 탭의 카테고리·목표 유형 필터 매치 0, ListView 검색 결과 0건.
- 디자인 톤: 더 작은 inline placeholder (full-screen 아님). "이 필터로 표시할 항목이 없습니다" + 필터 해제 hint.

**Case C (토글 결과 empty — "모두 완료")** — 진행 예정:
- 대상: showCompleted=false + 미완료 0개. 데이터는 있고 모두 완료된 상태.
- 디자인 톤: 긍정 메시지 ("오늘 모두 완료" 등) + 체크 아이콘 + 동기부여 멘트.

**Case D (Picker mode + 단일 항목 + occurrence 없음)** — 진행 예정:
- 대상: TodayView picker mode + pickedItemID + 그 일자 occurrence 없음.
- 디자인 톤: 작은 placeholder + "다른 일자로 swipe" 안내.

**재활용 패턴**:
- Case A의 EmptyStateView 컴포넌트 + "(+)" 마커 교체 패턴 그대로 활용 가능 (다른 SF Symbol로 교체 가능).
- B/C는 inline section row가 자연 (필터/토글 인디케이터는 데이터 자체가 있음을 알릴 필요).

**큰 작업 — 유료 unlock UI 흐름** (집에서 진행 예정):
- 유료 cap 기준 확정 (NTD/활동/반복/카테고리 갯수, Premium 기능 set).
- Paywall 진입점 3종 (Settings 상시 entry / cap 도달 inline / 기능 진입 시도) UI 설계.
- 코드 가드 헬퍼 시그니처 정리 (`canAddRecurrence(in:)`, `canUsePremiumFeature(...)`).
- **DEV unlock 버튼** Settings의 Dev section에 추가 — 테스트용.
- StoreKit 2 통합은 다음 단계.

**보류 작업** (이번 phase 안 함):
- monthview 기능 정리 — 데이터 더 쌓인 후 다시 검토.
- 입력폼 활동 기록 "전체 보기"에 monthview — monthview 정리 완료 후 진행.

### 출시 1.0 직전 (출시 준비)
- **첫 진입 onboarding** — 권한 요청 흐름(Notification / HealthKit / Microphone / Speech) + 기능 소개.
- **App Store 자료** — 스크린샷 5종(ko/en), description, 키워드, **Privacy Nutrition Labels** (HealthKit / CloudKit 데이터 처리 명시 필수).
- **출시 전 QA 체크리스트**:
  - 권한 거부 케이스 (Notification / HealthKit / Microphone / Speech).
  - CloudKit 충돌 케이스 (멀티 기기).
  - 위젯 stale (사용자 앱 안 열어도 정상 동작).
  - iCloud 미로그인 사용자 fallback.

### 다음 단계 작업 (출시 1.0 후 / v1.1+)
- 활동 보고서 (Premium) — Charts framework. 통계 항목 확정 필요 ("5-b. 활동 보고서" 섹션 참조).
- ActivityHistoryView 통계 강화 — type별 그룹핑, completion rate, streak.
- monthview 정리 완료 후 입력폼 활동 기록 monthview.
- HK BG type 확장 (수면 / 취침 시각).
- HK BG 운영 모니터링 — `.immediate` 배터리·메모리 영향 실측.

### v2 작업
- **무료/유료 cap 활성화** — StoreKit 2 통합 + paywall 동작.
- **구글 애널리틱스** — 사용자 패턴 분석. 코드 위치 정리 필요 (App init / 주요 화면 진입 / 액션 시점).
- **Firebase 동기화** — CloudKit ↔ Firebase 양방향 토글 + last-writer-wins. 로그인 화면 추가.
- **세팅탭 기능 정리** — 권한 / 데이터 / 동기화 / 보고서 / 백업 등 재구성.
- **데이터 export/import** — JSON 백업. Freemium 데이터 안전망 + 동기화 변경 사이 fallback.

### v3+ 작업 (먼 미래)
- iPad Stage 3 — 3-column NavigationSplitView + AddItemView inline pane + Mac-native 폴리시. 1.5~2주.
- 검색 확장 — 태그 overview 화면 (unique 태그 + 카운트) + TextField `#` 입력 시 자동완성.
- Apple Watch 앱 — 활동 목표 빠른 view + 체크. iOS 위젯/HK 인프라 재활용 가능.

## Freemium 계획 (출시 시점 결정 보류)

### 제안 (사용자 안)
- **사용량 cap (무료)**:
  - 절제목표 + 활동목표 합계 최대 2개 (NTD 1 + Activity 1)
  - 반복일정 최대 2개
  - 카테고리 최대 3개
  - 체크리스트 최대 3개/할일
- **Premium 기능 (유료)**:
  - 테마 색상 (TintPreset 8색)
  - 데이터 동기화 (CloudKit / Firebase)
  - 활동 보고서 + 활동 검색
- 별도 앱 X, 단일 앱 in-app purchase.

### 의견 / 권장 보정
- NTD/반복 cap 너무 빡빡 — **각 3~4개로 완화** 권장. 한도 빨리 도달 → 사용자 이탈 risk.
- 위젯은 **무료 포함** 권장 — 차별화 약하면 사용 안 함.
- **1차 출시는 전체 무료, freemium은 v2로 미루는 게 안전** — 사용자 적응 데이터 + review 안정화 후 paid tier 추가.
  - 대안: 출시 기념 N개월 전부 무료 → 추후 전환.

### UX (Paywall 진입점 3가지)
1. Settings에 "Pro 업그레이드" 상시 entry (덜 intrusive).
2. **Cap 도달 inline 안내** — 그 자리에서 "Pro로 무제한 → [업그레이드]" 칩/링크.
3. **기능 진입 시도** — 보고서/검색 탭 열면 preview + 가격 + CTA.
- 첫 launch onboarding엔 paywall 표시 X (사용자 적응 우선).
- modal popup 빈도 제한 (세션당 1회).

### 기술 구현 메모
- **StoreKit 2** (iOS 15+). 권장: 연구독 + 평생(lifetime) 일회성 둘 다 제공.
- **`isPremium` flag**:
  - source of truth: StoreKit transaction 확인
  - 캐시: `@AppStorage(... store: .appShared)` — 위젯도 인지
- **권한 가드 헬퍼**: `canAddRecurrence(in:)`, `canAddNTD(in:)`, `canAddCategory(in:)` 등. 각 entry point에서 미리 검사 → 실패 시 paywall.
- 동기화 ON 토글 시 Premium 체크 → cloudKitContainerOptions 부착.

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
- **iOS 26 TabView floating 탭바 opaque 회귀 — `.clipped()` 주의**: TodayView body 외곽 ZStack에 `.clipped()` 부착하면 iOS 26 TabView가 scroll content edge를 감지 못해 floating 탭바가 opaque로 fallback(다른 탭은 반투명). TodayView만 탭바 주변이 톤 입혀져 보이는 회귀. 슬라이드 transition의 overflow 방어 목적으로 `.clipped()`를 추가하지 말 것 — ZStack은 navigation bar / safeAreaInset / 화면 가장자리로 이미 자연 bound됨. `.clipped()` 제거 시 safeAreaInset 콘텐츠(WeekStrip/MonthGrid)의 암묵 backdrop도 사라져 List 본문이 비치므로 inset content에 `.background(Color(.systemBackground))` 명시 필요.
- 콘솔 노이즈 (`remoteTextInputSession…`, `Gesture: System gesture gate timed out`, `Result accumulator timeout` 등)는 iOS 자체 이슈로 무시.
- **`updateTaskRequest failed for com.apple.coredata.cloudkit.activity.export.…`** + `BGSystemTaskSchedulerErrorDomain Code=3` — Core Data+CloudKit이 동적 UUID로 BGTaskScheduler 등록 시도하다 dev/Xcode 환경에서 거부됨. CloudKit sync 자체는 push notification으로 정상 동작. 출시 빌드에선 거의 안 보임.

## 사용자 컨텍스트

- 익숙: Swift, Java. native 개발 선호 (크로스플랫폼 X).
- 응답 스타일: 짧고 빠른 결정. UX 디테일에 민감.
- 진행 방식: 기능 단위로 만들고 → 실기기에서 확인 → 짧은 피드백 → 반영.
- 메모리 시스템은 머신 로컬에 저장됨. 회사(맥미니)와 집(맥북) 양쪽에서 작업하므로 이 CLAUDE.md가 컨텍스트 동기화의 1순위.
- 두 기기 모두 동일 경로 `/Users/diokim/Work/mywork/mydays/mydays_ios/MyDays` 사용 권장 (메모리 sanitized path 동일).
- 코드 수정 시 주석 잘 달기 — 특히 timezone, NTD 의미, SwiftUI 우회 사유 등 비-자명한 부분.
