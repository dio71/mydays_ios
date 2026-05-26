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

### Category / Tag / Reminder
- Category: name, colorHex, iconName, sortOrder
- Tag: name, colorHex(현재 단일 색)
- Reminder: fireDate, offsetMin, anchor, repeats

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
      - duration 설정됨: 계획된 종료 instant의 local 일자 (실제 완료/포기와 무관 — 계획된 일자에 모두 노출)
      - duration 없음 + RC.completedAt 있음: RC.completedAt의 local 일자
      - duration 없음 + 1회성 종료: item.completedAt의 local 일자
      - duration 없음 + 진행 중: now의 local 일자 (계속 확장 — "현재까지 진행시간")
    - 후보 occurrence start dates (`Item.ntdOccurrenceStartCandidates(coveringDate:)`):
      - 1회성: startDate 1개
      - 반복: lookback 내 forward iterate — duration 설정 시 ceil(duration/24)+1일, 미설정 시 31일
    - 한 Item당 한 occurrence만 노출 (가장 먼저 매치)
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

### RecurrenceSheet
- Frequency picker (segmented): 매일/매주/매월
- Daily: Stepper로 interval (1~365)
- Weekly: 요일 7개 멀티 (시스템 firstWeekday 시작). `shortWeekdaySymbols` 사용 (영어 Tue/Thu 구분 OK)
- Monthly: 1~31 grid + 말일 toggle + 1~12월 grid
- 기간(start/end) 입력은 **없음** — Item.startDate/dueDate 사용
- 편집 시 "반복 제거" destructive 버튼

### ItemRow (3줄 레이아웃)
- 줄 1: leadingControl + 제목(1줄, truncation tail) + 시간대(caption2) + D-day/카운트다운(caption, isOverdue면 red)
- 줄 2: 메모(notes, caption secondary, 1줄) — 옵션
- 줄 3: statusIcons (깃발 / 🔥streak / 알림 bell / 반복 repeat+요약 / NTD 목표 clock+duration) — today·list mode 공통 노출
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

## 미구현 (다음 후보, 우선순위 순)

### 1. Week strip → Month view (다음 작업 — 회사에서 이어받기)
**컨셉**: TodayView 상단 타이틀 아래에 week strip(요일+날짜 가로 줄)을 두고, 추후 [D][M] 토글로 월간 grid 진입. Week view는 별도 구현 안 함 — strip이 그 효과 대체. 일자 시간격자 일정이 없는 todo+NTD 앱이라 month view가 더 유용.

**Phase 1: Week strip만 (다음 작업, 회사에서 시작)**
- 위치: TodayView toolbar(title) 아래. 옵션 (a) `safeAreaInset(edge: .top)` (b) ZStack 위로 VStack 묶기
- 구성: 7 cell — 요일(일/월/...토) + 날짜 숫자만 (indicator 없음)
- **주 시작 요일**: `Calendar.current.firstWeekday` 따라감 — 한국=일요일, 유럽=월요일 자동
- 일자 cell 탭 → `displayedDate` 변경 (기존 `navigateTo(_:forward:)` 재사용 — slide transition 그대로 작동)
- **주 단위 swipe**: Week strip 영역에서만 detect (TodayView 본문의 일 단위 swipe와 분리). 한 swipe = 7일 shift.
- **선택일 표시**: 선택된 일자 cell에 accent fill background (circle 또는 capsule)
- **오늘 일자**: 별도 시각 표시 (예: 요일 라벨 색 accent, 또는 작은 dot)
- 구현 단위: 새 view `Views/WeekStripView.swift`, `@Binding var selectedDate: Date` 받음
- 주 시작점 계산: `Calendar.current.dateInterval(of: .weekOfYear, for: someDate)` 로 주 시작일 얻기. **주의**: 우리는 UTC anchor로 저장하지만 firstWeekday 계산은 `Calendar.current`로 (사용자 로케일 따름). 날짜 비교는 UTC startOfDay 통일.
- 컴포넌트 분리 — 추후 Phase 2/3에서 Month grid와 같은 prop 패턴 공유 가능하게.

