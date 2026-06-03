import CoreData
import SwiftUI
import UIKit
import UserNotifications

struct AddItemView: View {

    let editingItem: Item?

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleFocused: Bool
    /// 활동 목표 수치 TextField focus — quick add chip 탭 시 dismiss용.
    @FocusState private var activityTargetFocused: Bool

    @State private var title: String
    @State private var notes: String
    // NTD/Todo 분기.
    @State private var kind: ItemKind
    @State private var hasStart: Bool
    @State private var startDate: Date
    @State private var hasDue: Bool
    @State private var dueDate: Date
    @State private var priority: Priority
    // Todo·NTD 공통 wall-clock 시각 — non-optional Int.
    // startHour: 0~23 (default 0). dueHour: 0~24 (24 = 시간 미설정 sentinel = 다음 날 0시).
    // hasTime은 derived (`dueHour < 24`) — 별도 toggle state 불필요.
    @State private var startHour: Int
    @State private var dueHour: Int

    /// 시간 명시 여부 — derived. `dueHour < 24`면 시간 설정 ON, `== 24`면 OFF (종일).
    private var hasTime: Bool { dueHour < 24 }
    // 반복 종료일 (UTC anchor). nil = 무기한.
    @State private var recurrenceEndDate: Date?
    // NTD 전용. ntdDurationHour=nil = 미설정 = "한계까지" (반복 의미 X).
    @State private var ntdDurationHour: Int?
    /// 활동 전용 — 목표 수치 (정수). 입력 폼에선 TextField 바인딩.
    /// 0 = 미설정 (canSave에서 검증).
    @State private var activityTarget: Int = 0
    /// 활동 측정 source — manual / steps / distance / calories / flights. 신규는 manual default.
    /// HealthKit 권한 요청은 저장 시점 (attemptSave) — picker 선택할 때마다 prompt 뜨지 않게.
    @State private var activitySource: ActivitySourceType = .manual
    /// 건강 앱 이동 alert — auto source hint의 link 탭 시 안내 dialog 표시.
    @State private var showHealthAppPathAlert: Bool = false
    /// 활동/집중 목표 달성 시 알림 fire 여부. 신규 default ON.
    /// HK BG handler가 target 도달 감지 시 이 값을 보고 fire 결정.
    @State private var notifyOnGoalReached: Bool = true
    // legacy: 시간대 chip은 UI에서 제거됨. Core Data 호환 위해 state는 유지 (save 시 .none 고정).
    @State private var startTimeOfDay: TimeOfDay = .none
    @State private var dueTimeOfDay: TimeOfDay = .none
    // 알림 offset (분). nil = 알림 OFF. 0 = 정시. 음수 = 사전 알림.
    @State private var ntdStartAlertOffset: Int?
    @State private var ntdEndAlertOffset: Int?
    // Todo: 시작/마감 알림 별도 — 단일 모드는 시작만, 기간 모드는 둘 다.
    @State private var todoStartAlertOffset: Int?
    @State private var todoDueAlertOffset: Int?

    /// 날짜·시각 chip 클릭 시 인라인 확장 (iOS Calendar 패턴).
    /// 날짜·시각이 별도 subchip으로 분리됐기 때문에 expansion도 calendar/time 둘로 나뉨.
    /// recurrenceEnd는 calendar 전용.
    @State private var dateExpansion: DateExpansion = .none
    /// NTD 목표 시간 row 확장 여부 (인라인 wheel).
    @State private var durationExpanded: Bool = false

    enum DateExpansion {
        case none
        case startCalendar, startTime
        case dueCalendar, dueTime
        case recurrenceEnd
    }

    /// 인라인 캘린더/시각 wheel이 적용되는 날짜 필드.
    /// recurrenceEnd는 별도 경로 (recurrenceEndBinding) — 여기 포함 X.
    enum DateField { case start, due }

    @State private var showDeleteConfirm = false
    @State private var showCancelConfirm = false
    @State private var showRecurrenceSheet = false
    /// 활동 기록 "전체 보기" sheet — NavigationLink push 대신 sheet로 띄움.
    /// 이유: monthview 가로 swipe가 NavigationStack back-swipe와 충돌해 의도치 않게 pop되는 회귀 회피.
    @State private var showFullHistory = false
    @State private var showPeriod: Bool
    @State private var recurrenceConfig: RecurrenceConfig?
    /// 선택된 카테고리 id. nil이면 미분류.
    @State private var selectedCategoryID: UUID?
    /// 카테고리 picker sheet 노출 여부.
    @State private var showCategoryPicker: Bool = false
    /// 목표(절제/활동) 전용 — 사용자 지정 아이콘. nil=미선택(저장 불가).
    @State private var goalIcon: GoalIcon?
    /// 사용자가 picker grid에서 GoalIcon을 직접 골랐는지 — type 변경 시 자동 갱신 가드.
    /// false면 type 변경할 때마다 `newKind.defaultGoalIcon`으로 자동 갱신. true면 보존.
    /// 편집 모드 진입 시엔 true(이미 사용자 선택 상태로 간주). 신규는 false 시작.
    @State private var userPickedGoalIcon: Bool = false
    /// 목표 전용 — 사용자 지정 색. nil=미선택(저장 불가).
    @State private var goalColor: CategoryColor?
    /// 체크리스트 draft 배열 — 저장 시 reconcile.
    /// active(soft-deleted 아닌) ChecklistItem만 form에 노출. 사용자가 minus 누르면 array에서 제거 →
    /// save 시 매칭 existing은 soft-delete(deletedAt 마킹). 새 draft는 새 ChecklistItem 생성.
    @State private var checklistDrafts: [ChecklistDraft] = []
    /// 알림 권한 상태 — 사용자가 시스템에서 거부한 경우 알림 section에 안내 표시.
    @State private var notificationAuthStatus: UNAuthorizationStatus = .authorized
    /// 저장 시 알림 있는데 권한 거부 상태면 확인 dialog.
    @State private var showPermissionSaveAlert: Bool = false
    /// 저장 시 누락 항목 안내 alert. canSave=false일 때 사용자가 저장 시도하면 뭘 채워야 하는지 안내.
    @State private var showMissingFieldsAlert: Bool = false
    /// 목표 저장 시 반복 미설정 confirmation alert — 사용자가 의도적으로 1회성인지 확인.
    @State private var showOneOffGoalAlert: Bool = false
    /// 편집 모드 활동/집중에서 target 값이 바뀐 경우 안내 alert — 변경값이 신규 occurrence부터 적용된다는 안내.
    @State private var showTargetChangedAlert: Bool = false
    /// 편집 시작 시점의 activityTarget. 저장 시 변경 감지에 사용 (활동·집중 공통, focus는 분 단위).
    @State private var originalActivityTarget: Int = 0
    @Environment(\.scenePhase) private var addItemScenePhase
    @Environment(\.openURL) private var openURL
    /// 새로 추가한 draft 자동 focus.
    @FocusState private var focusedChecklistDraft: UUID?

    /// 체크리스트 편집용 draft. id는 existing ChecklistItem과 매칭 (또는 새 UUID).
    struct ChecklistDraft: Identifiable {
        let id: UUID
        var title: String
    }

    /// 정렬된 카테고리 목록 — picker 옵션.
    @FetchRequest(
        sortDescriptors: [SortDescriptor(\Category.sortOrder), SortDescriptor(\Category.createdAt)],
        animation: .default
    )
    private var categories: FetchedResults<Category>

    init(editing: Item? = nil, baseDate: Date? = nil, categoryID: UUID? = nil, goalKind: ItemKind? = nil) {
        self.editingItem = editing
        // 모든 startDate/dueDate state는 UTC anchor Date로 통일.
        // 새 항목의 default 또는 nil fallback도 todayCalendarAnchor 사용.
        if let item = editing {
            _title = State(initialValue: item.title ?? "")
            _notes = State(initialValue: item.notes ?? "")
            _kind = State(initialValue: item.itemKind)
            _hasStart = State(initialValue: item.startDate != nil)
            _startDate = State(initialValue: item.startDate ?? .todayCalendarAnchor)
            _hasDue = State(initialValue: item.dueDate != nil)
            _dueDate = State(initialValue: item.dueDate ?? Self.defaultDueDate(after: item.startDate))
            _priority = State(initialValue: item.itemPriority)
            _showPeriod = State(initialValue: Self.shouldUsePeriodMode(
                start: item.startDate, due: item.dueDate,
                startHour: item.startHourInt, dueHour: item.dueHourInt
            ))
            // 시각: non-optional. startHour 0~23, dueHour 0~24 (24=시간 미설정).
            // NTD에서 startHour==0(legacy nil)은 의미 모호 → default 정각으로 보정.
            let resolvedStartHour: Int = {
                if item.itemKind == .notTodo, item.startHour == nil {
                    return Item.defaultNextTopOfHour
                }
                return item.startHourInt
            }()
            _startHour = State(initialValue: resolvedStartHour)
            // NTD는 dueHour 미사용이라 startHour와 sync해 hasTime=true 유지 (시간 chip 노출 보장).
            // legacy NTD가 dueHour=24로 저장된 경우 hasTime=false로 잡혀 chip 숨겨지는 버그 방지.
            if item.itemKind == .notTodo {
                _dueHour = State(initialValue: resolvedStartHour)
            } else {
                _dueHour = State(initialValue: item.dueHourInt)
            }
            _recurrenceEndDate = State(initialValue: item.recurrenceEndDate)
            _ntdDurationHour = State(initialValue: item.ntdDurationHourInt)
            let originalT = item.activityTargetValueInt ?? 0
            _activityTarget = State(initialValue: originalT)
            _originalActivityTarget = State(initialValue: originalT)
            _activitySource = State(initialValue: item.activitySource)
            // 편집 모드 — nil이면 ON으로 해석 (legacy 데이터 default ON).
            _notifyOnGoalReached = State(initialValue: item.notifyOnGoalReached?.boolValue ?? true)
            // 기존 Reminder 레코드에서 알림 offset 복원 (anchor별 1개 가정).
            let reminders = (item.reminders as? Set<Reminder>) ?? []
            let startReminder = reminders.first { ReminderAnchor(rawValue: $0.anchor) == .start }
            let dueReminder = reminders.first { ReminderAnchor(rawValue: $0.anchor) == .due }
            if item.itemKind == .notTodo {
                _ntdStartAlertOffset = State(initialValue: startReminder.map { Int($0.offsetMin) })
                _ntdEndAlertOffset = State(initialValue: dueReminder.map { Int($0.offsetMin) })
                _todoStartAlertOffset = State(initialValue: nil)
                _todoDueAlertOffset = State(initialValue: nil)
            } else {
                _ntdStartAlertOffset = State(initialValue: nil)
                _ntdEndAlertOffset = State(initialValue: nil)
                _todoStartAlertOffset = State(initialValue: startReminder.map { Int($0.offsetMin) })
                _todoDueAlertOffset = State(initialValue: dueReminder.map { Int($0.offsetMin) })
            }
            if let rule = item.recurrenceRule {
                _recurrenceConfig = State(initialValue: RecurrenceConfig(from: rule))
            } else {
                _recurrenceConfig = State(initialValue: nil)
            }
            _selectedCategoryID = State(initialValue: item.category?.id)
            // 목표 아이콘·색 — 기존 값 있으면 복원, 없으면 nil.
            _goalIcon = State(initialValue: GoalIcon.from(item.iconName))
            // 편집 진입은 사용자가 이미 선택한 상태로 간주 — type 바꿔도 보존.
            _userPickedGoalIcon = State(initialValue: item.iconName != nil)
            _goalColor = State(initialValue: item.iconColorHex.flatMap { CategoryColor(rawValue: $0) })
            // 체크리스트 — active만 load, sortOrder asc.
            let allChecklist = (item.checklistItems as? Set<ChecklistItem>) ?? []
            let activeChecklist = allChecklist
                .filter { $0.isActive }
                .sorted { $0.sortOrder < $1.sortOrder }
            _checklistDrafts = State(initialValue: activeChecklist.map {
                ChecklistDraft(id: $0.id ?? UUID(), title: $0.title ?? "")
            })
        } else {
            _title = State(initialValue: "")
            _notes = State(initialValue: "")
            // goalKind preset 있으면 그 type으로 시작 (필터 활성 시 (+) 탭 케이스).
            // 추가적인 kind별 default(시작시간/duration 등)는 .task에서 handleKindChange로 적용.
            _kind = State(initialValue: goalKind ?? .todo)
            if let base = baseDate {
                // baseDate는 호출자(TodayView)가 UTC anchor로 넘김.
                _hasStart = State(initialValue: true)
                _startDate = State(initialValue: base)
                _hasDue = State(initialValue: true)
                _dueDate = State(initialValue: base)
            } else {
                _hasStart = State(initialValue: false)
                _startDate = State(initialValue: .todayCalendarAnchor)
                _hasDue = State(initialValue: false)
                _dueDate = State(initialValue: Self.defaultDueDate(after: nil))
            }
            _priority = State(initialValue: .none)
            _showPeriod = State(initialValue: false)
            // 새 항목 default — hasTime=false (종일 일정): dueHour=24 sentinel.
            // startHour는 사용자가 시간설정 toggle ON 시 wheel default로 사용.
            _startHour = State(initialValue: Item.defaultNextTopOfHour)
            _dueHour = State(initialValue: 24)
            _recurrenceEndDate = State(initialValue: nil)
            _ntdDurationHour = State(initialValue: nil)  // 미설정 = 한계까지
            _activityTarget = State(initialValue: 0)     // 신규 활동: 사용자 명시 입력 필요
            _activitySource = State(initialValue: .manual)  // 신규는 수동 default
            _notifyOnGoalReached = State(initialValue: true)  // 신규 default ON
            // 새 항목 알림 default:
            //  - NTD: 시작/종료 모두 정시(0) ON
            //  - Todo: OFF (사용자 명시 ON)
            _ntdStartAlertOffset = State(initialValue: 0)
            _ntdEndAlertOffset = State(initialValue: 0)
            _todoStartAlertOffset = State(initialValue: nil)
            _todoDueAlertOffset = State(initialValue: nil)
            _recurrenceConfig = State(initialValue: nil)
            // 카테고리 — 호출자가 명시한 categoryID 우선 (필터 적용 상태에서 신규 추가 등).
            _selectedCategoryID = State(initialValue: categoryID)
            // 목표 아이콘·색.
            // - 아이콘: 미선택 (저장 시 검증 — 사용자가 명시 선택해야 함).
            // - 색: 신규는 랜덤 preset (아이콘 grid의 background가 색에 의존하므로 색 미설정 상태에서
            //   아이콘 미리보기가 회색이 되어 시각 약함 → 색은 자동 선택, 사용자가 원하면 변경).
            _goalIcon = State(initialValue: nil)
            _userPickedGoalIcon = State(initialValue: false)
            _goalColor = State(initialValue: CategoryColor.allCases.randomElement())
            // 체크리스트 — 신규는 빈 배열로 시작.
            _checklistDrafts = State(initialValue: [])
        }
    }


