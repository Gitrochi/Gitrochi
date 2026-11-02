use super::*;

pub(super) fn call(
    c: &Connection,
    args: &Value,
    action: &str,
    now: i64,
    human: bool,
) -> Result<Value> {
    let project = if matches!(action, "add_bundle" | "add_item" | "event" | "note") {
        required(args, &["project"])?
    } else {
        project(c, args)?
    };
    crate::baseline::ensure_project(c, &project, now)?;
    match action {
        "add_bundle" => {
            let bundle = bundle(args)?;
            let (date, _) = date(args, false)?;
            add_bundle(c, &project, &bundle, &date, now)?;
            Ok(json!({"project":project,"bundle":bundle}))
        }
        "add_item" => add_item(c, &project, args, now),
        "event" => event(c, &project, args, now),
        "note" if human => {
            let text = text(args)?;
            if text.is_empty() {
                return Err(Error::invalid("A note cannot be empty"));
            }
            let target = arg_str(args, "target").unwrap_or_default();
            if !target.is_empty() {
                let exists: bool = c.query_row("SELECT EXISTS(SELECT 1 FROM ledger_work_items WHERE project=?1 AND id=?2 UNION ALL SELECT 1 FROM ledger_work_bundles WHERE project=?1 AND name=?2)", params![project,target], |r| r.get(0))?;
                if !exists {
                    return Err(Error::not_found("The work note target does not exist"));
                }
            }
            c.execute("INSERT INTO ledger_work_notes(project,target,text,created_at) VALUES (?1,?2,?3,?4)", params![project,target,text,now])?;
            Ok(json!({"project":project,"id":c.last_insert_rowid()}))
        }
        "note" => Err(Error::not_allowed(
            "Only a person in the app can leave a work note",
        )),
        _ => Err(Error::invalid(format!("Unknown work action: {action}"))),
    }
}

pub(super) fn add_bundle(
    c: &Connection,
    project: &str,
    bundle: &str,
    date: &str,
    now: i64,
) -> Result<()> {
    c.execute("INSERT OR IGNORE INTO ledger_work_bundles(project,name,created_date,created_at) VALUES (?1,?2,?3,?4)", params![project,bundle,date,now])?;
    Ok(())
}

fn valid_id(id: &str) -> bool {
    id.starts_with("W-")
        && id.chars().count() <= 100
        && id
            .chars()
            .all(|ch| ch.is_alphanumeric() || matches!(ch, '-' | '_' | '.'))
        && id
            .rsplit('-')
            .next()
            .is_some_and(|s| s.len() >= 2 && s.bytes().all(|v| v.is_ascii_digit()))
}

fn add_item(c: &Connection, project: &str, args: &Value, now: i64) -> Result<Value> {
    if (args.get("event").is_some() || args.get("ev").is_some()) && kind(args)? != "registered" {
        return Err(Error::invalid("add_item only accepts a registered event"));
    }
    let id = item_id(args)?;
    if !valid_id(&id) {
        return Err(Error::invalid(
            "item must be W-<group>-<number>, for example W-app-01",
        ));
    }
    let exists: bool = c.query_row(
        "SELECT EXISTS(SELECT 1 FROM ledger_work_items WHERE id=?1)",
        [&id],
        |r| r.get(0),
    )?;
    if exists {
        return Err(Error::conflict(format!(
            "Work item {id} already exists; IDs cannot be reused"
        )));
    }
    let bundle = bundle(args)?;
    let title = limited(required(args, &["title", "t"])?, "title", 500)?;
    let output = limited(
        arg_str_any(args, &["output", "out"]).unwrap_or_default(),
        "output",
        2000,
    )?;
    let scope = list_of(&args["scope"]);
    let stem = limited(
        arg_str_any(args, &["stem", "g"]).unwrap_or_default(),
        "stem",
        100,
    )?;
    let (date, estimated) = date(args, true)?;
    let from = arg_str(args, "from");
    if let Some(from) = &from {
        load_item(c, project, from)?;
    }
    add_bundle(c, project, &bundle, &date, now)?;
    if bundle_completed(c, project, &bundle)? {
        return Err(Error::conflict("Reopen the bundle before adding work"));
    }
    c.execute("INSERT INTO ledger_work_items(id,project,bundle,title,output,scope,stem,from_item,created_date,created_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)", params![id,project,bundle,title,output,serde_json::to_string(&scope)?,stem,from,date,now])?;
    let event = insert_event(
        c,
        &json!({"project":project,"item":id,"bundle":bundle,"event":"registered","date":date,"estimated":estimated,"text":text(args)?,"refs":refs(args),"data":{"from":from}}),
        now,
    )?;
    Ok(json!({"project":project,"item":load_item(c,project,&id)?,"eventId":event}))
}

