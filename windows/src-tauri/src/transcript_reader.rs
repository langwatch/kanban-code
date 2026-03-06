use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, BufReader};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContentBlock {
    pub kind: String,
    pub text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Turn {
    pub index: usize,
    pub role: String,
    pub text_preview: String,
    pub timestamp: Option<String>,
    pub content_blocks: Vec<ContentBlock>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptPage {
    pub turns: Vec<Turn>,
    pub total_turns: usize,
    pub has_more: bool,
    pub next_offset: usize,
}

const PAGE_SIZE: usize = 20;

/// Read conversation turns from a JSONL file with pagination.
pub async fn read_transcript(file_path: &str, offset: usize) -> Result<TranscriptPage> {
    let path = std::path::Path::new(file_path);
    if !path.exists() {
        return Ok(TranscriptPage {
            turns: vec![],
            total_turns: 0,
            has_more: false,
            next_offset: 0,
        });
    }

    let file = tokio::fs::File::open(path).await?;
    let reader = BufReader::new(file);
    let mut lines = reader.lines();

    let mut all_turns: Vec<Turn> = Vec::new();
    let mut turn_index = 0;

    while let Some(line) = lines.next_line().await? {
        if line.is_empty() {
            continue;
        }
        let obj: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(_) => continue,
        };

        let msg_type = obj["type"].as_str().unwrap_or("");
        if msg_type != "user" && msg_type != "assistant" {
            continue;
        }

        let timestamp = obj["timestamp"].as_str().map(|s| s.to_string());
        let content_blocks = parse_content_blocks(&obj);
        let text_preview: String = content_blocks
            .iter()
            .filter(|b| b.kind == "text")
            .map(|b| b.text.as_str())
            .collect::<Vec<_>>()
            .join(" ")
            .chars()
            .take(200)
            .collect();

        all_turns.push(Turn {
            index: turn_index,
            role: msg_type.to_string(),
            text_preview,
            timestamp,
            content_blocks,
        });
        turn_index += 1;
    }

    let total_turns = all_turns.len();
    let page: Vec<Turn> = all_turns
        .into_iter()
        .skip(offset)
        .take(PAGE_SIZE)
        .collect();
    let has_more = offset + PAGE_SIZE < total_turns;

    Ok(TranscriptPage {
        total_turns,
        has_more,
        next_offset: if has_more { offset + PAGE_SIZE } else { total_turns },
        turns: page,
    })
}

fn parse_content_blocks(obj: &Value) -> Vec<ContentBlock> {
    let mut blocks = Vec::new();
    let content = match obj["message"]["content"].as_array() {
        Some(c) => c,
        None => {
            // Content might be a plain string
            if let Some(text) = obj["message"]["content"].as_str() {
                blocks.push(ContentBlock {
                    kind: "text".to_string(),
                    text: text.to_string(),
                });
            }
            return blocks;
        }
    };

    for block in content {
        let kind = block["type"].as_str().unwrap_or("text");
        match kind {
            "text" => {
                let text = block["text"].as_str().unwrap_or("").to_string();
                blocks.push(ContentBlock {
                    kind: "text".to_string(),
                    text,
                });
            }
            "tool_use" => {
                let name = block["name"].as_str().unwrap_or("tool");
                let input = block["input"].to_string();
                blocks.push(ContentBlock {
                    kind: "tool_use".to_string(),
                    text: format!("{}: {}", name, input),
                });
            }
            "tool_result" => {
                let content_text = block["content"]
                    .as_str()
                    .or_else(|| block["content"][0]["text"].as_str())
                    .unwrap_or("")
                    .to_string();
                blocks.push(ContentBlock {
                    kind: "tool_result".to_string(),
                    text: content_text,
                });
            }
            "thinking" => {
                blocks.push(ContentBlock {
                    kind: "thinking".to_string(),
                    text: block["thinking"].as_str().unwrap_or("").to_string(),
                });
            }
            _ => {}
        }
    }

    blocks
}
