import CoreData
import Foundation

/// 무료 한도 종류 — 안내 alert에서 어느 한도에 걸렸는지 구분.
enum CapKind {
    case goal
    case recurrence
    case category
    case checklist

    /// 해당 한도 값.
    var limit: Int {
        switch self {
        case .goal: return Premium.goalCap
        case .recurrence: return Premium.recurrenceCap
        case .category: return Premium.categoryCap
        case .checklist: return Premium.checklistPerTaskCap
        }
    }

    /// 한도 안내 메시지 — 어느 기능이 몇 개까지인지 + Pro 안내 (한도 숫자 주입).
    var alertMessage: String {
        let key: String
        switch self {
        case .goal: key = "cap.goal.message"
        case .recurrence: key = "cap.recurrence.message"
        case .category: key = "cap.category.message"
        case .checklist: key = "cap.checklist.message"
        }
        return String(format: NSLocalizedString(key, comment: ""), limit)
    }
}

/// Pro 전용 기능 — 잠금 안내 alert에서 어느 기능인지 구분.
enum ProFeature {
    case theme   // 테마 색상 8종
    case report  // 활동 보고서 (MissionReportView)

    /// 안내 alert 제목 (공통).
    var alertTitle: String { NSLocalizedString("pro.feature.title", comment: "") }

    /// 기능별 안내 메시지.
    var alertMessage: String {
        switch self {
        case .theme: return NSLocalizedString("pro.feature.theme.message", comment: "")
        case .report: return NSLocalizedString("pro.feature.report.message", comment: "")
        }
    }
}

/// Freemium 관련 UserDefaults 키.
enum PremiumKey {
    /// Pro 언락 여부 (App Group 공유 — 위젯도 읽음).
    /// StoreKit 2 연결 전까지는 Settings Dev 토글로만 set (테스트용).
    static let isUnlocked = "premium.isUnlocked"
}

/// 1.0 Freemium 가드. Pro면 무제한, 아니면 무료 cap 적용.
/// 게이팅 정책·cap 값은 CLAUDE.md "Freemium 계획" 섹션 참조.
/// Premium 3종: 사용량 cap 해제 / 테마 색상 / 활동 보고서(MissionReportView).
enum Premium {

    // MARK: - 무료 한도 (조정 가능)

    /// 4-type 목표(절제·활동·집중·습관) 활성 합계.
    static let goalCap = 3
    /// 반복 Todo.
    static let recurrenceCap = 3
    /// 카테고리.
    static let categoryCap = 3
    /// 할일당 체크리스트 항목.
    static let checklistPerTaskCap = 5

    // MARK: - 언락 상태

    /// Pro 언락 여부. App Group UserDefaults 기반 (본체·위젯 일관).
    static var isUnlocked: Bool {
        UserDefaults.appShared.bool(forKey: PremiumKey.isUnlocked)
    }

    // MARK: - 생성 가드 (true = 추가 가능)

    /// 새 목표(절제·활동·집중·습관) 생성 가능 여부.
    /// **보유(미삭제) 전체** 기준 — status==0(활성)만 세면 종료→재활성화로 cap 우회 가능
    /// (completeExpiredRoutines가 종료일 제거 시 자동 .pending 복원, 백그라운드라 UI로 못 막음).
    /// status != 2(deleted)로 세야 우회 불가. 완료/종료 목표도 슬롯 차지 → 삭제해야 빔.
    static func canAddGoal(in context: NSManagedObjectContext) -> Bool {
        guard !isUnlocked else { return true }
        return entityCount("Item",
                           NSPredicate(format: "kind != 0 AND status != 2"),
                           in: context) < goalCap
    }

    /// 새 반복 Todo 생성 가능 여부. 보유(미삭제) 전체 기준 (위 canAddGoal 주석 참조 — 재활성화 우회 방지).
    static func canAddRecurrence(in context: NSManagedObjectContext) -> Bool {
        guard !isUnlocked else { return true }
        return entityCount("Item",
                           NSPredicate(format: "kind == 0 AND recurrenceRule != nil AND status != 2"),
                           in: context) < recurrenceCap
    }

    /// 새 카테고리 생성 가능 여부.
    static func canAddCategory(in context: NSManagedObjectContext) -> Bool {
        guard !isUnlocked else { return true }
        return entityCount("Category", nil, in: context) < categoryCap
    }

    /// 체크리스트 항목 추가 가능 여부 (할일당). currentCount = 현재 채워진 draft 수.
    static func canAddChecklistItem(currentCount: Int) -> Bool {
        isUnlocked || currentCount < checklistPerTaskCap
    }

    // MARK: - 내부

    private static func entityCount(_ entity: String, _ predicate: NSPredicate?, in context: NSManagedObjectContext) -> Int {
        let req = NSFetchRequest<NSManagedObject>(entityName: entity)
        req.predicate = predicate
        return (try? context.count(for: req)) ?? 0
    }
}
