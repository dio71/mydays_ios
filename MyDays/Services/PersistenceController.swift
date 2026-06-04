import CoreData
import Foundation
import WidgetKit

final class PersistenceController {

    static let shared = PersistenceController()

    /// Widget Extension과 store를 공유하기 위한 App Group ID.
    /// 두 target의 Signing & Capabilities → App Groups에 동일 ID가 등록돼 있어야 함.
    static let appGroupID = "group.io.snapplay.MyDays"

    /// 마지막 CloudKit 동기화(import/export) 성공 시각 — Settings 표시용.
    /// timeIntervalSinceReferenceDate(Double)로 UserDefaults.standard에 저장. SettingsView가 @AppStorage로 관찰.
    static let lastSyncDateKey = "sync.lastSyncDate"

    /// NSPersistentCloudKitContainer는 NSPersistentContainer의 subclass.
    /// Main app은 CloudKit 동기화 필요해 CloudKit container, Widget process는 메모리 부담 줄이기 위해 일반 container.
    /// Widget은 sqlite를 read-only로만 접근 — sync는 main app이 처리.
    let container: NSPersistentContainer

    var viewContext: NSManagedObjectContext { container.viewContext }

    private init(inMemory: Bool = false) {
        if Self.isWidgetExtension {
            // Widget memory limit(~30MB) 초과 회피 — CloudKit metadata/sync 인프라 제거.
            container = NSPersistentContainer(name: "MyDays")
        } else {
            container = NSPersistentCloudKitContainer(name: "MyDays")
        }

        guard let description = container.persistentStoreDescriptions.first else {
            fatalError("Failed to retrieve persistent store description.")
        }

        if inMemory {
            description.url = URL(fileURLWithPath: "/dev/null")
        } else {
            // 기존 default location → App Group shared container로 1회 마이그레이션.
            // sqlite 본체 + WAL + SHM 세 파일을 모두 이동. 이미 shared에 있으면 no-op.
            Self.migrateStoreToSharedContainerIfNeeded()
            if let sharedURL = Self.sharedStoreURL() {
                description.url = sharedURL
            }
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

        // Widget process에서는 observer 등록 X — CloudKit background sync로 widget process가 save를 받으면
        // observer가 reloadAllTimelines를 호출하고 그게 다시 widget process를 깨우는 self-trigger 루프가 생김.
        // Main app process에서만 등록 → 사용자 변경(save) 시점에 위젯 갱신.
        if !Self.isWidgetExtension {
            NotificationCenter.default.addObserver(
                forName: .NSManagedObjectContextDidSave,
                object: nil,
                queue: .main
            ) { _ in
                WidgetCenter.shared.reloadAllTimelines()
            }

            // Firebase 마이그레이션 prep: 모든 entity 객체에 id 채워졌는지 검증.
            // 모델에 id 추가되기 전 빌드의 잔존 row가 있을 수 있어 부팅 시 한 번 검사 → 로그만.
            // 백필 없이 로그만 — 테스트 중 노출되는지 사용자가 직접 모니터링.
            logEntitiesWithMissingID()

            // CloudKit 동기화 이벤트 관찰 → 마지막 import/export 성공 시각 기록 (Settings 표시용).
            observeCloudKitSyncEvents()
        }
    }

    /// NSPersistentCloudKitContainer의 import/export 이벤트가 성공 완료되면 그 시각을 UserDefaults에 기록.
    /// Settings "마지막 동기화" row가 @AppStorage로 읽어 표시.
    private func observeCloudKitSyncEvents() {
        guard let ckContainer = container as? NSPersistentCloudKitContainer else { return }
        NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: ckContainer,
            queue: .main
        ) { note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            // 완료된(endDate != nil) import/export + 성공만 기록. setup/진행중/실패는 무시.
            guard event.endDate != nil, event.succeeded,
                  event.type == .import || event.type == .export else { return }
            let stamp = (event.endDate ?? Date()).timeIntervalSinceReferenceDate
            UserDefaults.standard.set(stamp, forKey: Self.lastSyncDateKey)
        }
    }

    /// 모든 entity 중 `id` attribute가 있는 것들을 fetch해서 id == nil인 row를 entity별로 카운트 + 로그.
    /// 변경/저장은 하지 않음 — 데이터 정합성 모니터링 목적 (Firebase 마이그레이션 시 nil id는 sync 불가).
    private func logEntitiesWithMissingID() {
        let context = viewContext
        for entity in container.managedObjectModel.entities {
            guard let name = entity.name,
                  entity.attributesByName["id"] != nil else { continue }
            let request = NSFetchRequest<NSManagedObject>(entityName: name)
            request.predicate = NSPredicate(format: "id == nil")
            do {
                let rows = try context.fetch(request)
                guard !rows.isEmpty else { continue }
                let sample = rows.prefix(3).map { obj -> String in
                    if let title = obj.value(forKey: "title") as? String { return "title=\(title)" }
                    return obj.objectID.uriRepresentation().lastPathComponent
                }.joined(separator: ", ")
                print("⚠️ [MigrationPrep] \(name): \(rows.count) row(s) with nil id — sample: \(sample)")
            } catch {
                print("⚠️ [MigrationPrep] \(name): fetch failed — \(error)")
            }
        }
    }

    /// Bundle ID로 현재 process가 widget extension인지 판정.
    /// `io.snapplay.MyDays.MyDaysWidget` 매칭 — Bundle.main이 host app이 아닌 widget appex임을 의미.
    private static var isWidgetExtension: Bool {
        Bundle.main.bundleIdentifier?.hasSuffix(".MyDaysWidget") == true
    }

    /// App Group shared container 내의 store URL. App Group이 설정 안 됐으면 nil.
    private static func sharedStoreURL() -> URL? {
        let fm = FileManager.default
        return fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("MyDays.sqlite")
    }

    /// 기존 default location(`Application Support/MyDays.sqlite`)에서 shared container로 1회 마이그레이션.
    /// shared 위치에 이미 sqlite가 있거나 default 위치에 데이터가 없으면 no-op.
    /// .sqlite / .sqlite-wal / .sqlite-shm 세 파일을 모두 복사 (write-ahead log + shared memory).
    /// 마이그레이션 후 default 파일은 그대로 둠 — Core Data가 shared만 보니까 orphan이고 안전.
    private static func migrateStoreToSharedContainerIfNeeded() {
        let fm = FileManager.default
        guard let sharedURL = sharedStoreURL() else { return }
        if fm.fileExists(atPath: sharedURL.path) { return }

        let defaultURL = NSPersistentContainer.defaultDirectoryURL()
            .appendingPathComponent("MyDays.sqlite")
        guard fm.fileExists(atPath: defaultURL.path) else { return }

        let suffixes = ["", "-wal", "-shm"]
        for suffix in suffixes {
            let src = URL(fileURLWithPath: defaultURL.path + suffix)
            let dst = URL(fileURLWithPath: sharedURL.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            do {
                try fm.copyItem(at: src, to: dst)
            } catch {
                assertionFailure("PersistenceController migration copy failed: \(error)")
            }
        }
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