fn bundle_completed(c: &Connection, project: &str, bundle: &str) -> Result<bool> {
    Ok(c.query_row("SELECT kind FROM ledger_work_events WHERE project=?1 AND item IS NULL AND bundle=?2 AND kind IN ('bundle_completed','bundle_reopened') ORDER BY date DESC,id DESC LIMIT 1", params![project,bundle], |r| r.get::<_,String>(0)).optional()?.as_deref() == Some("bundle_completed"))
}

fn event(c: &Connection, project: &str, args: &Value, now: i64) -> Result<Value> {
    let kind = kind(args)?;
    if kind == "registered" {
        return add_item(c, project, args, now);
    }
    if kind == "skipped" {
        return skip(c, project, args, now);
    }
    if matches!(kind.as_str(), "bundle_completed" | "bundle_reopened") {
        let bundle = bundle(args)?;
        let (date, _) = date(args, false)?;
        let exists: bool = c.query_row(
            "SELECT EXISTS(SELECT 1 FROM ledger_work_bundles WHERE project=?1 AND name=?2)",
            params![project, bundle],
            |r| r.get(0),
        )?;
        if !exists {
            return Err(Error::not_found("The work bundle does not exist"));
        }
        if bundle == "Later" || bundle == "차후 과제" {
            return Err(Error::invalid("The later-work bundle cannot be completed"));
        }
        if (kind == "bundle_completed") == bundle_completed(c, project, &bundle)? {
            return Err(Error::conflict("The bundle already has that status"));
        }
        if kind == "bundle_completed" {
            let state = super::read::state(c, project, args, now)?;
            if state["items"].as_array().is_some_and(|items| {
                items.iter().any(|item| {
                    item["bundle"] == bundle && !closed(item["status"].as_str().unwrap_or(""))
                })
            }) {
                return Err(Error::conflict(
                    "Complete, freeze, cancel or transfer the remaining items first",
                ));
            }
        }
        let id = insert_event(
            c,
            &json!({"project":project,"bundle":bundle,"event":kind,"date":date,"text":text(args)?,"refs":refs(args)}),
            now,
        )?;
        return Ok(json!({"project":project,"bundle":bundle,"eventId":id}));
    }
    if matches!(kind.as_str(), "text_fix" | "date_fix") {
        return correction(c, project, args, &kind, now);
    }
    let id = item_id(args)?;
    let item = load_item(c, project, &id)?;
    if matches!(kind.as_str(), "stem" | "item_fix") {
        return edit_item(c, project, &item, args, &kind, now);
    }
    if kind == "move" {
        return move_event(c, project, &item, args, now);
    }
    if kind == "carry" {
        return carry(c, project, &item, args, now);
    }
    if !matches!(
        kind.as_str(),
        "started"
            | "progress"
            | "completed"
            | "frozen"
            | "held"
            | "resumed"
            | "cancelled"
            | "plan"
            | "issue"
            | "transfer"
    ) {
        return Err(Error::invalid(format!("Unknown work event: {kind}")));
    }
    let (date, estimated) = date(args, true)?;
    let text = text(args)?;
    if text.is_empty() && kind != "plan" {
        return Err(Error::invalid(
            "A work event needs text describing the work",
        ));
    }
    let mut data = json!({});
    let plan = if kind == "plan" {
        let raw = args
            .get("plan")
            .filter(|v| v.is_object())
            .ok_or_else(|| Error::invalid("plan requires conservative and slack dates"))?;
        let early = required(raw, &["conservative", "보수"])?;
        let late = required(raw, &["slack", "여유"])?;
        let (early, _) = date_value(&early, false)?;
        let (late, _) = date_value(&late, false)?;
        if early > late {
            return Err(Error::invalid(
                "The slack date cannot precede the conservative date",
            ));
        }
        json!({"conservative":early,"slack":late})
    } else {
        if !args["plan"].is_null() {
            return Err(Error::invalid("plan is allowed only on a plan event"));
        }
        Value::Null
    };
    let mut bundle = item["bundle"].as_str().unwrap_or_default().to_string();
    if kind == "transfer" {
        bundle = arg_str_any(args, &["to", "bundle", "b"])
            .ok_or_else(|| Error::invalid("transfer requires a destination bundle"))?;
        if item["bundle"] == bundle {
            return Err(Error::invalid("The item already belongs to that bundle"));
        }
        add_bundle(c, project, &bundle, &date, now)?;
        if bundle_completed(c, project, &bundle)? {
            return Err(Error::conflict("The destination bundle is completed"));
        }
        data = json!({"fromBundle":item["bundle"],"toBundle":bundle});
        c.execute(
            "UPDATE ledger_work_items SET bundle=?2 WHERE id=?1",
            params![id, bundle],
        )?;
    }
    let event = insert_event(
        c,
        &json!({"project":project,"item":id,"bundle":bundle,"event":kind,"date":date,"estimated":estimated,"text":text,"refs":refs(args),"plan":plan,"data":data}),
        now,
    )?;
    if kind == "transfer" {
        let current: String = c.query_row("SELECT json_extract(data,'$.toBundle') FROM ledger_work_events WHERE item=?1 AND kind='transfer' ORDER BY date DESC,id DESC LIMIT 1",[&id],|r|r.get(0))?;
        c.execute(
            "UPDATE ledger_work_items SET bundle=?2 WHERE id=?1",
            params![id, current],
        )?;
    }
    Ok(json!({"project":project,"item":id,"eventId":event}))
}

