use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
pub struct Commit {
    pub id: String,
    pub parents: Vec<String>,
}

pub trait Node {
    type Id: Clone + Eq;
    fn id(&self) -> &Self::Id;
    fn parents(&self) -> &[Self::Id];
    fn wip(&self) -> bool;
}
impl Node for Commit {
    type Id = String;
    fn id(&self) -> &String {
        &self.id
    }
    fn parents(&self) -> &[String] {
        &self.parents
    }
    fn wip(&self) -> bool {
        self.id == "__WORKING_TREE__"
    }
}
struct NumericCommit {
    id: u32,
    parents: Vec<u32>,
    wip: bool,
}
impl Node for NumericCommit {
    type Id = u32;
    fn id(&self) -> &u32 {
        &self.id
    }
    fn parents(&self) -> &[u32] {
        &self.parents
    }
    fn wip(&self) -> bool {
        self.wip
    }
}

#[derive(Serialize)]
pub struct Segment {
    x1: usize,
    y1: f64,
    x2: usize,
    y2: f64,
    color: usize,
    dashed: bool,
}

#[derive(Serialize)]
pub struct Row {
    column: usize,
    color: usize,
    segments: Vec<Segment>,
    width: usize,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Layout {
    rows: Vec<Row>,
    max_lanes: usize,
}

#[derive(Clone)]
struct Lane<Id> {
    expected: Id,
    color: usize,
    dashed: bool,
}

fn slot<Id>(lanes: &mut Vec<Option<Lane<Id>>>, excluding: Option<usize>) -> usize {
    if let Some(i) = lanes
        .iter()
        .enumerate()
        .position(|(i, lane)| lane.is_none() && Some(i) != excluding)
    {
        i
    } else {
        lanes.push(None);
        lanes.len() - 1
    }
}

/// 화면은 선을 그리기만 하고 레인·색·머지 연결은 두 플랫폼에서 같은 결과를 쓴다.
pub fn layout<C: Node>(commits: &[C]) -> Layout {
    let mut lanes: Vec<Option<Lane<C::Id>>> = Vec::new();
    let mut next_color = 0;
    let mut rows = Vec::with_capacity(commits.len());
    let mut max_lanes = 1;
    for c in commits {
        let before_len = lanes.len();
        let col = lanes
            .iter()
            .position(|l| l.as_ref().is_some_and(|l| &l.expected == c.id()));
        let (col, color) = match col {
            Some(i) => (i, lanes[i].as_ref().unwrap().color),
            None => {
                let i = slot(&mut lanes, None);
                let color = next_color;
                next_color += 1;
                (i, color)
            }
        };
        let mut segments = Vec::with_capacity(lanes.len() + c.parents().len());
        // 복사한 레인 스냅샷 대신 기존 슬롯을 읽은 뒤 비운다.
        for (i, lane) in lanes.iter_mut().enumerate() {
            if let Some(l) = lane {
                let joins = &l.expected == c.id();
                segments.push(Segment {
                    x1: i,
                    y1: 0.0,
                    x2: if joins { col } else { i },
                    y2: if joins { 0.5 } else { 1.0 },
                    color: l.color,
                    dashed: l.dashed,
                });
                if joins {
                    *lane = None;
                }
            }
        }
        if let Some(first) = c.parents().first() {
            let dashed = c.wip();
            lanes[col] = Some(Lane {
                expected: first.clone(),
                color,
                dashed,
            });
            segments.push(Segment {
                x1: col,
                y1: 0.5,
                x2: col,
                y2: 1.0,
                color,
                dashed,
            });
            for parent in c.parents().iter().skip(1) {
                let (j, parent_color) = if let Some(j) = lanes
                    .iter()
                    .position(|l| l.as_ref().is_some_and(|l| &l.expected == parent))
                {
                    (j, lanes[j].as_ref().unwrap().color)
                } else {
                    let j = slot(&mut lanes, Some(col));
                    let parent_color = next_color;
                    next_color += 1;
                    lanes[j] = Some(Lane {
                        expected: parent.clone(),
                        color: parent_color,
                        dashed: false,
                    });
                    (j, parent_color)
                };
                segments.push(Segment {
                    x1: col,
                    y1: 0.5,
                    x2: j,
                    y2: 1.0,
                    color: parent_color,
                    dashed: false,
                });
            }
        }
        while lanes.last().is_some_and(Option::is_none) {
            lanes.pop();
        }
        let width = before_len.max(lanes.len()).max(col + 1);
        max_lanes = max_lanes.max(width);
        rows.push(Row {
            column: col,
            color,
            segments,
            width,
        });
    }
    Layout { rows, max_lanes }
}

/// 레인 데이터는 정수 버퍼로 전달해 큰 JSON 객체 생성·파싱을 피한다.
pub fn compact(bytes: &[u8]) -> Result<Vec<u8>, String> {
    if !bytes.len().is_multiple_of(4) {
        return Err("Invalid graph buffer".into());
    }
    let words: Vec<u32> = bytes
        .as_chunks::<4>()
        .0
        .iter()
        .map(|b| u32::from_le_bytes(*b))
        .collect();
    let mut cursor = 0;
    fn next(words: &[u32], cursor: &mut usize) -> Result<u32, String> {
        let n = *words.get(*cursor).ok_or("Incomplete graph buffer")?;
        *cursor += 1;
        Ok(n)
    }
    let count = next(&words, &mut cursor)? as usize;
    if count > 1_000_000 || count > words.len() / 3 {
        return Err("Invalid graph count".into());
    }
    let mut commits = Vec::with_capacity(count);
    for _ in 0..count {
        let id = next(&words, &mut cursor)?;
        let wip = next(&words, &mut cursor)? != 0;
        let n = next(&words, &mut cursor)? as usize;
        let end = cursor.checked_add(n).ok_or("Invalid parent count")?;
        let parents = words.get(cursor..end).ok_or("Incomplete parents")?.to_vec();
        cursor = end;
        commits.push(NumericCommit { id, parents, wip });
    }
    if cursor != words.len() {
        return Err("Unexpected graph data".into());
    }
    let layout = layout(&commits);
    let mut output = Vec::new();
    let mut push = |n: u32| output.extend_from_slice(&n.to_le_bytes());
    push(layout.rows.len() as u32);
    push(layout.max_lanes as u32);
    for row in layout.rows {
        push(row.column as u32);
        push(row.color as u32);
        push(row.width as u32);
        push(row.segments.len() as u32);
        for s in row.segments {
            push(s.x1 as u32);
            push((s.y1 * 2.0) as u32);
            push(s.x2 as u32);
            push((s.y2 * 2.0) as u32);
            push(s.color as u32);
            push(u32::from(s.dashed));
        }
    }
    Ok(output)
}
