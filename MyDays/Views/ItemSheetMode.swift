import CoreData
import Foundation

enum ItemSheetMode: Identifiable {
    case new(baseDate: Date?, categoryID: UUID? = nil)
    case edit(Item)

    var id: String {
        switch self {
        case .new:
            return "new"
        case .edit(let item):
            return item.objectID.uriRepresentation().absoluteString
        }
    }
}
