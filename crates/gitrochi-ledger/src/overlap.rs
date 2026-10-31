//! Overlaps: two live sessions of a project that touch the same thing may produce
//! conflicting results. `same` = shared touches. `coupled` (files that usually change
//! together, from the repository index) is reserved for a later phase.

use crate::session::SessionView;
use serde::Serialize;

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct Overlap {
    pub a: String,
    pub b: String,
    pub paths: Vec<String>,
    pub kind: &'static str,
}

/// Whether a session takes part in overlap checks: live, not archived, not a stream (a
/// stream's touches pile up cycle after cycle and would warn about everything).
pub fn counts(view: &SessionView) -> bool {
    view.is_live() && !view.is_stream() && !view.touches.is_empty()
}

/// The shared touches of `a` with `b`, in `a`'s order.
pub fn shared(a: &[String], b: &[String]) -> Vec<String> {
    a.iter().filter(|t| b.contains(t)).cloned().collect()
}

/// Every overlapping pair within each project, older session first.
pub fn overlaps(views: &[SessionView]) -> Vec<Overlap> {
    let live: Vec<&SessionView> = views.iter().filter(|v| counts(v)).collect();
    let mut out = Vec::new();
    for (i, a) in live.iter().enumerate() {
        for b in &live[i + 1..] {
            if a.project != b.project {
                continue;
            }
            let paths = shared(&a.touches, &b.touches);
            if !paths.is_empty() {
                let (a, b) = if (a.created_at, &a.id) <= (b.created_at, &b.id) {
                    (a, b)
                } else {
                    (b, a)
                };
                out.push(Overlap {
                    a: a.id.clone(),
                    b: b.id.clone(),
                    paths,
                    kind: "same",
                });
            }
        }
    }
    out
}
