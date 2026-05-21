import CoreData
import Foundation

extension ItemEvent {

    var itemAction: ItemAction {
        get { ItemAction(rawValue: action) ?? .updated }
        set { action = newValue.rawValue }
    }

    @discardableResult
    static func log(
        _ action: ItemAction,
        on item: Item,
        in context: NSManagedObjectContext,
        note: String? = nil
    ) -> ItemEvent {
        let event = ItemEvent(context: context)
        event.id = UUID()
        event.timestamp = Date()
        event.itemAction = action
        event.itemTitle = item.title
        event.item = item
        event.note = note
        return event
    }
}