    /// 기간 모드 판정 — `Item.isSingleSchedule`의 inverse.
    /// - 다른 날짜 → 기간
    /// - 같은 날짜 + dueHour==24 (시간 미설정) → 단일
    /// - 같은 날짜 + startHour==dueHour → 단일
    /// - 같은 날짜 + startHour!=dueHour → 기간
    private static func shouldUsePeriodMode(start: Date?, due: Date?, startHour: Int, dueHour: Int) -> Bool {
        guard let start, let due else { return false }
        if !Calendar.gmt.isDate(start, inSameDayAs: due) { return true }
        if dueHour == 24 { return false }  // 시간 미설정 종일 → 단일
        return startHour != dueHour
    }

    private var isEditing: Bool { editingItem != nil }

    /// 활동 기록(`routineHistoryRecords`) 1+ 보유 여부 — 상단 아이콘 버튼 노출 조건.
    private var hasHistoryRecords: Bool {
        guard let item = editingItem else { return false }
        return !item.routineHistoryRecords.isEmpty
    }
    private var isNTD: Bool { kind == .notTodo }
    /// 목표(절제/활동/집중/습관) 그룹 판정 — 같은 섹션·같은 입력 UI 사용.
    private var isGoal: Bool { kind.isGoal }
    private var isActivity: Bool { kind == .activity }
    /// 습관 판정 — 시각 UI(기간/시간설정) 숨김용.
    private var isHabit: Bool { kind == .habit }
    /// 집중 판정 — target 분 입력 + 알림 숨김 + source picker 숨김.
    private var isFocus: Bool { kind == .focus }

    /// 입력폼 top-level 종류 — 할일 vs 목표. 데이터 모델 ItemKind는 평면 3-way지만 UI에선 2-level로 표현.
    enum TopLevelKind: Hashable {
        case todo, goal
    }

    /// Top picker(할일/목표) binding. 토글 시 kind state도 변경 + handleKindChange 호출.
    private var topLevelKindBinding: Binding<TopLevelKind> {
        Binding(
            get: { isGoal ? .goal : .todo },
            set: { newTop in
                switch newTop {
                case .todo:
                    let newKind = ItemKind.todo
                    kind = newKind
                    handleKindChange(newKind)
                case .goal:
                    // 목표 첫 진입 default = 절제. 이전에 활동 선택 후 todo→목표 토글이면 절제로 reset.
                    let newKind = ItemKind.notTodo
                    kind = newKind
                    handleKindChange(newKind)
                }
            }
        )
    }