pub(super) fn closed(status: &str) -> bool {
    matches!(status, "completed" | "frozen" | "cancelled" | "carried")
}

fn history(
    c: &Connection,
    project: &str,
    target: (Option<&str>, Option<i64>),
    action: &str,
    date: &str,
    change: (&Value, &Value),
    now: i64,
) -> Result<()> {
    c.execute("INSERT INTO ledger_work_history(project,item,event_id,action,date,before_value,after_value,created_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8)",params![project,target.0,target.1,action,date,change.0.to_string(),change.1.to_string(),now])?;
    Ok(())
}

fn target(c: &Connection, project: &str, args: &Value, date_key: &str) -> Result<Value> {
    let item = arg_str_any(args, &["item", "w"]);
    let bundle = arg_str_any(args, &["bundle", "b"]);
    if item.is_none() && bundle.is_none() {
        return Err(Error::invalid("Select a work item or bundle"));
    }
    let date = if date_key.is_empty() {
        None
    } else {
        Some(
            arg_str(args, date_key)
                .or_else(|| arg_str_any(args, &["date", "d"]))
                .ok_or_else(|| Error::invalid("A target date is required"))?,
        )
    }
    .map(|date| date_value(&date, true).map(|v| v.0))
    .transpose()?;
    let of = arg_str(args, "of")
        .map(|event| kind(&json!({"event":event})))
        .transpose()?;
    let old = arg_str(args, "old");
    let eid = args["eventId"].as_i64();
    let selected: Vec<_> = events(c, project, item.as_deref())?
        .into_iter()
        .filter(|e| {
            (item.is_some() || e["item"].is_null())
                && (bundle.is_none() || e["bundle"] == bundle.as_deref().unwrap_or(""))
                && date.as_ref().is_none_or(|date| e["date"] == *date)
                && of.as_ref().is_none_or(|kind| e["event"] == *kind)
                && old
                    .as_ref()
                    .is_none_or(|old| e["text"].as_str().unwrap_or("").contains(old))
                && eid.is_none_or(|id| e["id"].as_i64() == Some(id))
        })
        .collect();
    if selected.len() != 1 {
        return Err(Error::invalid(format!(
            "The target matches {} records; use eventId, of and old to select one",
            selected.len()
        )));
    }
    Ok(selected[0].clone())
}

