import Foundation

/// The HTTP provider's documented request shape fills gaps in its open-ended input schema.
enum FlowInputSchema {
    static func field(_ name: String, block: String, schema: FlowJSON) -> FlowJSON {
        guard block == "ci.http", ["trigger", "status", "logs", "cancel", "find"].contains(name), schema["properties"].object.isEmpty else { return schema }
        let string: FlowJSON = .object(["type": .string("string")])
        var fields: [String: FlowJSON] = [
            "url": string,
            "method": .object(["type": .string("string"), "enum": .array(["GET", "POST", "PUT", "PATCH", "DELETE"].map(FlowJSON.string))]),
            "headers": .object(["type": .string("object")]),
            "body": .object(["oneOf": .array([.object(["type": .string("object")]), string])])
        ]
        if name == "status" {
            fields["pointer"] = string
            for key in ["success", "failure", "cancelled", "queued"] {
                fields[key] = .object(["type": .string("array"), "items": string])
            }
        }
        if name == "find" { fields["id"] = string }
        return .object(["type": .string("object"), "properties": .object(fields), "required": .array([.string("url")]),
                        "description": .string("Use {id} for the remote run and {corr} for its correlation identifier. Status pointer is a JSON pointer, such as /status.")])
    }
}
