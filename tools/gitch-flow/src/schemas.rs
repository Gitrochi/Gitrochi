//! Public JSON Schemas (Draft 2020-12). `gitch schema flow*` hands off to these (gitch-v1's 20 names stay as they are).

pub const NAMES: &[&str] = &[
    "flow",
    "flow-plan",
    "flow-run",
    "flow-event",
    "flow-report",
    "flow-error",
    "flow-design-inspect",
    "flow-design-render",
    "ci-browse",
];

pub fn get(name: &str) -> Option<&'static str> {
    Some(match name {
        "flow" | "spec" => include_str!("../schema/flow-v1.schema.json"),
        "flow-plan" | "plan" => include_str!("../schema/flow-plan-v1.schema.json"),
        "flow-run" | "run" => include_str!("../schema/flow-run-v1.schema.json"),
        "flow-event" | "event" => include_str!("../schema/flow-event-v1.schema.json"),
        "flow-report" | "report" => include_str!("../schema/flow-report-v1.schema.json"),
        "flow-error" | "error" => include_str!("../schema/flow-error-v1.schema.json"),
        "flow-design-inspect" | "design-inspect" => {
            include_str!("../schema/flow-design-inspect-v1.schema.json")
        }
        "flow-design-render" | "design-render" => {
            include_str!("../schema/flow-design-render-v1.schema.json")
        }
        "ci-browse" => include_str!("../schema/ci-browse.schema.json"),
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    #[test]
    fn schemas_are_json() {
        for n in super::NAMES {
            let v: serde_json::Value =
                serde_json::from_str(super::get(n).unwrap()).unwrap_or_else(|e| panic!("{n}: {e}"));
            assert_eq!(v["$schema"], "https://json-schema.org/draft/2020-12/schema");
        }
    }
}