fn correction(c: &Connection, project: &str, args: &Value, kind: &str, now: i64) -> Result<Value> {
    let before = target(
        c,
        project,
        args,
        if kind == "date_fix" { "was" } else { "date" },
    )?;
    let eid = before["id"].as_i64().unwrap_or_default();
    let mut after = before.clone();
    if kind == "date_fix" {
        if refs(args).is_empty() {
            return Err(Error::invalid("A date correction needs evidence in refs"));
        }
        if !before["estimated"].as_bool().unwrap_or(false) {
            return Err(Error::invalid("Only an estimated date can be replaced"));
        }
        let (new, _) = date(args, false)?;
        after["date"] = json!(new);
        after["estimated"] = json!(false);
        c.execute(
            "UPDATE ledger_work_events SET date=?2,estimated=0 WHERE id=?1",
            params![eid, new],
        )?;
    } else {
        let text = text(args)?;
        if text.is_empty() || before["text"] == text {
            return Err(Error::invalid(
                "The replacement text must change the record",
            ));
        }
        after["text"] = json!(text);
        c.execute(
            "UPDATE ledger_work_events SET text=?2 WHERE id=?1",
            params![eid, text],
        )?;
    }
    history(
        c,
        project,
        (before["item"].as_str(), Some(eid)),
        kind,
        after["date"].as_str().unwrap_or(""),
        (&before, &after),
        now,
    )?;
    Ok(json!({"project":project,"eventId":eid,"event":after}))
}

fn edit_item(
    c: &Connection,
    project: &str,
    before: &Value,
    args: &Value,
    kind: &str,
    now: i64,
) -> Result<Value> {
    let (date, _) = date(args, false)?;
    let id = before["id"].as_str().unwrap_or_default();
    let mut after = before.clone();
    if kind == "stem" {
        let stem = args
            .get("stem")
            .or_else(|| args.get("g"))
            .and_then(Value::as_str)
            .ok_or_else(|| Error::invalid("stem is required; an empty string removes it"))?;
        after["stem"] = json!(limited(clean(stem).unwrap_or_default(), "stem", 100)?);
    } else {
        for (key, names, max) in [
            ("title", vec!["title", "t"], 500),
            ("output", vec!["output", "out"], 2000),
        ] {
            if names.iter().any(|name| args.get(*name).is_some()) {
                after[key] = json!(limited(
                    arg_str_any(args, &names).unwrap_or_default(),
                    key,
                    max
                )?);
            }
        }
        if args.get("scope").is_some() {
            after["scope"] = json!(list_of(&args["scope"]));
        }
        if after["title"].as_str().unwrap_or("").is_empty() {
            return Err(Error::invalid("A work item needs a title"));
        }
    }
    if after == *before {
        return Err(Error::invalid("No work metadata changed"));
    }
    c.execute(
        "UPDATE ledger_work_items SET title=?2,output=?3,scope=?4,stem=?5 WHERE id=?1",
        params![
            id,
            after["title"].as_str(),
            after["output"].as_str(),
            after["scope"].to_string(),
            after["stem"].as_str()
        ],
    )?;
    history(
        c,
        project,
        (Some(id), None),
        kind,
        &date,
        (before, &after),
        now,
    )?;
    if kind == "stem" {
        let current: String = c.query_row("SELECT json_extract(after_value,'$.stem') FROM ledger_work_history WHERE item=?1 AND action='stem' ORDER BY date DESC,id DESC LIMIT 1",[id],|r|r.get(0))?;
        c.execute(
            "UPDATE ledger_work_items SET stem=?2 WHERE id=?1",
            params![id, current],
        )?;
        after = load_item(c, project, id)?;
    }
    Ok(json!({"project":project,"item":after}))
}

fn move_event(
    c: &Connection,
    project: &str,
    item: &Value,
    args: &Value,
    now: i64,
) -> Result<Value> {
    let before = target(c, project, args, "date")?;
    if matches!(
        before["event"].as_str(),
        Some("registered" | "transfer" | "carry")
    ) || !before["data"]["carriedTo"].is_null()
        || !before["data"]["originDate"].is_null()
    {
        return Err(Error::invalid(
            "Registration, transfer and carried records cannot move",
        ));
    }
    let to = required(args, &["to"])?;
    let destination = load_item(c, project, &to)?;
    if item["id"] == to {
        return Err(Error::invalid("Select a different destination item"));
    }
    let eid = before["id"].as_i64().unwrap_or_default();
    let mut after = before.clone();
    after["item"] = json!(to);
    after["bundle"] = destination["bundle"].clone();
    c.execute(
        "UPDATE ledger_work_events SET item=?2,bundle=?3 WHERE id=?1",
        params![eid, to, destination["bundle"].as_str()],
    )?;
    history(
        c,
        project,
        (item["id"].as_str(), Some(eid)),
        "move",
        before["date"].as_str().unwrap_or(""),
        (&before, &after),
        now,
    )?;
    Ok(json!({"project":project,"eventId":eid,"item":to}))
}

