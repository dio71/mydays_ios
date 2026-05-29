import CoreData
import Foundation

// MARK: - ChecklistItem helpers
//
// 체크리스트 모델 규칙 (CLAUDE.md 참조):
// - 부모 Item에 속함. soft delete (deletedAt) — 실제 row는 보존, 표시만 hide.
// - ChecklistCheck는 occurrence별 체크 기록 (id + occurrenceDate + completedAt).
// - 표시 정책 = 합집합:
//   · active(deletedAt==nil) ChecklistItem 전부 +
//   · soft-deleted 중 그 occurrence에 check 있는 것
// - 진행 카운트는 표시 항목 기준.
//
// occurrenceDate 규약:
// - 반복: 각 occurrence start date (UTC anchor) — per-occurrence 기록
// - 1회성/Someday: `Item.nonRoutineChecklistOccurrence` sentinel — 단일 bucket
//   (startDate 변경되어도 매칭 유지. ChecklistCheck.checklistItem FK로 항목별 격리).
// - 1회성 ↔ 반복 전환 시 자동 마이그 X — 기존 bucket의 check는 DB에 보존만 됨 (다시 원상태 돌리면 자동 복원).

extension ChecklistItem {

    /// soft delete — 실제 delete 대신 deletedAt 마킹. 합집합 정책상 과거 occurrence가 참조하면 표시됨.
    func markDeleted() {
        let now = Date()
        self.deletedAt = now
        self.updatedAt = now
    }

    /// 활성(삭제 안된) 상태인지.
    var isActive: Bool { deletedAt == nil }

    /// 특정 occurrence에 이 checklist item이 체크돼 있는지.
    func isChecked(forOccurrence occurrenceDate: Date) -> Bool {
        let day = Calendar.gmt.startOfDay(for: occurrenceDate)
        let allChecks = (self.checks as? Set<ChecklistCheck>) ?? []
        return allChecks.contains { c in
            guard let d = c.occurrenceDate else { return false }
            return Calendar.gmt.isDate(d, inSameDayAs: day)
        }
    }

    /// 특정 occurrence의 ChecklistCheck 레코드 1개 (있으면). 토글 시 삭제 대상 lookup.
    func checkRecord(forOccurrence occurrenceDate: Date) -> ChecklistCheck? {
        let day = Calendar.gmt.startOfDay(for: occurrenceDate)
        let allChecks = (self.checks as? Set<ChecklistCheck>) ?? []
        return allChecks.first { c in
            guard let d = c.occurrenceDate else { return false }
            return Calendar.gmt.isDate(d, inSameDayAs: day)
        }
    }
}

// MARK: - Item 체크리스트 accessor

extension Item {

    /// non-routine(1회성/Someday) 항목용 sentinel occurrenceDate.
    /// distantPast의 UTC startOfDay — 실제 어떤 occurrence와도 절대 충돌 X.
    /// 모든 non-routine 항목이 동일 값을 공유해도 `ChecklistCheck.checklistItem` FK로 격리됨.
    static let nonRoutineChecklistOccurrence: Date = {
        Calendar.gmt.startOfDay(for: Date.distantPast)
    }()

    /// view 컨텍스트에서 사용할 occurrenceDate 결정.
    /// - 반복: occurrenceStartOverride ?? referenceDate (각 occurrence별)
    /// - 1회성/Someday: nonRoutineChecklistOccurrence sentinel
    func checklistOccurrenceDate(occurrenceStartOverride: Date? = nil,
                                 referenceDate: Date) -> Date {
        if recurrenceRule != nil {
            let day = occurrenceStartOverride ?? referenceDate
            return Calendar.gmt.startOfDay(for: day)
        }
        return Self.nonRoutineChecklistOccurrence
    }

    /// 표시할 ChecklistItem 목록 — 합집합 정책 적용.
    /// active 전부 + soft-deleted 중 이 occurrence에 check 있는 것. sortOrder asc.
    func displayedChecklist(forOccurrence occurrenceDate: Date) -> [ChecklistItem] {
        let all = (self.checklistItems as? Set<ChecklistItem>) ?? []
        let day = Calendar.gmt.startOfDay(for: occurrenceDate)
        let visible = all.filter { ci in
            if ci.isActive { return true }
            // soft-deleted — 이 occurrence에 check 있으면 historical 표시.
            let checks = (ci.checks as? Set<ChecklistCheck>) ?? []
            return checks.contains { c in
                guard let d = c.occurrenceDate else { return false }
                return Calendar.gmt.isDate(d, inSameDayAs: day)
            }
        }
        return visible.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// 진행 카운트 (checked / total) — 표시 항목 기준.
    func checklistProgress(forOccurrence occurrenceDate: Date) -> (checked: Int, total: Int) {
        let items = displayedChecklist(forOccurrence: occurrenceDate)
        let checked = items.reduce(into: 0) { acc, ci in
            if ci.isChecked(forOccurrence: occurrenceDate) { acc += 1 }
        }
        return (checked, items.count)
    }

    /// 체크리스트가 비어있지 않은지 — chip 표시 여부 결정.
    /// displayedChecklist가 비어도 historical만 다 사라진 경우라 chip 숨김.
    func hasDisplayableChecklist(forOccurrence occurrenceDate: Date) -> Bool {
        !displayedChecklist(forOccurrence: occurrenceDate).isEmpty
    }
}

// MARK: - 토글

extension Item {
    /// 체크 토글 — ChecklistCheck 생성/삭제. context.save() 책임은 호출 측.
    /// 보통 withAnimation 안에서 호출해 row 갱신 부드럽게.
    /// 부모 Item.updatedAt도 함께 갱신 — SwiftUI @ObservedObject(item)가 child ChecklistItem 변경을
    /// 자동 관찰하지 못해 row body 재평가 안 되는 문제 회피.
    static func toggleChecklistCheck(
        for checklistItem: ChecklistItem,
        occurrenceDate: Date,
        in context: NSManagedObjectContext
    ) {
        let now = Date()
        if let existing = checklistItem.checkRecord(forOccurrence: occurrenceDate) {
            context.delete(existing)
        } else {
            let check = ChecklistCheck(context: context)
            check.id = UUID()
            check.occurrenceDate = Calendar.gmt.startOfDay(for: occurrenceDate)
            check.completedAt = now
            check.checklistItem = checklistItem
        }
        checklistItem.updatedAt = now
        checklistItem.item?.updatedAt = now
    }
}