    /// 저장 가능 여부 — 제목 필수. 목표는 추가로 아이콘·색상 필수.
    private var canSave: Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if isGoal {
            guard goalIcon != nil, goalColor != nil else { return false }
        }
        // 활동/집중은 추가로 목표 수치(>0) 필수.
        if (isActivity || isFocus), activityTarget <= 0 { return false }
        return true
    }

    /// 저장 버튼 탭 핸들러 — 검증 alerts 순차 처리.
    /// 순서 원칙: **외부 이동(시스템 prompt / 설정 앱 / sheet)** 가능 단계 먼저, **정보성 확인** 단계 뒤.
    /// 사용자가 외부 이동 후 돌아오면 저장 다시 누름 → chain 처음부터 다시 타게 됨 → 정보성 dialog 중복 노출 회피.
    /// 1. canSave=false → 누락 필드 안내 (terminate)
    /// 2. 활동 + auto source → HealthKit 권한 요청 (시스템 prompt, 미결정시만)
    /// 3. 알림 권한 거부 → permission warning (설정 앱 이동 가능)
    /// 4. 신규 목표 + 반복 미설정 → 1회성 confirmation (반복 sheet 이동 가능)
    /// 5. 편집 + 활동/집중 + target 변경 → 변경값 적용 범위 안내 (정보성 확인)
    /// 6. save()
    ///
    /// 다이얼로그 중첩 회피: 모든 alert는 state-flag 기반이라 동시에 두 개가 뜨지 않음.
    /// 각 alert의 confirm 버튼이 다음 step의 helper를 호출 — 순차 chain 보장.
    private func attemptSave() {
        if !canSave {
            showMissingFieldsAlert = true
            return
        }
        // HK auto source → 권한 요청 후 저장 흐름 이어감. 이미 결정된 경우 prompt 없이 즉시 반환.
        // 거부돼도 저장은 진행 — 다음 sync 시 fetch nil로 단순히 자동 갱신 안 됨.
        if isActivity, activitySource != .manual {
            Task {
                _ = await HealthKitService.shared.requestAuthorization(for: activitySource)
                await MainActor.run { checkNotificationPermission() }
            }
            return
        }
        checkNotificationPermission()
    }

    /// HK 단계 이후 — 알림 권한 거부 경고 분기.
    private func checkNotificationPermission() {
        if hasAlertConfigured && notificationAuthStatus == .denied {
            showPermissionSaveAlert = true
            return
        }
        checkOneOffGoal()
    }

    /// 알림 권한 단계 이후 — 신규 목표가 반복 미설정이면 1회성 confirmation.
    private func checkOneOffGoal() {
        if !isEditing, isGoal, recurrenceConfig == nil {
            showOneOffGoalAlert = true
            return
        }
        checkTargetChange()
    }

    /// 마지막 정보성 단계 — 편집 모드 활동/집중 target 변경 안내. 이후 save.
    private func checkTargetChange() {
        if hasActivityTargetChanged {
            showTargetChangedAlert = true
            return
        }
        save()
    }

    /// 편집 모드 활동/집중에서 target 값이 바뀌었는지.
    /// 신규 항목은 항상 false. focus는 분 단위 target.
    private var hasActivityTargetChanged: Bool {
        guard isEditing, (isActivity || isFocus) else { return false }
        return activityTarget != originalActivityTarget
    }

    /// canSave=false 시 alert에 표시할 누락 항목 안내 문구.
    /// 누락된 필드만 bullet으로 나열.
    private var missingFieldsMessage: String {
        var lines: [String] = []
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("- " + String(localized: "add.field.title"))
        }
        if isGoal {
            if goalIcon == nil {
                lines.append("- " + String(localized: "add.section.goal_icon"))
            }
            if goalColor == nil {
                lines.append("- " + String(localized: "add.section.goal_color"))
            }
        }
        if (isActivity || isFocus), activityTarget <= 0 {
            lines.append("- " + String(localized: isFocus ? "add.field.focus_target" : "add.field.activity_target"))
        }
        let header = String(localized: "alert.missing_fields.body")
        return header + "\n" + lines.joined(separator: "\n")
    }

    /// 반복 설정은 일정(시작일)이 있을 때만 의미 있음 — 미정(hasStart=false)이면 anchor가 없어 반복 정의 불가.
    /// NTD는 추가로 목표 시간이 있어야 의미 있음 (미설정 = 1회성).
    private var isRecurrenceSectionVisible: Bool {
        guard hasStart else { return false }
        if isNTD { return ntdDurationHour != nil }
        return true
    }

    private var alertOffsetOptions: [Int] {
        // NTD는 항상 hasTime=true. Todo의 hasTime에 따라 옵션 세트 결정.
        hasTime ? AlertOffset.withTimeOptions : AlertOffset.noTimeOptions
    }

    /// 현재 form에 알림이 하나라도 설정돼 있는지 — 저장 시 권한 경고 dialog 표시 여부 판정용.
    private var hasAlertConfigured: Bool {
        if isNTD {
            if ntdStartAlertOffset != nil { return true }
            if ntdDurationHour != nil, ntdEndAlertOffset != nil { return true }
            return false
        }
        // 활동: 목표 달성 알림 toggle도 alert 의도로 카운트 (default ON이라 사용자가 안 만져도 활성).
        // 시작 알림 offset과 별개로 HK BG handler가 target 도달 시 fire하므로 권한 필요.
        if isActivity {
            if notifyOnGoalReached { return true }
            if todoStartAlertOffset != nil { return true }
            return false
        }
        if !(hasStart || hasDue) { return false }
        if todoStartAlertOffset != nil { return true }
        if showPeriod, todoDueAlertOffset != nil { return true }
        return false
    }

    /// 알림 section.
    /// - NTD: 시작 알림 + (목표 시간 있을 때) 목표 달성 알림 — 기본 모두 ON.
    /// - Todo: startDate/dueDate 중 하나라도 있으면 노출 — hasDue면 "마감 알림"(.due anchor),
    ///   hasStart만 있으면(단일 모드 반복 등) "시작 알림"(.start anchor).
    /// Picker selection은 Optional<Int> — nil이면 알림 OFF, 정수는 offset(분).
    @ViewBuilder
    private var alertSection: some View {
        if isNTD {
            Section("add.section.alert") {
                if notificationAuthStatus == .denied {
                    notificationPermissionWarning
                }
                alertOffsetPicker(label: "alert.label.start", selection: $ntdStartAlertOffset)
                if ntdDurationHour != nil {
                    alertOffsetPicker(label: "alert.label.end", selection: $ntdEndAlertOffset)
                }
            }
        } else if isActivity {
            // 활동: 시작 알림(시작일 0시 기준) + 목표 달성 알림 toggle (HK BG handler가 target 도달 시 fire).
            // 종일 의미라 마감 알림은 없음.
            Section("add.section.alert") {
                if notificationAuthStatus == .denied {
                    notificationPermissionWarning
                }
                alertOffsetPicker(label: "alert.label.start", selection: $todoStartAlertOffset)
                Toggle(isOn: $notifyOnGoalReached) {
                    Text("add.field.goal_alert")
                }
            }
        } else if hasStart || hasDue {
            Section("add.section.alert") {
                if notificationAuthStatus == .denied {
                    notificationPermissionWarning
                }
                // 단일 모드: 시작 알림만 (단일은 시작=마감 같은 의미).
                // 기간 모드: 시작 알림 + 마감 알림 둘 다.
                alertOffsetPicker(label: "alert.label.start", selection: $todoStartAlertOffset)
                if showPeriod {
                    alertOffsetPicker(label: "alert.label.due", selection: $todoDueAlertOffset)
                }
            }
        }
    }

    /// 알림 권한 거부 안내 — 설정 열기 버튼.
    /// 사용자가 알림 offset을 골라도 실제 fire 안 되니 미리 알려줘 setting 가도록 유도.
    @ViewBuilder
    private var notificationPermissionWarning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bell.slash.fill")
                .foregroundStyle(.orange)
                .font(.callout)
            VStack(alignment: .leading, spacing: 2) {
                Text("alert.permission.denied.title")
                    .font(.subheadline.weight(.semibold))
                Text("alert.permission.denied.body")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            } label: {
                Text("alert.permission.open_settings")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    /// 단일 알림 picker — menu style. "안 함" + offset 옵션 (hasTime에 따라 세트 다름).
    private func alertOffsetPicker(label: LocalizedStringKey, selection: Binding<Int?>) -> some View {
        Picker(selection: selection) {
            Text("alert.offset.disabled").tag(Optional<Int>.none)
            ForEach(alertOffsetOptions, id: \.self) { offset in
                Text(verbatim: AlertOffset.label(for: offset)).tag(Optional(offset))
            }
        } label: {
            Text(label)
        }
        .pickerStyle(.menu)
    }

    /// 체크리스트 section — title TextField 목록 + minus 버튼 + 추가 버튼.
    /// soft delete 정책 — minus는 draft 배열에서만 제거, 저장 시 existing은 deletedAt 마킹.
    /// submit(.next) 시 비어있지 않으면 새 draft 자동 추가 + 포커스 이동 → 키보드 내리지 않고 연속 입력.
    /// 빈 draft에서 submit하면 키보드 dismiss + 그 빈 draft 제거 (사용자가 끝낼 신호).
    @ViewBuilder
    private var checklistSection: some View {
        Section("add.section.checklist") {
            ForEach($checklistDrafts) { $draft in
                HStack(spacing: 8) {
                    TextField("add.checklist.placeholder", text: $draft.title)
                        .focused($focusedChecklistDraft, equals: draft.id)
                        // iOS 26 keyboard가 .next/.continue를 chevron(>)으로 표시.
                        .submitLabel(.continue)
                        // 키보드 chevron이 앱 tint(brown 등)로 보여 가독성 낮음 — system blue 명시.
                        // 커서도 blue가 되지만 입력 영역에서 강조 색은 시인성 우선.
                        .tint(.blue)
                        .onSubmit {
                            handleChecklistSubmit(draftID: draft.id)
                        }
                    Button(role: .destructive) {
                        checklistDrafts.removeAll { $0.id == draft.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                appendChecklistDraftAndFocus()
            } label: {
                Label("add.checklist.add", systemImage: "plus.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    // 글자/아이콘 옆 빈 공간도 탭 가능하도록 row 전체 hit area 확장.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// 새 빈 draft를 끝에 추가하고 자동 포커스.
    private func appendChecklistDraftAndFocus() {
        let newDraft = ChecklistDraft(id: UUID(), title: "")
        checklistDrafts.append(newDraft)
        focusedChecklistDraft = newDraft.id
    }

    /// TextField submit 처리 — 빈 입력이면 키보드 dismiss + 그 draft 제거.
    /// 입력 있으면 새 draft 추가 + 포커스 이동 (연속 입력).
    private func handleChecklistSubmit(draftID: UUID) {
        guard let idx = checklistDrafts.firstIndex(where: { $0.id == draftID }) else { return }
        let trimmed = checklistDrafts[idx].title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // 빈 입력에서 submit → 사용자가 마치는 신호. 그 draft 제거하고 키보드 내림.
            checklistDrafts.remove(at: idx)
            focusedChecklistDraft = nil
            return
        }
        // 입력 있음 → 새 draft 추가하고 포커스.
        appendChecklistDraftAndFocus()
    }

    /// 입력 폼에 미저장 변경사항이 있는지.
    /// - 새 항목: 제목 또는 메모에 텍스트 입력 시 true.
    /// - 편집 항목: 현재 state가 editingItem 저장값과 다를 때 true.
    /// 사용처: 저장 버튼 색상(빨강), 취소 시 confirm 표시.
    private var hasChanges: Bool {
        guard let item = editingItem else {
            return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if (item.title ?? "") != title { return true }
        if (item.notes ?? "") != notes { return true }
        if item.itemKind != kind { return true }
        if (item.startDate != nil) != hasStart { return true }
        if hasStart, let s = item.startDate, s != startDate { return true }
        if (item.dueDate != nil) != hasDue { return true }
        if hasDue, let d = item.dueDate, d != dueDate { return true }
        if item.itemPriority != priority { return true }
        // 시각 — save 정규화 후 값과 비교 (hasTime/showPeriod 반영).
        let effectiveStartH: Int
        let effectiveDueH: Int
        if kind == .notTodo {
            effectiveStartH = startHour
            effectiveDueH = startHour  // NTD save와 동일 — startHour와 sync
        } else if !hasTime {
            effectiveStartH = 0
            effectiveDueH = 24
        } else {
            effectiveStartH = startHour
            effectiveDueH = showPeriod ? dueHour : startHour
        }
        if item.startHourInt != effectiveStartH { return true }
        if item.dueHourInt != effectiveDueH { return true }
        // 반복 종료일.
        if item.recurrenceEndDate != recurrenceEndDate { return true }
        // 카테고리.
        if item.category?.id != selectedCategoryID { return true }
        // 목표 아이콘/색.
        if item.iconName != goalIcon?.rawValue { return true }
        if item.iconColorHex != goalColor?.rawValue { return true }
        // NTD 목표 시간.
        if kind == .notTodo {
            if item.ntdDurationHourInt != ntdDurationHour { return true }
        }
        // 활동 목표 수치.
        if kind == .activity {
            if (item.activityTargetValueInt ?? 0) != activityTarget { return true }
        }
        // 반복 규칙 비교.
        let hadRule = (item.recurrenceRule != nil)
        let hasConfig = (recurrenceConfig != nil)
        if hadRule != hasConfig { return true }
        if let rule = item.recurrenceRule, let config = recurrenceConfig {
            if rule.itemFrequency != config.frequency { return true }
            if rule.interval != config.interval { return true }
            if rule.selectedWeekdays != config.weekdays { return true }
            if rule.selectedDays != config.days { return true }
            if rule.includesLastDay != config.includesLastDay { return true }
            if rule.selectedMonths != config.months { return true }
        }
        // 체크리스트 비교 — active만, sortOrder asc 순서로 (id, trimmedTitle) tuple 비교.
        let existingChecklist = ((item.checklistItems as? Set<ChecklistItem>) ?? [])
            .filter { $0.isActive }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { ($0.id ?? UUID(), ($0.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) }
        let draftChecklist = checklistDrafts.map {
            ($0.id, $0.title.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // 빈 제목 draft는 save에서 skip되므로 비교 시 제외.
        let draftFiltered = draftChecklist.filter { !$0.1.isEmpty }
        if existingChecklist.count != draftFiltered.count { return true }
        for (a, b) in zip(existingChecklist, draftFiltered) {
            if a.0 != b.0 || a.1 != b.1 { return true }
        }
        return false
    }

    /// 편집 시엔 "할일 수정" / "비움 수정"처럼 kind를 타이틀에 명시.
    /// (편집 모드에서 kind picker를 숨겼기 때문에 사용자가 종류를 파악할 단서로 사용.)
    private var navigationTitleText: String {
        if isEditing {
            return String.localizedStringWithFormat(
                NSLocalizedString("add.title.edit_format", comment: ""),
                kind.displayName
            )
        }
        return String(localized: "add.title.new")
    }

    var body: some View {
        NavigationStack {
            // .appTint()을 NavigationStack 안쪽에도 적용 — iOS 26에서 sheet root의 tint가
            // 일정 idle 후 환경에서 사라지는 케이스 방어 (사용자 보고: ~1분 후 form 전체 tint 풀림).
            // 외부에도 .appTint()가 한 번 더 있음 (belt-and-suspenders).
            Form {
                // 편집 모드 — 항목 유형 식별 배지 (kind picker 숨김 보완).
                // 신규에서는 picker/chip으로 type 선택, 편집에선 type 변경 불가니까
                // 어떤 유형(할일/목표 4종)인지 시각적으로 확인할 수 있도록 filled circle 가운데 표시.
                // 섹션 카드 배경은 숨김 — Form 위에 떠 있는 듯한 시각. 제목 섹션 위(form 최상단)에 배치.
                if isEditing {
                    Section {
                        HStack {
                            Spacer()
                            ZStack {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 64, height: 64)
                                Image(systemName: isGoal ? kind.goalTypeSymbolName : "checkmark")
                                    .font(.title.weight(.semibold))
                                    .foregroundStyle(.white)
                            }
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                    }
                    .listSectionSpacing(.compact)
                }

                Section {
                    TextField("add.field.title", text: $title)
                        .focused($titleFocused)
                    TextField("add.field.notes", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    // 빈 header 영역을 활용해 우측 정렬 활동 기록 아이콘 버튼 노출.
                    // 편집 모드 + 기록 1+ 일 때만. 평소엔 빈 header → 시각 영향 없음.
                    // capsule + tint 배경으로 "버튼" 느낌 강조 (header text plain 텍스트와 시각 구분).
                    if isEditing, hasHistoryRecords {
                        HStack {
                            Spacer()
                            Button {
                                showFullHistory = true
                            } label: {
                                Image(systemName: "calendar.badge.clock")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("activity_history.show_all")
                        }
                    }
                }

                // 종류 picker. 편집 시엔 숨김 (kind 변환은 의미 shift 위험).
                // Top-level: 할일/목표 segmented.
                if !isEditing {
                    Section {
                        Picker(selection: topLevelKindBinding) {
                            Text("kind.top.todo").tag(TopLevelKind.todo)
                            Text("kind.top.goal").tag(TopLevelKind.goal)
                        } label: {
                            Text("add.section.kind")
                        }
                        .pickerStyle(.segmented)
                    }

                    // 목표 선택 시 — 별도 "목표 유형" section에 4 chip 가로 + 선택한 유형 설명.
                    if isGoal {
                        Section("add.section.goal_type") {
                            goalTypeRow
                        }
                    }
                }

                // 목표(절제/활동): 색·아이콘 통합 섹션. 아이콘 grid 위, 색상 chip 아래.
                // Todo: 카테고리 + 우선순위 (기존 그대로).
                if isGoal {
                    Section("add.section.goal_icon") {
                        goalIconGrid
                        // 색상 row — 같은 섹션 내 아래에 배치. 아이콘 grid의 background는 이 색을 사용.
                        goalColorGrid
                    }
                } else {
                    // 카테고리 — Todo 한정. 등록된 카테고리가 없으면 section 자체 숨김 (진입 장벽 0).
                    if !categories.isEmpty {
                        Section("add.section.category") {
                            categoryPickerRow
                        }
                    }
                    // Todo 전용: 우선순위.
                    Section("add.section.priority") {
                        HStack(spacing: 12) {
                            ForEach(Priority.pickerOrder, id: \.self) { p in
                                priorityButton(p)
                            }
                            Spacer()
                        }
                    }
                }

                // 활동/집중 입력 section — target 수치 입력 공유. focus는 source picker 숨김.
                if isActivity || isFocus {
                    Section(isFocus ? "add.section.focus" : "add.section.activity") {
                        // Source chip row + 안내 (activity 전용; focus는 자체 timer 시스템이라 source 불필요).
                        if isActivity {
                            // chip: 수동 / 걸음수 / 거리 / 칼로리 / 계단. 횡스크롤 X — HStack flow.
                            // HealthKit 권한 요청은 저장 시점에 처리 (attemptSave) — 선택할 때마다 prompt 뜨지 않게.
                            //
                            // **편집 모드**: 현재 source만 display (변경 불가).
                            // 이유: source 변경 시 기존 RC.valueRecorded의 의미가 달라짐
                            // (예: 5000이 걸음수 → 거리(m) → 칼로리(kcal)로 의미가 shift).
                            //
                            // 안내:
                            // - manual: 자동 측정 불가 항목 안내 (단순 hint) — 신규 작성 시에만 (편집은 변경 불가).
                            // - auto: 권한 거부 시 건강 앱 link로 안내 (편집에서도 유효 — 권한 토글).
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 6) {
                                    if isEditing {
                                        sourceChip(activitySource, titleKey: activitySourceTitleKey(activitySource), locked: true)
                                        Spacer()
                                    } else {
                                        sourceChip(.manual, titleKey: "activity_source.manual")
                                        sourceChip(.steps, titleKey: "activity_source.steps")
                                        sourceChip(.distance, titleKey: "activity_source.distance")
                                        sourceChip(.calories, titleKey: "activity_source.calories")
                                        sourceChip(.flights, titleKey: "activity_source.flights")
                                    }
                                }
                                if activitySource == .manual {
                                    if !isEditing {
                                        manualSourceHint
                                    }
                                } else {
                                    autoSourcePermissionHint
                                }
                            }
                            .padding(.vertical, 4)
                        }

                        // Target value 필드 + quick add chip을 한 Form row(VStack)로 묶어 사이 분리선 제거.
                        // 큰 수치 입력 부담 회피 — quick increment chip(+1/+10/+100/+1000/초기화).
                        // focus는 label "목표 시간" + 단위 "분", activity는 label "목표 수치" + source별 단위.
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(isFocus ? "add.field.focus_target" : "add.field.activity_target")
                                    .foregroundStyle(.primary)
                                Spacer()
                                TextField("0", value: $activityTarget, format: .number)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 100)
                                    .focused($activityTargetFocused)
                                // 단위 hint — focus는 항상 "분", activity는 source별.
                                if let unit = activityUnitHint {
                                    Text(verbatim: unit)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            activityQuickAddRow
                        }
                        .padding(.vertical, 4)
                    }
                }

                // 일정 + 반복 통합 섹션 — 카테고리/색상 아래로 이동.
                // 반복 row는 일정 anchor가 있을 때만(isRecurrenceSectionVisible) 노출.
                Section("add.section.schedule") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            // NTD/습관/활동은 발생 calendar date 필수 + 단일 시작일만 의미 있음.
                            // → "미정"/"기간"/"시간설정" chip 모두 숨김.
                            if !isNTD && !isHabit && !isActivity && !isFocus {
                                quickChip("add.chip.no_date", daysFromToday: nil)
                            }
                            quickChip("add.chip.today", daysFromToday: 0)
                            // 목표는 "Tomorrow", 할일은 "+1" — Todo는 D-day 중심이라 +1이 더 직관적,
                            // 목표(절제/활동/집중/습관)는 1회성 의미가 강해 "내일"이 더 자연스러움.
                            quickChip(isGoal ? "add.chip.tomorrow.goal" : "add.chip.tomorrow", daysFromToday: 1)
                            if !isNTD && !isHabit && !isActivity && !isFocus {
                                periodChip
                                // 시간 설정 toggle은 hasStart일 때만 의미 있음 — 미정이면 시각 설정 불가하니
                                // divider + chip 둘 다 숨김.
                                if hasStart {
                                    Rectangle()
                                        .fill(Color.secondary.opacity(0.3))
                                        .frame(width: 1, height: 20)
                                        .padding(.horizontal, 2)
                                    hasTimeChip
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }

                    // 시작 라인 — hasStart일 때 노출 (NTD는 anchor 필수라 항상 true).
                    // "시작" 라벨은 기간 모드일 때만 (단일 모드에선 종료가 같으니 라벨 불필요).
                    // 시간 chip은 hasTime ON일 때만 (NTD는 hasTime 강제 ON).
                    if hasStart {
                        HStack(spacing: 12) {
                            if showPeriod {
                                Text("add.label.start")
                                    .foregroundStyle(.primary)
                            }
                            Spacer()
                            dateSubchip(active: hasStart,
                                        expanded: dateExpansion == .startCalendar,
                                        date: startDate) {
                                toggleDateExpansion(.startCalendar)
                            }
                            if hasTime {
                                timeSubchip(hour: startHour,
                                            expanded: dateExpansion == .startTime) {
                                    toggleDateExpansion(.startTime)
                                }
                            }
                        }
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        if dateExpansion == .startCalendar {
                            inlineCalendarEditor(for: .start)
                                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        } else if dateExpansion == .startTime && hasTime {
                            inlineTimeEditor(for: .start)
                                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        }
                    }

                    // 마감 라인 — 기간 모드 + Todo (NTD는 별도 마감 시각 없음).
                    if showPeriod && !isNTD && hasDue {
                        HStack(spacing: 12) {
                            Text("add.label.end")
                                .foregroundStyle(.primary)
                            Spacer()
                            dateSubchip(active: hasDue,
                                        expanded: dateExpansion == .dueCalendar,
                                        date: dueDate) {
                                toggleDateExpansion(.dueCalendar)
                            }
                            if hasTime {
                                timeSubchip(hour: dueHour,
                                            expanded: dateExpansion == .dueTime) {
                                    toggleDateExpansion(.dueTime)
                                }
                            }
                        }
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        if dateExpansion == .dueCalendar {
                            inlineCalendarEditor(for: .due)
                                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        } else if dateExpansion == .dueTime && hasTime {
                            inlineTimeEditor(for: .due)
                                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        }
                    }

                    // NTD 목표 시간 — 일정 section의 별도 row(고정). 탭하면 인라인 wheel 확장.
                    // 펼침 시 dateExpansion(.startTime 등)은 함께 접어 동시 펼침 방지.
                    if isNTD {
                        // 라벨 + chip 패턴 — 일정의 시간 선택 chip과 동일 UI (timeSubchip 패턴).
                        HStack {
                            Text("add.field.duration")
                                .foregroundStyle(.primary)
                            Spacer()
                            durationChip
                        }
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        if durationExpanded {
                            inlineDurationEditor
                                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        }
                    }

                    // 반복 row — 일정 anchor 있을 때만 (isRecurrenceSectionVisible).
                    // Todo: 항상 / NTD: 목표 시간 있을 때만. 일정 섹션 내 같은 위치에 통합.
                    if isRecurrenceSectionVisible {
                        Button {
                            showRecurrenceSheet = true
                        } label: {
                            HStack {
                                Text("add.field.recurrence")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(verbatim: recurrenceSummaryText)
                                    .foregroundStyle(recurrenceConfig == nil ? Color.secondary : Color.primary)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }

                        // 반복 종료일 row — 반복 패턴이 설정된 경우에만 노출.
                        if recurrenceConfig != nil {
                            Button {
                                toggleDateExpansion(.recurrenceEnd)
                            } label: {
                                HStack {
                                    Text("add.field.recurrence_end")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text(verbatim: recurrenceEndDisplayText)
                                        .foregroundStyle(dateExpansion == .recurrenceEnd ? Color.accentColor : Color.secondary)
                                    Image(systemName: dateExpansion == .recurrenceEnd ? "chevron.down" : "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                            if dateExpansion == .recurrenceEnd {
                                inlineRecurrenceEndEditor
                                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                            }
                        }
                    }
                }

                // 알림 section — NTD는 항상(시작/종료), Todo는 dueDate 있을 때만 마감 알림.
                // 집중은 시작 시각이 정해져 있지 않음(사용자가 원하는 시점) → 알림 의미 없음, 숨김.
                if !isFocus {
                    alertSection
                }

                // 체크리스트 section — Todo 전용. 목표(절제/활동)는 단일 의미라 체크리스트 비활성.
                if !isGoal {
                    checklistSection
                }

                if isEditing {
                    // 활동 기록 미리보기 section은 제거 — 화면 상단 chart 아이콘 버튼이 이미 entry point.
                    // 단일 entry로 통합해 중복 회피 + 편집 폼 단순화.

                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("common.delete", systemImage: "trash")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .alert(
                            "add.delete_alert.title",
                            isPresented: $showDeleteConfirm
                        ) {
                            Button("common.cancel", role: .cancel) {}
                            Button("common.delete", role: .destructive) { deleteItem() }
                        } message: {
                            // 할일 vs 목표 — 활동 기록 cascade 안내 + 호칭(을/를) 분기.
                            Text(isGoal ? "add.delete_alert.message.goal" : "add.delete_alert.message.todo")
                        }
                    }
                }
            }
            // 키보드 dismiss: 스크롤 시작 즉시 닫힘.
            // 이전엔 .simultaneousGesture(TapGesture)로 빈 영역 탭 시 닫게 했지만
            // Form 하단 Button(삭제/종료) 탭과 충돌해 제거.
            .scrollDismissesKeyboard(.immediately)
            // sheet 열 때 title focus 해제. sheet 닫혀도 자동 복귀 안 되도록.
            // (FocusState는 sheet 표시 중에도 유지돼, 닫히면 키보드가 다시 올라오는 문제 해결.)
            .onChange(of: dateExpansion)       { _, expansion in if expansion != .none { titleFocused = false } }
            .onChange(of: durationExpanded)    { _, expanded in if expanded { titleFocused = false } }
            .onChange(of: showRecurrenceSheet) { _, n in if n { titleFocused = false } }
            // NTD 목표 시간이 미설정(nil)되면 반복 설정도 자동 제거 — 미설정 NTD는 1회성 의미라 반복 불가.
            .onChange(of: ntdDurationHour) { _, new in
                if isNTD && new == nil { recurrenceConfig = nil }
            }
            .navigationTitle(navigationTitleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") {
                        if hasChanges {
                            showCancelConfirm = true
                        } else {
                            dismiss()
                        }
                    }
                    // 취소 버튼은 앱 테마 색 적용 X — 중립 회색으로 유지 (저장/주요 액션과 시각 구분).
                    .tint(.secondary)
                    .confirmationDialog(
                        "add.cancel_confirm.title",
                        isPresented: $showCancelConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("add.cancel_confirm.discard", role: .destructive) { dismiss() }
                        Button("common.cancel", role: .cancel) {}
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    // 변경사항이 있을 때만 빨강 강조. 기본 상태는 시스템 toolbar 기본 색상(.primary).
                    // canSave=false여도 disabled 안 함 — tap 시 어떤 항목이 누락됐는지 alert로 안내.
                    Button {
                        attemptSave()
                    } label: {
                        Text("common.save")
                            .foregroundStyle(hasChanges ? Color.red : Color.primary)
                    }
                    .alert(
                        "alert.permission.save_warning.title",
                        isPresented: $showPermissionSaveAlert
                    ) {
                        Button("alert.permission.open_settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                openURL(url)
                            }
                        }
                        Button("alert.permission.save_anyway") {
                            checkOneOffGoal()
                        }
                        Button("common.cancel", role: .cancel) {}
                    } message: {
                        Text("alert.permission.save_warning.body")
                    }
                    .alert(
                        "alert.missing_fields.title",
                        isPresented: $showMissingFieldsAlert
                    ) {
                        Button("common.ok", role: .cancel) {}
                    } message: {
                        Text(verbatim: missingFieldsMessage)
                    }
                    .alert(
                        "alert.goal_no_recurrence.title",
                        isPresented: $showOneOffGoalAlert
                    ) {
                        Button("alert.goal_no_recurrence.set_recurrence") {
                            showRecurrenceSheet = true
                        }
                        Button("alert.goal_no_recurrence.save_anyway") {
                            // 다음 step (target 변경 안내 → save) 으로 진행.
                            checkTargetChange()
                        }
                        Button("common.cancel", role: .cancel) {}
                    } message: {
                        Text("alert.goal_no_recurrence.body")
                    }
                    .alert(
                        "permission.health.dialog.title",
                        isPresented: $showHealthAppPathAlert
                    ) {
                        Button("common.cancel", role: .cancel) {}
                        Button("permission.health.dialog.confirm") {
                            if let url = URL(string: "x-apple-health://") {
                                openURL(url)
                            }
                        }
                    } message: {
                        Text("permission.health.dialog.message")
                    }
                    .alert(
                        "alert.target_changed.title",
                        isPresented: $showTargetChangedAlert
                    ) {
                        Button("common.cancel", role: .cancel) {}
                        Button("common.ok") {
                            save()
                        }
                    } message: {
                        Text(isFocus ? "alert.target_changed.body.focus" : "alert.target_changed.body.activity")
                    }
                }
            }
            .task {
                // 알림 권한 상태 fetch (편집/신규 무관) — 거부 시 alert section에 안내 노출.
                notificationAuthStatus = await NotificationService.shared.currentAuthorizationStatus()

                guard !isEditing else { return }
                // goalKind preset(필터 활성 시 (+) 탭)으로 시작했으면 kind별 defaults 적용.
                // init에서 kind만 set하고 다른 state는 default(.todo 기준)라 명시 호출 필요.
                if kind.isGoal {
                    handleKindChange(kind)
                }
                // 목표(절제/활동)는 카테고리 사용 안 함 — selectedCategoryID 무시.
                // Todo: categoryID arg로 init 시점에 이미 set된 경우, init은 .onChange 트리거 X →
                // 여기서 한 번 알림 default 수동 적용 (신규 항목 작성 시 1회).
                if !isGoal, let id = selectedCategoryID,
                   let cat = categories.first(where: { $0.id == id }) {
                    applyCategoryAlertDefaults(cat)
                }
                try? await Task.sleep(for: .milliseconds(120))
                titleFocused = true
            }
            // foreground 복귀 시 권한 재확인 — 사용자가 설정에서 허용/거부 변경했을 수 있음.
            .onChange(of: addItemScenePhase) { _, newPhase in
                if newPhase == .active {
                    Task {
                        notificationAuthStatus = await NotificationService.shared.currentAuthorizationStatus()
                    }
                }
            }
            // 카테고리 변경 시 알림 default 적용 — 신규 항목 작성 중에만.
            // 편집 모드: 사용자가 이미 설정한 알림 보존 (카테고리 바꿔도 알림은 그대로).
            .onChange(of: selectedCategoryID) { _, newID in
                guard !isEditing else { return }
                guard let id = newID,
                      let cat = categories.first(where: { $0.id == id }) else { return }
                applyCategoryAlertDefaults(cat)
            }
            .sheet(isPresented: $showRecurrenceSheet) {
                // presetDate: 사용자가 설정한 시작일자 기준 요일/일자 pre-set. 없으면 오늘.
                RecurrenceSheet(
                    initialConfig: recurrenceConfig,
                    presetDate: hasStart ? startDate : .todayCalendarAnchor,
                    onSave: { config in
                        recurrenceConfig = config
                        ensureStartDateForRecurrence()
                    },
                    onClear: {
                        recurrenceConfig = nil
                    }
                )
            }
            .sheet(isPresented: $showFullHistory) {
                // 활동 기록 전체 보기 — NavigationStack 안에 ActivityHistoryView. 자체 toolbar(닫기 버튼) 표시.
                if let item = editingItem {
                    NavigationStack {
                        ActivityHistoryView(item: item, showsCloseButton: true)
                    }
                    .appTint()
                }
            }
            // NavigationStack root에 직접 .appTint() — iOS 26 idle-tint-loss 방어.
            // 외곽 .appTint()와 함께 belt-and-suspenders로 propagation 보장.
            .appTint()
        }
        // 변경사항이 있으면 스와이프-다운으로 sheet 닫는 행위를 차단.
        // 닫을 때는 반드시 (x) 버튼을 통해서 → 확인 dialog 거치게 함 (실수 방지).
        // SwiftUI는 "드래그 시도 시 dialog 띄우기"를 직접 지원 안 함 → drag 자체를 막는 방식.
        .interactiveDismissDisabled(hasChanges)
        // .graphical DatePicker / 일부 UIKit-bridged 컴포넌트가 sheet 안에서
        // 루트 .tint를 잃고 시스템 기본(blue)으로 fallback되는 케이스 방어.
        .appTint()
    }

    /// kind 변경 시 state 일관성 유지.
    /// - .notTodo: 시작일 강제 ON, 단일 모드, startHour/duration default 적용 (신규만).
    /// - .activity: 시작일 ON. target value/unit은 별도 UI 입력 (Phase B/C).
    /// - .focus: 시작일 ON. timer target은 별도 UI (Phase D).
    /// - .habit: 시작일 ON, startHour=0/dueHour=24 종일 의미로 고정 (사용자에게 시간 UI 노출 X).
    /// - .todo: 별도 정리 없음 (목표 잔재는 save에서 정리).
    /// 목표는 카테고리 사용 안 함 → 신규 진입 시 selectedCategoryID 비움.
    private func handleKindChange(_ newKind: ItemKind) {
        // kind 변경 시 인라인 캘린더·duration 닫음.
        dateExpansion = .none
        durationExpanded = false

        switch newKind {
        case .todo:
            return  // Todo 전환은 별도 처리 없음
        case .notTodo:
            if !hasStart {
                hasStart = true
                startDate = .todayCalendarAnchor
            }
            showPeriod = false
            // 신규 NTD: 시작시간 6시 + 목표시간 16시간 default. 편집 모드는 기존 값 보존.
            if !isEditing {
                startHour = Item.defaultNTDStartHour
                ntdDurationHour = Item.defaultNTDDurationHour
            } else if startHour == 0 {
                // 편집 모드 + legacy(nil → 0) 보정.
                startHour = Item.defaultNTDStartHour
            }
            // NTD는 시간 chip이 항상 보여야 하므로 dueHour를 startHour로 sync해서 hasTime=true 보장.
            if dueHour == 24 {
                dueHour = startHour
            }
        case .activity:
            // 활동: 시작일 anchor 필수. 종일 의미(0/24) 고정 — 시각 window는 Phase B 범위 밖.
            if !hasStart {
                hasStart = true
                startDate = .todayCalendarAnchor
            }
            showPeriod = false
            startHour = 0
            dueHour = 24
            ntdDurationHour = nil
        case .focus:
            // 집중: 시작일 anchor 필수. 시각 무관 (사용자가 원하는 시점에 시작).
            // 종일 의미(0/24) 고정 — 시각/알림 UI 모두 비노출.
            // target은 activityTargetValue를 분 단위로 재활용 (default 60분).
            if !hasStart {
                hasStart = true
                startDate = .todayCalendarAnchor
            }
            showPeriod = false
            startHour = 0
            dueHour = 24
            ntdDurationHour = nil
            if !isEditing, activityTarget == 0 {
                activityTarget = 60  // default 60분
            }
        case .habit:
            // 습관: 종일 의미로 startHour=0, dueHour=24 고정. 시각 UI 비노출.
            if !hasStart {
                hasStart = true
                startDate = .todayCalendarAnchor
            }
            showPeriod = false
            startHour = 0
            dueHour = 24
            ntdDurationHour = nil  // 절제 전용 — habit에선 사용 안 함
        }

        // 목표는 카테고리 사용 안 함 — 신규 진입 시 selectedCategoryID 비움.
        if !isEditing, newKind.isGoal {
            selectedCategoryID = nil
        }

        // 신규 + 사용자가 picker에서 직접 안 골랐을 때 — type 변경할 때마다 type 대표 아이콘으로 자동 갱신.
        // 편집 모드는 항상 보존. 사용자가 grid에서 명시 선택한 경우도 보존 (type 바꿔도 유지).
        if !isEditing, !userPickedGoalIcon, let def = newKind.defaultGoalIcon {
            goalIcon = def
        }
    }

    /// 카테고리의 알림 default를 현재 UI state에 적용 (Todo 전용 — 목표는 카테고리 미사용).
    /// - Todo + hasTime=true: todoStart ← defaultTodoTimedStart, todoDue(period) ← defaultTodoTimedDue
    /// - Todo + hasTime=false: todoStart ← defaultTodoUntimedStart, todoDue(period) ← defaultTodoUntimedDue
    /// 호출 시점: 신규 항목 작성 중 (.task initial / .onChange of category / hasTime 토글).
    /// 편집 모드(isEditing)에서는 호출 안 함 — 사용자가 설정한 알림 보존.
    private func applyCategoryAlertDefaults(_ cat: Category) {
        if hasTime {
            todoStartAlertOffset = cat.defaultTodoTimedStartAlertInt
            if showPeriod {
                todoDueAlertOffset = cat.defaultTodoTimedDueAlertInt
            }
        } else {
            todoStartAlertOffset = cat.defaultTodoUntimedStartAlertInt
            if showPeriod {
                todoDueAlertOffset = cat.defaultTodoUntimedDueAlertInt
            }
        }
    }

    /// 시간 설정(hasTime) / 기간(showPeriod) 토글 시 알림 default 재적용.
    /// 옵션 세트(withTime/noTime)가 달라져 기존 offset 값이 호환 안 되므로 reset 필요.
    /// 카테고리 선택돼 있으면 그 카테고리의 새 context용 default로 채움 — 사용자가 명시 설정 안 했어도
    /// 카테고리 의도가 유지됨. 카테고리 없으면 nil로 reset (기존 동작).
    /// 편집 모드면 reset만 (카테고리 default 적용 안 함 — 사용자 알림 보존 원칙).
    private func reapplyTodoAlertDefaults() {
        if !isEditing,
           let id = selectedCategoryID,
           let cat = categories.first(where: { $0.id == id }) {
            applyCategoryAlertDefaults(cat)
        } else {
            todoStartAlertOffset = nil
            todoDueAlertOffset = nil
        }
    }

    private func durationLabel(_ hours: Int) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("ntd.duration_format", comment: ""),
            hours
        )
    }

    /// 목표 유지 시간 인라인 picker — 단일 row, 1~24시간.
    /// 1시간 단위, 최대 24시간 (목표 스트릭 단위 cap). 24시간 초과 legacy 데이터는 24로 clamp 표시.
    /// nil(legacy 미설정) 데이터는 row 펼침 시점에 16으로 commit됨 — 여기 binding은 항상 1~24 보장.
    @ViewBuilder
    private var inlineDurationEditor: some View {
        Picker(selection: ntdDurationBinding) {
            ForEach(1...24, id: \.self) { h in
                Text(verbatim: ntdHourLabel(h)).tag(h)
            }
        } label: { EmptyView() }
            .pickerStyle(.wheel)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }

    /// 단일 wheel binding (Int 1~24).
    /// - get: state nil이면 default 16, 그 외 1~24 clamp.
    /// - set: 항상 1~24 값 저장.
    private var ntdDurationBinding: Binding<Int> {
        Binding(
            get: {
                guard let total = ntdDurationHour else { return Item.defaultNTDDurationHour }
                return min(max(total, 1), 24)
            },
            set: { newValue in
                ntdDurationHour = newValue
            }
        )
    }

    private func ntdHourLabel(_ h: Int) -> String {
        String.localizedStringWithFormat(
            NSLocalizedString("ntd.duration_format", comment: ""),
            h
        )
    }

    private var startHourDisplayText: String {
        let h = startHour
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("j")  // 시스템 hour cycle 선호 따름
        var comps = DateComponents()
        comps.hour = h
        comps.minute = 0
        if let date = Calendar.current.date(from: comps) {
            return formatter.string(from: date)
        }
        // fallback (실패 시 단순 "n시" 형태)
        return String.localizedStringWithFormat(
            NSLocalizedString("ntd.start_hour_format", comment: ""),
            h
        )
    }

    /// Duration row 우측 chip 텍스트. 항상 "n시간" (1~24).
    /// legacy nil 데이터는 display 단계에서 16시간으로 보여줌 (실제 commit은 chip tap 시).
    private var durationDisplayText: String {
        let total = ntdDurationHour ?? Item.defaultNTDDurationHour
        let clamped = min(max(total, 1), 24)
        return String.localizedStringWithFormat(
            NSLocalizedString("ntd.duration_format", comment: ""), clamped
        )
    }

    /// 목표 유지 시간 chip — timeSubchip과 동일 스타일.
    /// expanded면 accent 배경, 평소엔 secondarySystemFill.
    private var durationChip: some View {
        Button {
            withAnimation {
                durationExpanded.toggle()
                if durationExpanded {
                    dateExpansion = .none
                    // 미설정 옵션 제거 — 펼침 시 nil(legacy)이면 16으로 commit.
                    if ntdDurationHour == nil {
                        ntdDurationHour = Item.defaultNTDDurationHour
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "hourglass")
                    .foregroundStyle(durationExpanded ? Color.accentColor : Color.primary)
                Text(verbatim: durationDisplayText)
            }
            .font(.subheadline)
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(
                    durationExpanded ? Color.accentColor.opacity(0.15) : Color(.secondarySystemFill)
                )
            )
        }
        .buttonStyle(.plain)
    }

    private func quickChip(_ titleKey: LocalizedStringKey, daysFromToday days: Int?) -> some View {
        let active = isQuickChipActive(daysFromToday: days)
        return Button {
            applyQuickDate(daysFromToday: days)
        } label: {
            Text(titleKey)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(active ? Color.accentColor : Color.clear)
                )
                .overlay(
                    Capsule().stroke(active ? Color.clear : Color.accentColor, lineWidth: 1)
                )
                .foregroundStyle(active ? Color.white : Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    private func isQuickChipActive(daysFromToday days: Int?) -> Bool {
        guard let days else {
            return !showPeriod && !hasStart && !hasDue
        }
        guard !showPeriod, hasStart, hasDue else { return false }
        // 오늘 기준 UTC anchor에서 days만큼 더해 chip이 가리키는 calendar date 계산.
        guard let target = Calendar.gmt.date(byAdding: .day, value: days, to: .todayCalendarAnchor) else {
            return false
        }
        return Calendar.gmt.isDate(startDate, inSameDayAs: target)
            && Calendar.gmt.isDate(dueDate, inSameDayAs: target)
    }

    private func applyQuickDate(daysFromToday days: Int?) {
        // 미정 chip(days=nil): 날짜 제거 + 캘린더 닫음 (날짜가 없으니 캘린더 의미 X).
        // 오늘/내일 chip: 날짜만 변경, 캘린더 펼침/닫힘 상태 그대로 유지.
        // 시각은 state에 유지 — 사용자가 chip 토글해도 이전 시각 보존.
        guard let days else {
            dateExpansion = .none
            hasStart = false
            hasDue = false
            showPeriod = false
            return
        }
        guard let target = Calendar.gmt.date(byAdding: .day, value: days, to: .todayCalendarAnchor) else {
            return
        }
        hasStart = true
        startDate = target
        hasDue = true
        dueDate = target
        showPeriod = false
    }

    private func ensureStartDateForRecurrence() {
        guard recurrenceConfig != nil, !hasStart else { return }
        hasStart = true
        startDate = .todayCalendarAnchor
        if !showPeriod {
            dueDate = startDate
            hasDue = true
        }
    }

    private func formatMonthDay(_ day: Int) -> String {
        let lang = Locale.preferredLanguages.first ?? ""
        let valueStr: String
        if lang.hasPrefix("en") {
            let formatter = NumberFormatter()
            formatter.numberStyle = .ordinal
            formatter.locale = Locale.current
            valueStr = formatter.string(from: NSNumber(value: day)) ?? "\(day)"
        } else {
            valueStr = "\(day)"
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("recurrence.day_format", comment: ""),
            valueStr
        )
    }

    private var recurrenceSummaryText: String {
        guard let config = recurrenceConfig else {
            return String(localized: "recurrence.empty")
        }
        let interval = max(config.interval, 1)
        switch config.frequency {
        case .daily:
            if interval <= 1 {
                return String(localized: "recurrence.summary.everyday")
            }
            return String.localizedStringWithFormat(
                NSLocalizedString("recurrence.summary.every_n_days", comment: ""),
                interval
            )

        case .weekly:
            let weekdays = config.weekdays.sorted()
            if weekdays.isEmpty {
                return String(localized: "recurrence.summary.weekly_unset")
            }
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            let symbols = formatter.shortWeekdaySymbols ?? []
            let names = weekdays.compactMap { idx -> String? in
                guard idx >= 1, idx <= symbols.count else { return nil }
                return symbols[idx - 1]
            }
            let daysStr = names.joined(separator: " · ")
            if interval <= 1 {
                return String.localizedStringWithFormat(
                    NSLocalizedString("recurrence.summary.weekly_list", comment: ""),
                    daysStr
                )
            }
            return String.localizedStringWithFormat(
                NSLocalizedString("recurrence.summary.weekly_list_interval", comment: ""),
                daysStr, interval
            )

        case .monthly:
            // 조건지정 우선 — weekdayMask는 config.weekdays 첫번째 비트로 변환.
            if let ordinal = config.weekdayOrdinal {
                let weekdayMask: Int16 = {
                    var m: Int16 = 0
                    for w in config.weekdays { m |= Int16(1) << (w - 1) }
                    return m
                }()
                let conditionText = RecurrenceRule.formatConditionSummary(
                    ordinal: ordinal, weekdayMask: weekdayMask)
                if interval <= 1 {
                    return String.localizedStringWithFormat(
                        NSLocalizedString("recurrence.summary.monthly_all", comment: ""),
                        conditionText)
                }
                return String.localizedStringWithFormat(
                    NSLocalizedString("recurrence.summary.monthly_all_interval", comment: ""),
                    conditionText, interval)
            }
            let days = config.days.sorted()
            let hasLast = config.includesLastDay
            let totalCount = days.count + (hasLast ? 1 : 0)
            if totalCount == 0 {
                return String(localized: "recurrence.summary.monthly_unset")
            }
            let isList = totalCount <= 3
            let dayString: String = {
                guard isList else { return "" }
                var parts = days.map { formatMonthDay($0) }
                if hasLast {
                    parts.append(String(localized: "recurrence.last_day_short"))
                }
                return parts.joined(separator: " · ")
            }()
            if interval <= 1 {
                return isList
                    ? String.localizedStringWithFormat(
                        NSLocalizedString("recurrence.summary.monthly_all", comment: ""),
                        dayString)
                    : String.localizedStringWithFormat(
                        NSLocalizedString("recurrence.summary.monthly_all_count", comment: ""),
                        totalCount)
            }
            return isList
                ? String.localizedStringWithFormat(
                    NSLocalizedString("recurrence.summary.monthly_all_interval", comment: ""),
                    dayString, interval)
                : String.localizedStringWithFormat(
                    NSLocalizedString("recurrence.summary.monthly_all_count_interval", comment: ""),
                    totalCount, interval)

        case .yearly:
            let days = config.days.sorted()
            let hasLast = config.includesLastDay
            let totalDayCount = days.count + (hasLast ? 1 : 0)
            let dayString: String = {
                if totalDayCount == 0 || totalDayCount > 3 { return "" }
                var parts = days.map { formatMonthDay($0) }
                if hasLast {
                    parts.append(String(localized: "recurrence.last_day_short"))
                }
                return parts.joined(separator: " · ")
            }()
            let months = config.months
            let monthFormatter = DateFormatter()
            monthFormatter.locale = Locale.current
            let monthSymbols = monthFormatter.shortMonthSymbols ?? []
            let monthNames = months.sorted().compactMap { idx -> String? in
                guard idx >= 1, idx <= monthSymbols.count else { return nil }
                return monthSymbols[idx - 1]
            }
            let monthStr = monthNames.joined(separator: " · ")
            if dayString.isEmpty {
                if interval <= 1 {
                    return String.localizedStringWithFormat(
                        NSLocalizedString("recurrence.summary.yearly_months_only", comment: ""),
                        monthStr)
                }
                return String.localizedStringWithFormat(
                    NSLocalizedString("recurrence.summary.yearly_months_only_interval", comment: ""),
                    monthStr, interval)
            }
            if interval <= 1 {
                return String.localizedStringWithFormat(
                    NSLocalizedString("recurrence.summary.yearly_specific", comment: ""),
                    dayString, monthStr)
            }
            return String.localizedStringWithFormat(
                NSLocalizedString("recurrence.summary.yearly_specific_interval", comment: ""),
                dayString, monthStr, interval)

        default:
            return String(localized: "recurrence.empty")
        }
    }

    /// 카테고리 picker row — sheet 기반 (Menu 대신). 옵션 styling 완전 제어 가능.
    @ViewBuilder
    private var categoryPickerRow: some View {
        Button {
            showCategoryPicker = true
        } label: {
            HStack {
                Text("add.field.category")
                    .foregroundStyle(.primary)
                Spacer()
                categoryPreview
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showCategoryPicker) {
            CategoryPickerSheet(
                selectedID: $selectedCategoryID,
                categories: Array(categories)
            )
        }
    }

    /// 선택 카테고리 미니 미리보기 — filled circle icon + name. 미선택 시 "없음" 텍스트.
    @ViewBuilder
    private var categoryPreview: some View {
        if let id = selectedCategoryID,
           let cat = categories.first(where: { $0.id == id }) {
            HStack(spacing: 6) {
                Image(systemName: cat.iconName ?? CategoryIcon.defaultIcon.symbolName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Self.categoryColor(for: cat)))
                Text(verbatim: cat.name ?? "")
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("category.none")
                .foregroundStyle(.secondary)
        }
    }

    /// Category.colorHex(CategoryColor rawValue) → Color. 미설정 시 secondary.
    static func categoryColor(for cat: Category) -> Color {
        guard let raw = cat.colorHex, let cc = CategoryColor(rawValue: raw) else {
            return .secondary
        }
        return cc.color
    }

    private func priorityButton(_ p: Priority) -> some View {
        let selected = priority == p
        return Button {
            priority = p
        } label: {
            Image(systemName: p == .none ? "flag.slash" : "flag.fill")
                .font(.title3)
                .foregroundStyle(Self.flagColor(for: p))
                .frame(width: 40, height: 40)
                .background(
                    Circle().fill(selected ? Color(.secondarySystemFill) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    static func flagColor(for priority: Priority) -> Color {
        switch priority {
        case .high:   return .red
        case .medium: return .yellow
        case .low:    return .blue
        case .none:   return .secondary
        }
    }

    // MARK: - 활동 source / unit

    /// Source 선택 chip — quickChip(날짜 chip)과 동일 시각 패턴(active=fill, inactive=stroke).
    /// 탭 → activitySource 변경. 권한 요청은 저장 시점 (attemptSave)에 한 번.
    /// locked=true (편집 모드): 탭 무효 + 회색 톤으로 "변경 불가" 시각화.
    private func sourceChip(
        _ source: ActivitySourceType,
        titleKey: LocalizedStringKey,
        locked: Bool = false
    ) -> some View {
        let active = activitySource == source
        // locked(편집 모드 변경 불가)도 시각은 active와 동일 accent fill — 회색 톤은 식별 어려워서 사용자 의견 반영.
        // 탭 무효는 .disabled로 행동만 차단.
        let fillColor: Color = (active || locked) ? Color.accentColor : Color.clear
        let strokeColor: Color = (active || locked) ? .clear : Color.accentColor
        let textColor: Color = (active || locked) ? Color.white : Color.accentColor
        return Button {
            guard !locked else { return }
            activitySource = source
        } label: {
            Text(titleKey)
                .font(.system(size: 14))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Capsule().fill(fillColor))
                .overlay(Capsule().stroke(strokeColor, lineWidth: 1))
                .foregroundStyle(textColor)
        }
        .buttonStyle(.plain)
        // .disabled는 chip 전체를 dim 처리해 white 텍스트가 회색처럼 보임 → allowsHitTesting으로 탭만 차단.
        .allowsHitTesting(!locked)
    }

    /// ActivitySourceType → 로컬 키. sourceChip 호출 편의용.
    private func activitySourceTitleKey(_ source: ActivitySourceType) -> LocalizedStringKey {
        switch source {
        case .manual:   return "activity_source.manual"
        case .steps:    return "activity_source.steps"
        case .distance: return "activity_source.distance"
        case .calories: return "activity_source.calories"
        case .flights:  return "activity_source.flights"
        }
    }

    /// Auto source 선택 시 — 권한이 거부됐을 수 있다는 inline 안내 + 설정 앱 deep link.
    /// iOS HealthKit read 권한은 status 조회 불가 (privacy) + 같은 type 재-prompt 불가.
    /// 사용자가 자동 측정 안 됨을 발견하면 설정에서 직접 켜야 함.
    /// 안내 문구 + 설정 링크를 한 줄에 — localized string에 Markdown link 임베드.
    /// link tap → openURL("app-settings:") → iOS가 설정 앱 열음.
    @ViewBuilder
    private var autoSourcePermissionHint: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("activity.source.auto.permission_hint")
                .font(.caption)
                .foregroundStyle(.secondary)
                .tint(Color.accentColor)
                // markdown link 탭 → 건강 앱으로 바로 이동하지 않고 안내 alert 띄움.
                // 사용자가 건강 앱 안에서 MyDays까지 navigate하는 경로 명시 (deep link 불가).
                .environment(\.openURL, OpenURLAction { url in
                    if url.scheme == "x-apple-health" {
                        showHealthAppPathAlert = true
                        return .handled
                    }
                    return .systemAction
                })
        }
    }

    /// Manual source 선택 시 — 자동 측정 불가 항목 안내 (단순 hint).
    @ViewBuilder
    private var manualSourceHint: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("activity.source.manual.hint")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 현재 source의 단위 hint — TextField 우측에 표시.
    /// focus는 활동 소스와 무관하게 항상 "분" 표시.
    /// activity manual은 nil (자유 단위), auto source는 각자 단위.
    private var activityUnitHint: String? {
        if isFocus { return String(localized: "activity.unit.minutes") }
        switch activitySource {
        case .manual:   return nil
        case .steps:    return String(localized: "activity.unit.steps")
        case .distance: return String(localized: "activity.unit.meter")
        case .calories: return String(localized: "activity.unit.calories")
        case .flights:  return String(localized: "activity.unit.flights")
        }
    }

    // MARK: - 활동 quick add chip row

    /// 활동 목표 수치 quick add — TextField 아래 chip 행. +1/+10/+100/+1000/초기화.
    /// 큰 수치(20000 등) 입력 + 작은 수치(squat 100회) 모두 키보드 부담 없이.
    @ViewBuilder
    private var activityQuickAddRow: some View {
        HStack(spacing: 8) {
            activityAddChip("+1") {
                activityTargetFocused = false
                activityTarget += 1
            }
            activityAddChip("+10") {
                activityTargetFocused = false
                activityTarget += 10
            }
            activityAddChip("+100") {
                activityTargetFocused = false
                activityTarget += 100
            }
            activityAddChip("+1000") {
                activityTargetFocused = false
                activityTarget += 1000
            }
            Spacer()
            activityResetChip {
                activityTargetFocused = false
                activityTarget = 0
            }
        }
        .padding(.vertical, 2)
    }

    private func activityAddChip(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: label)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }

    private func activityResetChip(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("add.activity.reset")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color(.secondarySystemFill)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 목표 type 선택 (4 chip + 설명)

    /// chip 순서: 절제 → 활동 → 집중 → 습관.
    static let goalSubKindOrder: [ItemKind] = [.notTodo, .activity, .focus, .habit]

    /// 목표 유형 row — 4 chip 가로 + 선택한 type의 이름 + 설명.
    /// chip 자체엔 이름 표시 안 함. 활동/집중은 작은 "(준비중)" 라벨로 status 표시.
    @ViewBuilder
    private var goalTypeRow: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ForEach(Self.goalSubKindOrder, id: \.self) { type in
                    goalTypeChip(type)
                }
            }
            .frame(maxWidth: .infinity)
            // 선택한 유형의 이름 + 설명.
            VStack(alignment: .leading, spacing: 4) {
                Text(kind.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(goalKindDescription(for: kind))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    /// 개별 chip — filled circle + icon. 이름 미표시.
    /// 선택: accent fill. 미선택: gray fill. 비활성(활동/집중)은 gray + 아래 "(준비중)" 라벨 + 탭 X.
    @ViewBuilder
    private func goalTypeChip(_ type: ItemKind) -> some View {
        let selected = (kind == type)
        let available = type.isAvailableForInput
        Button {
            guard available else { return }
            kind = type
            handleKindChange(type)
        } label: {
            ZStack {
                Circle()
                    .fill(selected ? Color.accentColor : Color(.systemGray3))
                    .frame(width: 48, height: 48)
                Image(systemName: type.goalTypeSymbolName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
    }

    /// 각 type의 설명 텍스트 — chip row 아래에 표시.
    private func goalKindDescription(for type: ItemKind) -> LocalizedStringKey {
        switch type {
        case .notTodo:  return "kind.desc.not_todo"
        case .activity: return "kind.desc.activity"
        case .focus:    return "kind.desc.focus"
        case .habit:    return "kind.desc.habit"
        case .todo:     return ""
        }
    }

    // MARK: - 목표 아이콘·색 picker (CategoryEditSheet 패턴 재활용)

    /// 색상 grid — 8열 LazyVGrid. CategoryColor 8색 그대로 재활용.
    @ViewBuilder
    private var goalColorGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8),
            spacing: 8
        ) {
            ForEach(CategoryColor.allCases) { cc in
                goalColorChip(cc)
            }
        }
        .padding(.vertical, 4)
    }

    /// 아이콘 grid — 6열 LazyVGrid, GoalIcon 24개 (4행).
    /// 1행: type 대표(절제/활동/집중/습관) → 2~3행: 절제·운동 → 3~4행: 활동·개인.
    @ViewBuilder
    private var goalIconGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6),
            spacing: 8
        ) {
            ForEach(GoalIcon.allCases) { icon in
                goalIconChip(icon)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func goalColorChip(_ cc: CategoryColor) -> some View {
        let selected = goalColor == cc
        Button {
            goalColor = cc
        } label: {
            Circle()
                .fill(cc.color)
                .frame(width: 30, height: 30)
                .overlay {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .accessibilityLabel(Text(cc.labelKey))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func goalIconChip(_ icon: GoalIcon) -> some View {
        let selected = goalIcon == icon
        // 선택된 색상으로 활성 chip background. 색 미선택 시 accent fallback.
        let color = goalColor?.color ?? .accentColor
        Button {
            goalIcon = icon
            // 사용자 명시 선택 — 이후 type 변경에도 자동 갱신 안 됨.
            userPickedGoalIcon = true
        } label: {
            Image(systemName: icon.symbolName)
                .font(.body)
                .frame(width: 36, height: 36)
                .background(Circle().fill(selected ? color : Color(.systemGray5)))
                .overlay {
                    if !selected {
                        Circle().stroke(Color(.systemGray3), lineWidth: 0.5)
                    }
                }
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private var periodChip: some View {
        Button {
            // exclusive 동작 — 이미 활성이면 no-op (오늘/내일/미정 chip으로만 해제).
            guard !showPeriod else { return }
            showPeriod = true
            if !hasStart {
                hasStart = true
                startDate = .todayCalendarAnchor
            }
            // 기간 모드는 다른 두 일자 의미 — start+1로 default 채움 (이미 hasDue=true여도 덮어쓰기).
            hasDue = true
            dueDate = Self.defaultDueDate(after: startDate)
            // 기간 ON으로 마감 알림 picker가 노출 → 카테고리 default를 마감 anchor에만 적용
            // (시작 알림은 이미 단일 모드에서 사용자가 본 값 그대로 보존).
            if !isEditing,
               let id = selectedCategoryID,
               let cat = categories.first(where: { $0.id == id }) {
                todoDueAlertOffset = hasTime
                    ? cat.defaultTodoTimedDueAlertInt
                    : cat.defaultTodoUntimedDueAlertInt
            }
            // dateExpansion 유지 — chip 클릭은 캘린더 토글하지 않음.
        } label: {
            Text("add.chip.period")
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(showPeriod ? Color.accentColor : Color.clear)
                )
                .overlay(
                    Capsule().stroke(showPeriod ? Color.clear : Color.accentColor, lineWidth: 1)
                )
                .foregroundStyle(showPeriod ? Color.white : Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    /// "시간설정" 독립 toggle chip — `dueHour < 24` 여부로 derived state.
    /// OFF 전환 → `dueHour = 24` (sentinel). ON 전환 → `dueHour = startHour` (단일 모드 default).
    /// ON 후 사용자가 wheel로 dueHour 변경하면 그 값 유지.
    private var hasTimeChip: some View {
        Button {
            withAnimation {
                if hasTime {
                    // 현재 ON → OFF로 전환. dueHour를 sentinel 24로.
                    dueHour = 24
                    if dateExpansion == .startTime || dateExpansion == .dueTime {
                        dateExpansion = .none
                    }
                } else {
                    // 현재 OFF → ON으로 전환. dueHour를 startHour로 sync (사용자가 wheel로 재설정 가능).
                    dueHour = startHour
                }
                // hasTime 전환 시 알림 default 재적용 — 옵션 세트(withTime/noTime) 호환 안 됨.
                // 카테고리 선택돼 있으면 그 default 사용, 없으면 nil reset (사용자가 명시 설정한 게 아니라면
                // 카테고리 의도가 유지되어야 함).
                reapplyTodoAlertDefaults()
            }
        } label: {
            Text("add.chip.has_time")
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(hasTime ? Color.accentColor : Color.clear)
                )
                .overlay(
                    Capsule().stroke(hasTime ? Color.clear : Color.accentColor, lineWidth: 1)
                )
                .foregroundStyle(hasTime ? Color.white : Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    /// 인라인 캘린더 영역 toggle. 같은 chip 다시 누르면 닫힘.
    /// 다른 영역(목표 시간 wheel 등) 펼쳐져 있으면 함께 접음 — 동시 펼침 방지.
    private func toggleDateExpansion(_ target: DateExpansion) {
        withAnimation {
            dateExpansion = (dateExpansion == target) ? .none : target
            if dateExpansion != .none { durationExpanded = false }
        }
    }

    /// 인라인 캘린더 — DatePicker만. "날짜 없음" 버튼은 chip 'no_date'(미정)와 중복이라 제거.
    /// 시각 입력은 별도 timeSubchip → inlineTimeEditor로 분리됨.
    /// 마감(.due)은 시작일자 이전 선택 못하게 DatePicker range 제한.
    @ViewBuilder
    private func inlineCalendarEditor(for field: DateField) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if field == .due && showPeriod {
                DatePicker(
                    "",
                    selection: dateBinding(for: field),
                    in: startDate.localCalendarSameDay...,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                .environment(\.locale, Locale.current)
            } else {
                DatePicker(
                    "",
                    selection: dateBinding(for: field),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                .environment(\.locale, Locale.current)
            }
        }
        .padding(.vertical, 4)
    }

    /// 인라인 시각 wheel — 시 단위.
    /// wheel은 0~23 단일 옵션. "시간 미설정"은 chip toggle로만 (wheel에서 분리).
    /// 마감(.due) 시각은 같은 날짜일 때 시작 시각 이후만 노출 (validation).
    @ViewBuilder
    private func inlineTimeEditor(for field: DateField) -> some View {
        HStack {
            Spacer()
            Picker(selection: hourBinding(for: field)) {
                ForEach(validHours(for: field), id: \.self) { h in
                    Text(verbatim: todoHourLabel(h)).tag(h)
                }
            } label: { EmptyView() }
            .pickerStyle(.wheel)
            .labelsHidden()
            .frame(maxWidth: 240)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    /// 시각 wheel에 노출할 유효 시간 목록.
    /// - 시작(.start): 0~23 항상 자유 (마감 invalidate는 setter 측에서 정리).
    /// - 마감(.due): 같은 날짜·기간 모드면 시작+1 이후만. 다른 날짜면 0~23.
    /// 단, 현재 dueHour가 filter 밖(legacy 데이터)이라도 wheel에 포함 — wheel selection 매칭 보장.
    private func validHours(for field: DateField) -> [Int] {
        guard field == .due, showPeriod,
              Calendar.gmt.isDate(startDate, inSameDayAs: dueDate)
        else { return Array(0..<24) }
        var hours = Array((startHour + 1)..<24)
        if !hours.contains(dueHour) && dueHour < 24 {
            hours.append(dueHour)
            hours.sort()
        }
        return hours
    }

    /// 반복 종료일 row 우측 표시. 미설정이면 "무기한".
    private var recurrenceEndDisplayText: String {
        guard let date = recurrenceEndDate else {
            return String(localized: "recurrence_end.unset")
        }
        return formattedDateShort(date)
    }

    /// 반복 종료일 인라인 캘린더 + "무기한" 버튼.
    @ViewBuilder
    private var inlineRecurrenceEndEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            DatePicker(
                "",
                selection: recurrenceEndBinding,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .environment(\.locale, Locale.current)

            HStack {
                Spacer()
                if recurrenceEndDate != nil {
                    Button(role: .destructive) {
                        recurrenceEndDate = nil
                        withAnimation { dateExpansion = .none }
                    } label: {
                        Text("recurrence_end.unset")
                            .font(.subheadline)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// 반복 종료일 binding — UTC anchor ↔ local. nil이면 오늘로 시작.
    private var recurrenceEndBinding: Binding<Date> {
        Binding(
            get: { (recurrenceEndDate ?? .todayCalendarAnchor).localCalendarSameDay },
            set: { recurrenceEndDate = $0.calendarDateAnchor }
        )
    }

    /// Todo 시각 라벨 (시스템 12h/24h 자동).
    private func todoHourLabel(_ h: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("j")
        var comps = DateComponents()
        comps.hour = h
        comps.minute = 0
        if let date = Calendar.current.date(from: comps) {
            return formatter.string(from: date)
        }
        return "\(h)"
    }

    private func hourBinding(for field: DateField) -> Binding<Int> {
        Binding(
            get: {
                switch field {
                case .start: return startHour
                case .due:   return dueHour
                }
            },
            set: { newValue in
                switch field {
                case .start:
                    startHour = newValue
                    // 단일 모드: dueHour를 startHour와 sync (한 시간만 의미).
                    if !showPeriod { dueHour = newValue }
                    // 기간 모드 + 같은 날 + due가 새 start 이하면 due를 start+1로 보정.
                    if showPeriod, hasDue,
                       Calendar.gmt.isDate(startDate, inSameDayAs: dueDate),
                       dueHour <= newValue {
                        dueHour = min(newValue + 1, 23)
                    }
                case .due:
                    dueHour = newValue
                }
            }
        )
    }

    /// UTC anchor ↔ local Date 변환 binding.
    /// - get: state(UTC anchor) → local 같은 (y,m,d) 자정 instant (DatePicker 표시용)
    /// - set: DatePicker 결과(local 자정) → UTC anchor로 정규화해 state 저장 + hasStart/hasDue 자동 ON
    /// 단일 chip 모드에선 start 변경 시 due도 같이 따라옴.
    /// 기간 모드 + start 변경 시 due가 start 이전이면 due를 start로 sync (validation).
    private func dateBinding(for field: DateField) -> Binding<Date> {
        Binding(
            get: {
                switch field {
                case .start: return startDate.localCalendarSameDay
                case .due:   return dueDate.localCalendarSameDay
                }
            },
            set: { newValue in
                let anchor = newValue.calendarDateAnchor
                switch field {
                case .start:
                    startDate = anchor
                    hasStart = true
                    if !showPeriod {
                        dueDate = anchor
                        hasDue = true
                    } else if hasDue, dueDate < anchor {
                        // 기간 모드: 새 start가 due보다 미래 → due를 sync.
                        // dueHour가 startHour 이하로 invalid면 start+1로 보정 (sentinel 24면 그대로).
                        dueDate = anchor
                        if dueHour < 24, dueHour <= startHour {
                            dueHour = min(startHour + 1, 23)
                        }
                    } else if hasDue,
                              Calendar.gmt.isDate(anchor, inSameDayAs: dueDate),
                              dueHour < 24, dueHour <= startHour {
                        dueHour = min(startHour + 1, 23)
                    }
                case .due:
                    dueDate = anchor
                    hasDue = true
                }
            }
        )
    }

    /// 날짜 subchip — 📅 + 날짜 텍스트(active) 또는 "날짜 없음"(inactive).
    /// 캡슐 배경으로 chip 형태 강조. expanded면 accent tint 배경.
    private func dateSubchip(active: Bool, expanded: Bool, date: Date, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                    .foregroundStyle(
                        expanded ? Color.accentColor
                                 : (active ? Color.primary : Color.secondary)
                    )
                if active {
                    Text(verbatim: formattedDateShort(date))
                } else {
                    Text("common.no_date")
                }
            }
            .font(.subheadline)
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(
                    expanded ? Color.accentColor.opacity(0.15) : Color(.secondarySystemFill)
                )
            )
        }
        .buttonStyle(.plain)
    }

    /// 시각 subchip — ⏰ + 시각 텍스트. hasTime ON일 때만 렌더되므로 hour는 항상 0~23.
    /// 캡슐 배경으로 chip 형태 강조.
    private func timeSubchip(hour: Int, expanded: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .foregroundStyle(expanded ? Color.accentColor : Color.primary)
                Text(verbatim: todoHourLabel(hour))
            }
            .font(.subheadline)
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(
                    expanded ? Color.accentColor.opacity(0.15) : Color(.secondarySystemFill)
                )
            )
        }
        .buttonStyle(.plain)
    }

    private func formattedDateShort(_ date: Date) -> String {
        // date는 UTC anchor. timezone=.gmt로 고정한 formatter로 해석해야
        // local timezone에 따라 라벨이 흔들리지 않음.
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let dateYear = Calendar.gmt.component(.year, from: date)
        let currentYear = Calendar.gmt.component(.year, from: .todayCalendarAnchor)
        formatter.setLocalizedDateFormatFromTemplate(dateYear == currentYear ? "MdE" : "yMdE")
        return formatter.string(from: date)
    }

    private static func defaultDueDate(after base: Date?) -> Date {
        // base가 nil이면 오늘, 있으면 그 다음 날을 default due로.
        // 모두 UTC anchor 기준.
        let anchor = base.map { Calendar.gmt.startOfDay(for: $0) } ?? .todayCalendarAnchor
        return Calendar.gmt.date(byAdding: .day, value: 1, to: anchor) ?? anchor
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let isNew = editingItem == nil
        let item: Item
        if let existing = editingItem {
            item = existing
        } else {
            // make은 default priority로 시작 — 아래에서 kind에 따라 다시 정리.
            item = Item.make(in: context, kind: kind, title: trimmed, priority: priority)
        }
        // 활성화 트리거 판단용 snapshot — 1회성 NTD가 failed/done 상태에서
        // 시각 정보 변경 시 자동 재활성화하기 위함.
        let wasRecurring = (editingItem?.recurrenceRule != nil)
        let priorStatus = editingItem?.itemStatus
        let priorStartDate = editingItem?.startDate
        let priorStartHour = editingItem?.startHourInt
        let priorDurationHour = editingItem?.ntdDurationHourInt
        item.title = trimmed
        item.notes = notes.isEmpty ? nil : notes
        item.itemKind = kind
        item.startDate = hasStart ? startDate : nil
        item.dueDate = hasDue ? dueDate : nil
        item.isSomeday = !hasStart && !hasDue
        item.recurrenceEndDate = recurrenceEndDate
        // 카테고리 + 목표 아이콘/색 — kind에 따라 분기.
        // 목표: category nil + iconName/iconColorHex 사용자 선택값.
        // Todo: iconName/iconColorHex nil + category 선택값 (또는 미분류).
        if isGoal {
            item.category = nil
            item.iconName = goalIcon?.rawValue       // semantic rawValue 저장 (Android 호환)
            item.iconColorHex = goalColor?.rawValue  // CategoryColor rawValue 저장
        } else {
            if let id = selectedCategoryID,
               let cat = categories.first(where: { $0.id == id }) {
                item.category = cat
            } else {
                item.category = nil
            }
            item.iconName = nil
            item.iconColorHex = nil
        }
        item.updatedAt = Date()

        switch kind {
        case .notTodo:
            // NTD: startHour 필수 anchor. dueHour는 NTD에서 미사용이지만,
            // hasTime(dueHour<24) 판정이 NTD에서도 true가 되도록 startHour와 sync.
            item.startHourInt = startHour
            item.dueHourInt = startHour
            item.ntdDurationHourInt = ntdDurationHour
            item.itemPriority = .none
            item.itemStartTimeOfDay = .none
            item.itemDueTimeOfDay = .none
            if item.startDate == nil {
                item.startDate = .todayCalendarAnchor
                item.isSomeday = false
            }
        case .habit:
            // 습관: 종일 의미 — startHour=0, dueHour=24 고정. NTD duration 사용 X.
            // 우선순위 사용 X (목표 정체성).
            item.startHourInt = 0
            item.dueHourInt = 24
            item.ntdDurationHourInt = nil
            item.itemPriority = .none
            item.itemStartTimeOfDay = .none
            item.itemDueTimeOfDay = .none
            if item.startDate == nil {
                item.startDate = .todayCalendarAnchor
                item.isSomeday = false
            }
        case .activity:
            // 활동: 종일 의미(0/24) + target value 저장. 우선순위 없음.
            item.startHourInt = 0
            item.dueHourInt = 24
            item.ntdDurationHourInt = nil
            item.activityTargetValueInt = activityTarget
            item.activitySource = activitySource  // Phase C: 사용자 선택 source 저장
            item.notifyOnGoalReached = NSNumber(value: notifyOnGoalReached)
            item.itemPriority = .none
            item.itemStartTimeOfDay = .none
            item.itemDueTimeOfDay = .none
            if item.startDate == nil {
                item.startDate = .todayCalendarAnchor
                item.isSomeday = false
            }
        case .focus:
            // 집중: 종일 의미(0/24) + target 분 저장 (activityTargetValue 재활용).
            // source는 manual 강제 (focus는 자체 timer 시스템). 우선순위 없음.
            item.startHourInt = 0
            item.dueHourInt = 24
            item.ntdDurationHourInt = nil
            item.activityTargetValueInt = activityTarget
            item.activitySource = .manual
            item.notifyOnGoalReached = NSNumber(value: notifyOnGoalReached)
            item.itemPriority = .none
            item.itemStartTimeOfDay = .none
            item.itemDueTimeOfDay = .none
            if item.startDate == nil {
                item.startDate = .todayCalendarAnchor
                item.isSomeday = false
            }
        case .todo:
            // Todo: 시각 0~23(start), 0~24(due). 24=시간 미설정 sentinel.
            item.itemPriority = priority
            if !hasTime {
                item.startHourInt = 0
                item.dueHourInt = 24
            } else {
                item.startHourInt = startHour
                item.dueHourInt = showPeriod ? dueHour : startHour
            }
            item.itemStartTimeOfDay = .none
            item.itemDueTimeOfDay = .none
            item.ntdDurationHourInt = nil
        }

        // 반복 설정 적용.
        // NTD에서 ntdDurationHour=nil이면 반복 의미 없음 → recurrenceConfig 무시하고 제거.
        let effectiveRecurrence: RecurrenceConfig? = (isNTD && ntdDurationHour == nil) ? nil : recurrenceConfig

        if let config = effectiveRecurrence {
            // 1회성 → 반복 전환 시 종료된 status(done/failed) 재활성화.
            // 기존 RoutineCompletion 기록은 보존됨 (체크 시점에 RC가 이미 생성되어 있음 → 통합 모델).
            if !wasRecurring && (item.itemStatus == .done || item.itemStatus == .failed) {
                item.itemStatus = .pending
                item.completedAt = nil
            }
            if item.startDate == nil {
                // 루틴은 anchor가 필수 → 오늘(UTC anchor)을 startDate로.
                item.startDate = .todayCalendarAnchor
                item.isSomeday = false
            }
            // 단일 chip 모드: dueDate는 Todo 마감일이라 routine에선 안 쓰임 → nil로.
            // (routine 종료일은 별도 recurrenceEndDate 필드에 저장)
            if !showPeriod {
                item.dueDate = nil
            }
            let rule = item.recurrenceRule ?? RecurrenceRule.make(in: context)
            config.apply(to: rule)
            item.recurrenceRule = rule
        } else if let existing = item.recurrenceRule {
            context.delete(existing)
            item.recurrenceRule = nil
        }

        // 1회성 NTD failed/done 상태에서 시각 정보가 변경됐으면 자동 재활성화.
        // 사용자가 시간/날짜/duration을 바꾼 것은 "다시 시도" 의도로 해석.
        // 기존 RoutineCompletion 기록은 보존됨 (활동 로그·사유 history 유지).
        if isNTD,
           !wasRecurring,
           item.recurrenceRule == nil,
           let prior = priorStatus,
           prior == .done || prior == .failed {
            let startDateChanged = priorStartDate != item.startDate
            let startHourChanged = priorStartHour != startHour
            let durationChanged = priorDurationHour != ntdDurationHour
            if startDateChanged || startHourChanged || durationChanged {
                item.itemStatus = .pending
                item.completedAt = nil
            }
        }

        // 알림 Reminder 레코드 reconcile — UI state(offset Optional<Int>) → DB.
        reconcileReminders(item: item)

        // 체크리스트 reconcile — drafts → ChecklistItem (soft delete + 신규 생성).
        reconcileChecklist(item: item)

        ItemEvent.log(isNew ? .created : .updated, on: item, in: context)

        do {
            try context.save()
            Item.completeExpiredRoutines(in: context)
            Item.completeFinishedNTDs(in: context)
            // OS 알림 등록/갱신은 DB 저장 후. Reminder.id가 안정적이어야 OS notification id와 매칭됨.
            item.syncNotifications()
            // 활동 + auto source: 등록 직후 HK 데이터 즉시 fetch — scenePhase 갱신 대기 없이 바로 progress 반영.
            // 사용자가 "걸음수 10000 목표" 등록하자마자 캘린더·row에 오늘 누적값 보이도록.
            if kind == .activity, activitySource != .manual {
                Task { await Item.syncHealthKitActivities(in: context) }
            }
            dismiss()
        } catch {
            assertionFailure("Save failed: \(error)")
        }
    }

    /// AddItemView state의 알림 toggle/offset → Reminder 레코드 동기화.
    /// anchor별 1개 reminder 정책 (V1). 이미 있으면 offset 업데이트, 없으면 생성, 토글 OFF면 삭제.
    private func reconcileReminders(item: Item) {
        let existing = (item.reminders as? Set<Reminder>) ?? []
        // 같은 anchor에 중복 reminder가 들어와 있으면 (CloudKit 충돌 등으로 발생 가능) 1개만 유지하고 나머지는 정리.
        // 정리 안 하면 syncNotifications가 reminder마다 OS 알림을 등록해 동일 내용이 중복 fire.
        var anchorBuckets: [Int16: [Reminder]] = [:]
        for r in existing { anchorBuckets[r.anchor, default: []].append(r) }
        var byAnchor: [Int16: Reminder] = [:]
        for (anchor, group) in anchorBuckets {
            let sorted = group.sorted {
                ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "")
            }
            byAnchor[anchor] = sorted.first
            for dup in sorted.dropFirst() {
                if let rid = dup.id {
                    Item.cancelNotifications(forReminderID: rid)
                }
                context.delete(dup)
            }
        }

        // (anchor, offset) target 목록 — UI state 기반.
        var targets: [(Int16, Int)] = []
        if isNTD {
            if let o = ntdStartAlertOffset {
                targets.append((ReminderAnchor.start.rawValue, o))
            }
            if ntdDurationHour != nil, let o = ntdEndAlertOffset {
                targets.append((ReminderAnchor.due.rawValue, o))
            }
        } else if hasStart || hasDue {
            // 단일: 시작 알림만. 기간: 시작 + 마감 둘 다.
            if let o = todoStartAlertOffset {
                targets.append((ReminderAnchor.start.rawValue, o))
            }
            if showPeriod, let o = todoDueAlertOffset {
                targets.append((ReminderAnchor.due.rawValue, o))
            }
        }
        let targetAnchors = Set(targets.map { $0.0 })

        // target에 없는 anchor reminder는 삭제.
        // CD에서 제거하기 전, 해당 Reminder.id로 발급된 모든 occurrence OS 알림(prefix 매칭) 취소 →
        // syncNotifications가 reminderSet 순회 시 이미 사라진 Reminder는 못 봐서 orphan이 남는 문제 방지.
        for (anchor, reminder) in byAnchor where !targetAnchors.contains(anchor) {
            if let rid = reminder.id {
                Item.cancelNotifications(forReminderID: rid)
            }
            context.delete(reminder)
        }
        // upsert.
        let now = Date()
        for (anchor, offset) in targets {
            if let r = byAnchor[anchor] {
                r.offsetMin = Int32(offset)
                r.updatedAt = now
            } else {
                let r = Reminder(context: context)
                r.id = UUID()
                r.createdAt = now
                r.updatedAt = now
                r.anchor = anchor
                r.offsetMin = Int32(offset)
                r.item = item
            }
        }
    }

    private func deleteItem() {
        guard let item = editingItem else { return }
        // 삭제 전 OS 알림 취소 (Item이 사라지면 Reminder.id 접근 불가).
        item.cancelAllNotifications()
        ItemEvent.log(.deleted, on: item, in: context)
        context.delete(item)
        do {
            try context.save()
            dismiss()
        } catch {
            assertionFailure("Delete failed: \(error)")
        }
    }

    /// 체크리스트 drafts → Item.checklistItems 동기화.
    /// - 기존 active item 중 drafts에 없는 것 → soft delete (deletedAt 마킹). check 기록은 보존.
    /// - drafts 중 existing 매칭되는 것 → title/sortOrder 업데이트. 빈 제목은 건너뜀 (no-op).
    /// - drafts 중 매칭 없는 것 → 새 ChecklistItem 생성 (빈 제목은 skip).
    /// 사용자가 minus로 제거한 active가 다시 추가될 일은 없음 (UUID 새로 발급되니).
    private func reconcileChecklist(item: Item) {
        let now = Date()
        let existing = (item.checklistItems as? Set<ChecklistItem>) ?? []
        let draftIds = Set(checklistDrafts.map { $0.id })

        // 1. active이면서 drafts에 없는 것 → soft delete.
        for ci in existing where ci.isActive {
            guard let ciID = ci.id, !draftIds.contains(ciID) else { continue }
            ci.markDeleted()
        }

        // 2. drafts → upsert (빈 제목은 skip).
        for (idx, draft) in checklistDrafts.enumerated() {
            let trimmed = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let target: ChecklistItem
            if let ci = existing.first(where: { $0.id == draft.id }) {
                target = ci
                // 만약 이전에 soft-deleted였다가 같은 UUID로 다시 들어온 경우 복원 (실질 케이스 없지만 방어).
                if target.deletedAt != nil { target.deletedAt = nil }
            } else {
                target = ChecklistItem(context: context)
                target.id = draft.id
                target.createdAt = now
                target.item = item
            }
            if target.title != trimmed { target.title = trimmed }
            if target.sortOrder != Int32(idx) { target.sortOrder = Int32(idx) }
            target.updatedAt = now
        }
    }
}

#Preview("New") {
    AddItemView()
        .environment(\.managedObjectContext, PersistenceController.shared.viewContext)
}