fn carry(c: &Connection, project: &str, item: &Value, args: &Value, now: i64) -> Result<Value> {
    let (date, _) = date(args, false)?;
    let mut selector = args.clone();
    if let Some(original) = args.get("originalDate") {
        selector["date"] = original.clone();
    }
    let before = target(
        c,
        project,
        &selector,
        if args.get("originalDate").is_some() {
            "date"
        } else {
            ""
        },
    )?;
    if !matches!(before["event"].as_str(), Some("issue" | "progress"))
        || !before["data"]["carriedTo"].is_null()
    {
        return Err(Error::invalid(
            "Carry an issue or progress record that has not already moved forward",
        ));
    }
    let to = required(args, &["to"])?;
    let destination = load_item(c, project, &to)?;
    if item["id"] == to {
        return Err(Error::invalid("A carry needs a different destination item"));
    }
    if before["date"].as_str().unwrap_or("") > date.as_str() {
        return Err(Error::invalid("A carry cannot precede its original record"));
    }
    let count = before["data"]["carryCount"].as_i64().unwrap_or(0) + 1;
    let origin = before["data"]["originDate"]
        .as_str()
        .unwrap_or_else(|| before["date"].as_str().unwrap_or(""));
    let text = text(args)?;
    if text.is_empty() {
        return Err(Error::invalid("A carry needs the current state and reason"));
    }
    let mut data = before["data"].clone();
    data["carriedTo"] = json!(to);
    c.execute(
        "UPDATE ledger_work_events SET data=?2 WHERE id=?1",
        params![before["id"].as_i64(), data.to_string()],
    )?;
    let carry = insert_event(
        c,
        &json!({"project":project,"item":item["id"],"bundle":item["bundle"],"event":"carry","date":date,"text":text,"refs":refs(args),"data":{"to":to,"eventId":before["id"],"originDate":origin,"carryCount":count}}),
        now,
    )?;
    let received = insert_event(
        c,
        &json!({"project":project,"item":to,"bundle":destination["bundle"],"event":"issue","date":date,"text":before["text"],"refs":before["refs"],"data":{"from":item["id"],"originDate":origin,"carryCount":count,"carryEvent":carry}}),
        now,
    )?;
    Ok(json!({"project":project,"eventId":carry,"receivedEventId":received,"carryCount":count}))
}

fn skip(c: &Connection, project: &str, args: &Value, now: i64) -> Result<Value> {
    let (date, _) = date(args, false)?;
    let text = text(args)?;
    if text.is_empty() {
        return Err(Error::invalid("A skipped record needs a reason"));
    }
    let refs = refs(args);
    let ids: Vec<i64> = refs
        .iter()
        .filter_map(|r| {
            r.trim_start_matches('#')
                .strip_prefix('E')
                .and_then(|v| v.parse().ok())
        })
        .collect();
    if ids.is_empty() {
        return Err(Error::invalid(
            "refs must contain at least one session event such as E123",
        ));
    }
    for eid in &ids {
        let eligible: bool = c.query_row("SELECT EXISTS(SELECT 1 FROM events WHERE id=?1 AND project=?2 AND type IN ('release','applied','decision','done'))",params![eid,project],|r|r.get(0))?;
        if !eligible {
            return Err(Error::invalid(format!(
                "E{eid} is not an assignable session event in this project"
            )));
        }
        let linked: bool = c.query_row("SELECT EXISTS(SELECT 1 FROM ledger_work_events e,json_each(e.refs) r WHERE e.project=?1 AND (r.value=?2 OR r.value=?3) UNION ALL SELECT 1 FROM ledger_work_links WHERE project=?1 AND event_id=?4)",params![project,format!("E{eid}"),format!("#E{eid}"),eid],|r|r.get(0))?;
        if linked {
            return Err(Error::conflict(format!(
                "E{eid} is already assigned to work"
            )));
        }
    }
    for eid in &ids {
        c.execute("INSERT INTO ledger_work_marks(project,event_id,date,reason,created_at) VALUES (?1,?2,?3,?4,?5) ON CONFLICT(project,event_id) DO UPDATE SET date=excluded.date,reason=excluded.reason,created_at=excluded.created_at",params![project,eid,date,text,now])?;
    }
    Ok(json!({"project":project,"skipped":ids}))
}