**Phase 2 (이후): [D][M] toggle + Month view**
- Day mode (D, default): 현재 + week strip
- Month mode (M): week strip 숨김, 풀 month grid (LazyVGrid 7열)
- Month grid: cell당 날짜 + indicator (NTD bar, 완료 dot 등) — 점진적 추가
- 일자 탭 → D mode로 복귀 + displayedDate 변경
- 토글 위치: week strip 우측 small segmented control 또는 toolbar trailing

**Phase 3 (이후): NTD 히스토리 등에 month grid 인프라 재활용**
- 반복 NTD/Todo 전용 history view에 같은 grid 컴포넌트 사용

### 2. WidgetKit 위젯 (Phase 1 진행 중 — 2026-05-26 시작)
**범위**: Home Screen Small + Medium만 (Lock Screen 제외, Live Activity는 추후 Phase)
**Phase 1 (현재)**: NTD 전용 위젯 — 가장 relevant한 NTD occurrence 카운트다운. Apple Developer / Xcode 설정 + PersistenceController shared container 전환 + TimelineProvider/Views 완료. 실기기 동작 검증 단계.
**Phase 2 (이후)**: Todo도 표시. NTD가 없을 때 Todo로 fallback할지, 별도 widget kind를 추가할지는 그때 결정. 지금은 Todo 분기를 미리 추상화하지 말 것 (단순성 원칙).
**최초 진행 step (참고용 — 이미 완료)**:
1. App Group ID 생성 (`group.io.snapplay.MyDays`)
2. Main app Signing & Capabilities에 App Groups 추가
3. Widget Extension target 추가 (Xcode → File → New → Target → Widget Extension)
   - Include Live Activity: ☐
4. Widget target에도 App Groups capability + group ID 체크
5. PersistenceController 수정 — shared store URL:
   ```swift
   let storeURL = FileManager.default
       .containerURL(forSecurityApplicationGroupIdentifier: "group.io.snapplay.MyDays")!
       .appendingPathComponent("MyDays.sqlite")
   ```
6. Widget target에 file membership 추가:
   - Models/Item+Helpers.swift, CalendarDate.swift, ModelEnums.swift, RecurrenceRule+Helpers.swift
   - MyDays.xcdatamodeld
   - Services/PersistenceController.swift
7. TimelineProvider — `ntdRelevantOccurrenceDate` 기반 entries (시작/중간/종료 instant)
8. Widget views: Small (icon + countdown + 제목), Medium (제목 + countdown + progress bar)
9. 실기기 home에 추가 → 동작 확인

**참고**: PBXFileSystemSynchronizedRootGroup (Xcode 16+) 사용 중 — widget target file membership 방식 다를 수 있음. iOS 17.6 deployment 유지. CloudKit 동기화는 shared container로 자동.

### 3. 알림 후속 개선
- 알림 탭 → 항목 편집 화면 deep link
- 권한 거부 후 Settings 재안내 경로
- pending 한계(64) 초과 시 graceful 처리

### 4. 카테고리·태그 관리 UI
- Category 입력/편집 화면
- 목록·보관함에 필터 추가

### 5. 3단계 계층 구조
- AddItemView에 parent 선택 UI
- 표시(들여쓰기) — 깊이 제한 3단계 앱 로직

### 6. iPad 최적화
- 합의: **앱 완성 후 일괄 작업**
- NavigationSplitView, 2-pane, Regular size class

### 폴리시 / 후속 개선
- 항목별 전체 활동 기록 view (Todo/NTD 공통 — 현재 AddItemView 활동 기록 section은 최근 10건만)
- ActivityLogView ↔ RoutineCompletion 이원화 유지 (의도된 분리: lifecycle vs per-occurrence — ItemEvent는 uncomplete 등 lifecycle 보존, RC는 현재 occurrence snapshot)
- SpeechRecognizer Phase B 발전 — 현재 우리 자체 mic은 hands-free 용 (키보드 안 떠있을 때만). 키보드 활성 시 시스템 dictation에 위임 중. 향후 발전 시 자체 mic UI를 더 풍부하게 (waveform 등) 가능

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
