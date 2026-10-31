use serde::{Deserialize, Serialize};

pub const DEFAULT_DELAY_SEC: u32 = 30;
pub const MIN_DELAY_SEC: u32 = 10;
pub const MAX_DELAY_SEC: u32 = 300;
pub const DEFAULT_MAX_CONSECUTIVE: u32 = 3;
pub const MAX_CONSECUTIVE_LIMIT: u32 = 20;
/// Protected whatever the settings say, so a missing setting never opens them up.
pub const DEFAULT_PROTECTED_BRANCHES: [&str; 2] = ["main", "master"];
/// Hook timeouts leave this much room past the delay for the handler's own work (design §9.1).
pub const HOOK_TIMEOUT_MARGIN_SEC: u32 = 10;

/// Which kinds of prompts may be answered automatically.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Triggers {
    /// A turn that ends by asking the person something.
    pub stop_question: bool,
    pub ask_user_question: bool,
    /// Approving a plan ends plan mode, so it stays off unless the person turns it on.
    pub exit_plan_mode: bool,
    pub permission: bool,
}

impl Default for Triggers {
    fn default() -> Self {
        Self {
            stop_question: true,
            ask_user_question: true,
            exit_plan_mode: false,
            permission: true,
        }
    }
}

/// The language of the reply; `auto` follows the question.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Language {
    #[default]
    Auto,
    Ko,
    En,
    Ja,
    Zh,
}

/// Auto-continue settings, stored as JSON by the apps.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Policy {
    /// Off until the person turns it on: answering for someone is their choice.
    pub enabled: bool,
    pub delay_sec: u32,
    /// Most automatic answers to questions in a row; a person's input starts the count again.
    pub max_consecutive: u32,
    pub triggers: Triggers,
    /// More rules that hold a permission request for the person (README.md, "Extra rules").
    pub extra_deny: Vec<String>,
    /// Branches protected in addition to main and master; `release/*` patterns work.
    pub protected_branches: Vec<String>,
    /// MCP tools that may be allowed (`mcp__server__*` patterns work); others wait for the person.
    pub allow_mcp: Vec<String>,
    /// Replaces the built-in guidance after the first line; `{seconds}` and `{question}` are filled in.
    pub template: Option<String>,
    pub language: Language,
}

impl Default for Policy {
    fn default() -> Self {
        Self {
            enabled: false,
            delay_sec: DEFAULT_DELAY_SEC,
            max_consecutive: DEFAULT_MAX_CONSECUTIVE,
            triggers: Triggers::default(),
            extra_deny: Vec::new(),
            protected_branches: Vec::new(),
            allow_mcp: Vec::new(),
            template: None,
            language: Language::Auto,
        }
    }
}

impl Policy {
    pub fn from_json(text: &str) -> Result<Self, serde_json::Error> {
        Ok(serde_json::from_str::<Self>(text)?.normalized())
    }

    /// Clamps the numbers into their ranges and drops empty entries.
    pub fn normalized(mut self) -> Self {
        self.delay_sec = self.delay();
        self.max_consecutive = self.max_consecutive.min(MAX_CONSECUTIVE_LIMIT);
        for list in [
            &mut self.extra_deny,
            &mut self.protected_branches,
            &mut self.allow_mcp,
        ] {
            *list = clean(list);
        }
        if self
            .template
            .as_deref()
            .is_some_and(|t| t.trim().is_empty())
        {
            self.template = None;
        }
        self
    }

    /// The delay in seconds, within 10–300 whatever the file says.
    pub fn delay(&self) -> u32 {
        self.delay_sec.clamp(MIN_DELAY_SEC, MAX_DELAY_SEC)
    }

    pub fn hook_timeout(&self) -> u32 {
        self.delay() + HOOK_TIMEOUT_MARGIN_SEC
    }

    /// main, master and the configured branches.
    pub fn protected(&self) -> Vec<String> {
        let mut all: Vec<String> = DEFAULT_PROTECTED_BRANCHES
            .iter()
            .map(|b| b.to_string())
            .collect();
        all.extend(self.protected_branches.iter().cloned());
        clean(&all)
    }
}

fn clean(list: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for item in list {
        let item = item.trim();
        if !item.is_empty() && !out.iter().any(|o| o == item) {
            out.push(item.to_string());
        }
    }
    out
}
