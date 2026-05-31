import CoreData
import Foundation

// MARK: - Category alert defaults
//
// Category에 저장된 알림 default offset(분)을 AddItemView에 적용하기 위한 typed accessor.
// Core Data 필드는 NSNumber? — nil = OFF, 정수 = ON + offset(분).
//
// 적용 매핑 (AddItemView에서 신규 항목 작성 중 카테고리 선택/시간설정 변경 시 적용):
// - Todo + hasTime=true: todoStartAlertOffset → defaultTodoTimedStart, todoDueAlertOffset(period) → defaultTodoTimedDue
// - Todo + hasTime=false: todoStartAlertOffset → defaultTodoUntimedStart, todoDueAlertOffset(period) → defaultTodoUntimedDue
//
// 신규 카테고리 생성 시 default: Todo 4종 모두 nil (미설정).
//
// **주의**: 카테고리는 Todo 전용 도구. 목표(절제/활동)는 카테고리 사용 안 함 (Item.iconColorHex/iconName 직접 보유).

extension Category {

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
}
