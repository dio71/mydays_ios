import CoreData
import Foundation

// MARK: - DataExportService
//
// 전체 데이터를 JSON 한 파일로 내보내기 (백업 / GDPR 데이터 이동권 / 향후 import용).
// 모델의 모든 entity를 제네릭하게 순회 — entity 추가돼도 자동 포함.
// 관계는 상대 객체의 id(UUID) 참조로 flatten (모든 entity가 id 보유 — Firebase prep).
//
// schemaVersion으로 향후 import 호환성 대비.

enum DataExportService {

    static let schemaVersion = 1

    /// 전체 데이터를 JSON 파일로 써서 temp URL 반환. 실패 시 nil.
    static func exportJSON(in context: NSManagedObjectContext) -> URL? {
        let model = context.persistentStoreCoordinator?.managedObjectModel
            ?? PersistenceController.shared.container.managedObjectModel

        var entities: [String: [[String: Any]]] = [:]
        for entity in model.entities {
            guard let name = entity.name else { continue }
            let request = NSFetchRequest<NSManagedObject>(entityName: name)
            let objects = (try? context.fetch(request)) ?? []
            entities[name] = objects.map { row(for: $0, entity: entity) }
        }

        let payload: [String: Any] = [
            "app": "MyDays",
            "schemaVersion": schemaVersion,
            "exportedAt": iso(Date()),
            "entities": entities
        ]

        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return nil }

        let stamp = fileStamp()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyDays-backup-\(stamp).json")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            assertionFailure("DataExport write failed: \(error)")
            return nil
        }
    }

    // MARK: - 객체 1개 → dict

    private static func row(for obj: NSManagedObject, entity: NSEntityDescription) -> [String: Any] {
        var dict: [String: Any] = [:]
        // 속성.
        for (attr, _) in entity.attributesByName {
            dict[attr] = encode(obj.value(forKey: attr))
        }
        // 관계 → id 참조.
        for (rel, desc) in entity.relationshipsByName {
            if desc.isToMany {
                dict[rel] = relatedIDs(obj.value(forKey: rel))
            } else if let target = obj.value(forKey: rel) as? NSManagedObject {
                dict[rel] = (target.value(forKey: "id") as? UUID)?.uuidString ?? NSNull()
            } else {
                dict[rel] = NSNull()
            }
        }
        return dict
    }

    private static func relatedIDs(_ value: Any?) -> [String] {
        let objects: [NSManagedObject]
        if let set = value as? Set<NSManagedObject> {
            objects = Array(set)
        } else if let ordered = value as? NSOrderedSet {
            objects = ordered.array as? [NSManagedObject] ?? []
        } else {
            objects = []
        }
        return objects.compactMap { ($0.value(forKey: "id") as? UUID)?.uuidString }
    }

    // MARK: - 값 인코딩

    private static func encode(_ value: Any?) -> Any {
        switch value {
        case let d as Date:    return iso(d)
        case let u as UUID:    return u.uuidString
        case let data as Data: return data.base64EncodedString()
        case let n as NSNumber: return n
        case let s as String:  return s
        default:               return NSNull()
        }
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func fileStamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
