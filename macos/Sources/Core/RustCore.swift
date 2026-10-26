import Foundation
import GitrochiCore

/// 호출마다 독립 버퍼를 사용하므로 여러 탭·Task.detached에서도 공유 잠금이 필요 없다.
enum RustCore {
    static func graph(_ input: [UInt32]) -> [UInt32] {
        input.withUnsafeBytes { bytes in
            let output = gitrochi_graph(bytes.bindMemory(to: UInt8.self).baseAddress!, bytes.count)
            let count = Int(UInt64(littleEndian: UnsafeRawPointer(output).loadUnaligned(as: UInt64.self)))
            defer { gitrochi_free(output, count + 8) }
            precondition(count >= 8 && count % 4 == 0, "Invalid shared graph response")
            return (0..<(count / 4)).map { UInt32(littleEndian: UnsafeRawPointer(output).loadUnaligned(fromByteOffset: 8 + $0 * 4, as: UInt32.self)) }
        }
    }

    static func call(_ operation: String, _ fields: [String: Any] = [:]) -> Any {
        var request = fields
        request["op"] = operation
        // Swift Character와 화면의 Range<Int>는 확장 자소 단위다.
        request["scalarOffsets"] = false
        do {
            let data = try JSONSerialization.data(withJSONObject: request, options: [.fragmentsAllowed])
            let output = data.withUnsafeBytes { bytes in gitrochi_compute(bytes.bindMemory(to: UInt8.self).baseAddress!, data.count) }
            let count = Int(UInt64(littleEndian: UnsafeRawPointer(output).loadUnaligned(as: UInt64.self)))
            defer { gitrochi_free(output, count + 8) }
            let response = try JSONSerialization.jsonObject(with: Data(bytes: output.advanced(by: 8), count: count)) as! [String: Any]
            if let error = response["error"] as? String { preconditionFailure(error) }
            return response["value"] ?? NSNull()
        } catch { preconditionFailure("Shared core protocol failed: \(error)") }
    }

    static func object(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
    static func objects(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }
    static func integer(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
    static func optionalInteger(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
    static func string(_ value: Any?) -> String { value as? String ?? "" }
    static func strings(_ value: Any?) -> [String] { value as? [String] ?? [] }
    static func flag(_ value: Any?) -> Bool { value as? Bool ?? false }
}
