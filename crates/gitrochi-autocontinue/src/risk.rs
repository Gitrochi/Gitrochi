//! Whether a question, a chosen option or a plan is about something hard to reverse. Such
//! prompts wait for the person: telling the agent to go ahead with its recommendation is
//! wrong when the recommendation is to force push or deploy.

use crate::text::has_phrase;

const FORCE_PUSH: &[&str] = &[
    "force push",
    "force-push",
    "force pushing",
    "push --force",
    "push -f",
    "--force-with-lease",
    "강제 push",
    "강제 푸시",
    "강제로 push",
    "강제로 푸시",
    "強制プッシュ",
    "强制推送",
];

const DESTROY: &[&str] = &[
    "rm -rf",
    "reset --hard",
    "git clean",
    "drop table",
    "drop database",
    "wipe",
    "purge",
    "data loss",
    "delete the branch",
    "delete the remote",
    "delete the repository",
    "delete the database",
    "delete all",
    "데이터 삭제",
    "데이터를 삭제",
    "전부 삭제",
    "모두 삭제",
    "브랜치 삭제",
    "브랜치를 삭제",
    "데이터베이스",
    "データを削除",
    "すべて削除",
    "删除数据",
    "删除分支",
    "全部删除",
];

const DEPLOY: &[&str] = &[
    "deploy",
    "deploying",
    "deployment",
    "release",
    "releases",
    "publish",
    "publishing",
    "production",
    "go live",
    "배포",
    "릴리스",
    "릴리즈",
    "출시",
    "운영 서버",
    "프로덕션",
    "デプロイ",
    "リリース",
    "本番",
    "部署",
    "发布",
    "上线",
    "生产环境",
];

// Bare "token" and "account" are left out: tokenizers and "take into account" are common.
const CREDENTIALS: &[&str] = &[
    "credential",
    "credentials",
    "password",
    "passwords",
    "access token",
    "auth token",
    "api token",
    "secret",
    "secrets",
    "api key",
    "ssh key",
    "account settings",
    "git account",
    "github account",
    "user account",
    "switch account",
    "자격 증명",
    "비밀번호",
    "액세스 토큰",
    "인증 토큰",
    "계정",
    "인증 정보",
    "認証情報",
    "パスワード",
    "アクセストークン",
    "アカウント",
    "凭据",
    "密码",
    "访问令牌",
    "账户",
    "账号",
];

/// The kind of hard-to-reverse action `text` mentions, if any. `protected` adds pushes and
/// merges into those branches ("push to main", "main에 머지").
pub fn risky(text: &str, protected: &[String]) -> Option<&'static str> {
    let lower = text.to_lowercase();
    let found = |list: &[&str]| list.iter().any(|p| has_phrase(&lower, p));
    if found(FORCE_PUSH) {
        return Some("force-push");
    }
    if protected
        .iter()
        .any(|branch| mentions_protected_push(&lower, &branch.to_lowercase()))
    {
        return Some("protected-branch");
    }
    if found(DESTROY) {
        return Some("delete");
    }
    if found(DEPLOY) {
        return Some("deploy");
    }
    if found(CREDENTIALS) {
        return Some("credentials");
    }
    None
}

fn mentions_protected_push(lower: &str, branch: &str) -> bool {
    if branch.contains('*') {
        // patterns such as release/* name no single branch to look for
        return false;
    }
    let english = [
        "push to",
        "push it to",
        "push into",
        "pushing to",
        "merge into",
        "merge to",
        "merge it into",
        "merging into",
    ];
    if english
        .iter()
        .any(|verb| has_phrase(lower, &format!("{verb} {branch}")))
    {
        return true;
    }
    let local = [
        format!("{branch}에 push"),
        format!("{branch}에 푸시"),
        format!("{branch}로 push"),
        format!("{branch}로 푸시"),
        format!("{branch}에 머지"),
        format!("{branch}에 병합"),
        format!("{branch} 브랜치에 push"),
        format!("{branch} 브랜치에 푸시"),
        format!("{branch} 브랜치에 머지"),
        format!("{branch} 브랜치로"),
        format!("{branch}にpush"),
        format!("{branch}にプッシュ"),
        format!("{branch}にマージ"),
        format!("推送到 {branch}"),
        format!("推送到{branch}"),
        format!("合并到 {branch}"),
        format!("合并到{branch}"),
    ];
    local.iter().any(|p| lower.contains(p.as_str()))
}
