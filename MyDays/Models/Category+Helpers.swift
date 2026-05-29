import CoreData
import Foundation

// MARK: - Category alert defaults
//
// Category에 저장된 알림 default offset(분)을 AddItemView에 적용하기 위한 typed accessor.
// Core Data 필드는 NSNumber? — nil = OFF, 정수 = ON + offset(분).
//
// 적용 매핑 (AddItemView에서 신규 항목 작성 중 카테고리 선택/시간설정 변경 시 적용):
// - NTD: ntdStartAlertOffset → defaultNtdStart, ntdEndAlertOffset → defaultNtdDue
// - Todo + hasTime=true: todoStartAlertOffset → defaultTodoTimedStart, todoDueAlertOffset(period) → defaultTodoTimedDue
// - Todo + hasTime=false: todoStartAlertOffset → defaultTodoUntimedStart, todoDueAlertOffset(period) → defaultTodoUntimedDue
//
// 신규 카테고리 생성 시 default:
// - NTD start/due → 0 (정각)
// - Todo 4종 → nil (모두 미설정)

extension Category {

    /// 신규 카테고리 생성 시 적용할 NTD 시작 알림 default — 정시(0분).
    static let newCategoryNtdStartAlertDefault: Int = 0
    /// 신규 카테고리 생성 시 적용할 NTD 종료 알림 default — 정시(0분).
    static let newCategoryNtdDueAlertDefault: Int = 0

    // MARK: NTD

    var defaultNtdStartAlertInt: Int? {
        get { (value(forKey: "defaultNtdStartAlertOffset") as? NSNumber).map { Int(truncating: $0) } }
        set { setValue(newValue.map { NSNumber(value: $0) }, forKey: "defaultNtdStartAlertOffset") }
    }

    var defaultNtdDueAlertInt: Int? {
        get { (value(forKey: "defaultNtdDueAlertOffset") as? NSNumber).map { Int(truncating: $0) } }
        set { setValue(newValue.map { NSNumber(value: $0) }, forKey: "defaultNtdDueAlertOffset") }
    }

    // MARK: Todo

    var defaultTodoTimedStartAlertInt: Int? {
        get { (value(forKey: "defaultTodoTimedStartAlertOffset") as? NSNumber).map { Int(truncating: $0) } }
        set { setValue(newValue.map { NSNumber(value: $0) }, forKey: "defaultTodoTimedStartAlertOffset") }
    }

    var defaultTodoTimedDueAlertInt: Int? {
        get { (value(forKey: "defaultTodoTimedDueAlertOffset") as? NSNumber).map { Int(truncating: $0) } }
        set { setValue(newValue.map { NSNumber(value: $0) }, forKey: "defaultTodoTimedDueAlertOffset") }
    }

    var defaultTodoUntimedStartAlertInt: Int? {
        get { (value(forKey: "defaultTodoUntimedStartAlertOffset") as? NSNumber).map { Int(truncating: $0) } }
        set { setValue(newValue.map { NSNumber(value: $0) }, forKey: "defaultTodoUntimedStartAlertOffset") }
    }

    var defaultTodoUntimedDueAlertInt: Int? {
        get { (value(forKey: "defaultTodoUntimedDueAlertOffset") as? NSNumber).map { Int(truncating: $0) } }
        set { setValue(newValue.map { NSNumber(value: $0) }, forKey: "defaultTodoUntimedDueAlertOffset") }
    }

    // MARK: NTD 기본 카테고리 exclusive

    /// `isDefaultForNTD = true`로 marking된 카테고리 1개 반환. 없으면 nil.
    /// 다중 row가 true인 경우(legacy/충돌) sortOrder 우선 1개만 채택.
    static func defaultForNTD(in context: NSManagedObjectContext) -> Category? {
        let req: NSFetchRequest<Category> = Category.fetchRequest()
        req.predicate = NSPredicate(format: "isDefaultForNTD == YES")
        req.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
        req.fetchLimit = 1
        return (try? context.fetch(req))?.first
    }

    /// 이 카테고리를 NTD 기본 카테고리로 설정. 다른 모든 카테고리의 flag는 해제 (exclusive).
    /// 토글 OFF는 self.isDefaultForNTD = false 직접 설정으로 처리.
    func markAsDefaultForNTD(in context: NSManagedObjectContext) {
        let req: NSFetchRequest<Category> = Category.fetchRequest()
        req.predicate = NSPredicate(format: "isDefaultForNTD == YES AND SELF != %@", self)
        if let others = try? context.fetch(req) {
            for c in others {
                c.isDefaultForNTD = false
                c.updatedAt = Date()
            }
        }
        self.isDefaultForNTD = true
        self.updatedAt = Date()
    }
}
