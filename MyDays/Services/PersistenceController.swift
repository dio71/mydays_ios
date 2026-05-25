import CoreData
import Foundation

final class PersistenceController {

    static let shared = PersistenceController()

    let container: NSPersistentCloudKitContainer

    var viewContext: NSManagedObjectContext { container.viewContext }

    private init(inMemory: Bool = false) {
        container = NSPersistentCloudKitContainer(name: "MyDays")

        guard let description = container.persistentStoreDescriptions.first else {
            fatalError("Failed to retrieve persistent store description.")
        }

        if inMemory {
            description.url = URL(fileURLWithPath: "/dev/null")
        }

        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                fatalError("Unresolved Core Data error \(error), \(error.userInfo)")
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    func newBackgroundContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }

    func save() {
        let context = viewContext
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            assertionFailure("Core Data save failed: \(error)")
        }
    }

    /// 모든 엔티티의 모든 객체를 삭제. CloudKit에도 동기화됨.
    ///
    /// 주의: 개발/테스트용. NSBatchDeleteRequest는 CloudKit 동기화가 누락될 수 있어
    /// fetch + context.delete 방식으로 객체별 삭제 → context.save로 CloudKit propagation 보장.
    /// 모델에 등록된 모든 entity를 한 번씩 훑으므로 entity 추가돼도 자동 포함.
    func deleteAllData() {
        let context = viewContext
        let entityNames = container.managedObjectModel.entities.compactMap { $0.name }
        for name in entityNames {
            let fetch = NSFetchRequest<NSManagedObject>(entityName: name)
            fetch.includesPropertyValues = false  // 필요한 건 objectID뿐
            do {
                let objects = try context.fetch(fetch)
                for obj in objects {
                    context.delete(obj)
                }
            } catch {
                assertionFailure("deleteAllData fetch failed for \(name): \(error)")
            }
        }
        do {
            try context.save()
        } catch {
            assertionFailure("deleteAllData save failed: \(error)")
        }
    }
}
