//! `kanban` — channel-coordination CLI for tmux sessions.
//!
//! Speaks the same on-disk format as the Tauri app and the macOS Swift app:
//!   `<kanban_data_dir>/channels/channels.json`
//!   `<kanban_data_dir>/channels/<name>.jsonl`
//!   `<kanban_data_dir>/channels/dm/<keyA>__<keyB>.jsonl`
//!
//! Scope is intentionally narrow per issue #104: channels + DMs. Slack bridge,
//! markdown export, image paste, and tmux fanout are NOT here — those live in
//! the TS CLI under `cli/`.

use clap::{ArgAction, Args, Parser, Subcommand};
use kanban_code_lib::channels::{normalize_channel_name, ChannelParticipant};
use kanban_code_lib::channels_store::ChannelsStore;
use std::process::ExitCode;

#[derive(Parser)]
#[command(
    name = "kanban",
    version,
    about = "Kanban Code CLI — channel coordination (Windows port)"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Chat channels (room-visible, multi-member)
    #[command(subcommand)]
    Channel(ChannelCmd),
    /// Direct messages between two parties
    #[command(subcommand)]
    Dm(DmCmd),
    /// Print the resolved caller identity (debug)
    Handle(IdentityOpts),
}

#[derive(Subcommand)]
enum ChannelCmd {
    /// List channels with member count
    List {
        #[arg(short, long)]
        json: bool,
    },
    /// Create a new channel (auto-joins the caller)
    Create {
        /// Channel name — `[a-z0-9][a-z0-9_-]{0,63}`
        name: String,
        #[command(flatten)]
        ident: IdentityOpts,
        #[arg(short, long)]
        json: bool,
    },
    /// Join a channel and print recent messages
    Join {
        name: String,
        #[command(flatten)]
        ident: IdentityOpts,
        /// Number of recent messages to show after joining
        #[arg(short = 'n', long, default_value_t = 10)]
        tail: usize,
        #[arg(short, long)]
        json: bool,
    },
    /// Leave a channel
    Leave {
        name: String,
        #[command(flatten)]
        ident: IdentityOpts,
        #[arg(short, long)]
        json: bool,
    },
    /// List the members of a channel
    Members {
        name: String,
        #[arg(short, long)]
        json: bool,
    },
    /// Send a message to a channel
    Send {
        name: String,
        #[command(flatten)]
        ident: IdentityOpts,
        #[arg(short, long)]
        json: bool,
        /// Attach an image. Repeat to attach multiple. Missing files print
        /// a warning and are skipped (matches the persist_images lenient
        /// behavior).
        #[arg(short = 'i', long = "image", value_name = "PATH", action = ArgAction::Append)]
        images: Vec<String>,
        /// Message body — joined with single spaces. Quote multi-word
        /// messages, or put any flags BEFORE the message words.
        #[arg(required = true)]
        message: Vec<String>,
    },
    /// Show the last N messages of a channel
    History {
        name: String,
        #[arg(short = 'n', long, default_value_t = 20)]
        tail: usize,
        #[arg(short, long)]
        json: bool,
    },
    /// Delete a channel (removes the room and its history)
    Delete {
        name: String,
        #[arg(short, long)]
        json: bool,
    },
    /// Rename a channel — preserves history
    Rename {
        old: String,
        new: String,
        #[arg(short, long)]
        json: bool,
    },
    /// Edit a previously-sent message. Appends an Edit row; render layer
    /// collapses it into the original message body (#113).
    Edit {
        name: String,
        message_id: String,
        #[command(flatten)]
        ident: IdentityOpts,
        #[arg(short, long)]
        json: bool,
        #[arg(required = true)]
        body: Vec<String>,
    },
    /// Soft-delete a message — append a Delete row (#113).
    DeleteMsg {
        name: String,
        message_id: String,
        #[command(flatten)]
        ident: IdentityOpts,
        #[arg(short, long)]
        json: bool,
    },
    /// Add (or toggle off) an emoji reaction on a message (#113).
    React {
        name: String,
        message_id: String,
        emoji: String,
        #[command(flatten)]
        ident: IdentityOpts,
        #[arg(short, long)]
        json: bool,
    },
}

#[derive(Subcommand)]
enum DmCmd {
    /// Send a DM. Target is either a card id (`card_abc`) or `@handle`.
    Send {
        to: String,
        #[command(flatten)]
        ident: IdentityOpts,
        #[arg(short, long)]
        json: bool,
        /// Attach an image. Repeat to attach multiple. Missing files print
        /// a warning and are skipped.
        #[arg(short = 'i', long = "image", value_name = "PATH", action = ArgAction::Append)]
        images: Vec<String>,
        /// Message body — joined with single spaces. Quote multi-word
        /// messages, or put any flags BEFORE the message words.
        #[arg(required = true)]
        message: Vec<String>,
    },
    /// Read a DM thread.
    Read {
        other: String,
        #[command(flatten)]
        ident: IdentityOpts,
        #[arg(short = 'n', long, default_value_t = 20)]
        tail: usize,
        #[arg(short, long)]
        json: bool,
    },
    /// List the DM threads the caller participates in.
    List {
        #[arg(short, long)]
        json: bool,
    },
    /// Edit a DM message (#113).
    Edit {
        other: String,
        message_id: String,
        #[command(flatten)]
        ident: IdentityOpts,
        #[arg(short, long)]
        json: bool,
        #[arg(required = true)]
        body: Vec<String>,
    },
    /// Soft-delete a DM message (#113).
    DeleteMsg {
        other: String,
        message_id: String,
        #[command(flatten)]
        ident: IdentityOpts,
        #[arg(short, long)]
        json: bool,
    },
    /// React to a DM message with an emoji (#113).
    React {
        other: String,
        message_id: String,
        emoji: String,
        #[command(flatten)]
        ident: IdentityOpts,
        #[arg(short, long)]
        json: bool,
    },
}

/// Caller-identity flags. Mirrors the TS CLI:
///   `--as <handle>` / `--as-card-id <id>` / `--as-user`
/// Environment fallback: `KANBAN_HANDLE` and `KANBAN_CARD_ID`.
#[derive(Args, Clone, Default)]
struct IdentityOpts {
    /// Act as this handle
    #[arg(long = "as", value_name = "HANDLE")]
    as_handle: Option<String>,
    /// Explicit card id for the --as handle
    #[arg(long = "as-card-id", value_name = "ID")]
    as_card_id: Option<String>,
    /// Act as the human user (cardId=null, handle="user")
    #[arg(long = "as-user", default_value_t = false)]
    as_user: bool,
}

fn resolve_caller(opts: &IdentityOpts) -> ChannelParticipant {
    if opts.as_user {
        return ChannelParticipant::user("user");
    }
    let handle = opts
        .as_handle
        .clone()
        .or_else(|| std::env::var("KANBAN_HANDLE").ok())
        .unwrap_or_else(|| "user".to_string());
    let card_id = opts
        .as_card_id
        .clone()
        .or_else(|| std::env::var("KANBAN_CARD_ID").ok());
    ChannelParticipant { card_id, handle }
}

/// Pre-validates `--image` paths. Missing files print a warning to stderr
/// and are dropped from the returned list — matches the lenient persist
/// behavior so a typo doesn't fail the send.
fn warn_skipped_images(paths: Vec<String>) -> Vec<String> {
    paths
        .into_iter()
        .filter(|p| {
            let exists = std::path::Path::new(p).exists();
            if !exists {
                eprintln!("kanban: warning: image not found, skipping: {p}");
            }
            exists
        })
        .collect()
}

fn parse_target(s: &str) -> ChannelParticipant {
    if let Some(handle) = s.strip_prefix('@') {
        ChannelParticipant::user(handle)
    } else {
        // Treat bare `card_xyz` as a card. Handle is best-effort — empty if
        // unknown is fine for DM routing (the file name uses cardId only).
        ChannelParticipant {
            card_id: Some(s.to_string()),
            handle: s.to_string(),
        }
    }
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    let store = ChannelsStore::new(None);
    let rt = match tokio::runtime::Runtime::new() {
        Ok(r) => r,
        Err(e) => {
            eprintln!("kanban: failed to start runtime: {e}");
            return ExitCode::from(1);
        }
    };

    let result: anyhow::Result<()> = rt.block_on(async move {
        match cli.command {
            Command::Channel(c) => run_channel(c, &store).await,
            Command::Dm(d) => run_dm(d, &store).await,
            Command::Handle(opts) => {
                let p = resolve_caller(&opts);
                println!("{}", serde_json::to_string_pretty(&p)?);
                Ok(())
            }
        }
    });

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("kanban: {e}");
            ExitCode::from(1)
        }
    }
}

async fn run_channel(cmd: ChannelCmd, store: &ChannelsStore) -> anyhow::Result<()> {
    match cmd {
        ChannelCmd::List { json } => {
            let list = store.list_channels().await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&list)?);
                return Ok(());
            }
            if list.is_empty() {
                println!("No channels yet. Create one: kanban channel create <name>");
                return Ok(());
            }
            for ch in &list {
                println!(
                    "#{:<20} {} member(s)",
                    ch.name,
                    ch.members.len()
                );
            }
            Ok(())
        }
        ChannelCmd::Create { name, ident, json } => {
            let caller = resolve_caller(&ident);
            let clean = normalize_channel_name(&name);
            let ch = store.create_channel(&clean, caller.clone()).await?;
            // Auto-join the creator — matches the TS CLI.
            let _ = store.join_channel(&clean, caller.clone()).await?;
            if json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&serde_json::json!({
                        "channel": ch,
                        "joined": caller,
                    }))?
                );
            } else {
                println!("Created #{} (joined as {})", ch.name, caller.handle);
            }
            Ok(())
        }
        ChannelCmd::Join { name, ident, tail, json } => {
            let caller = resolve_caller(&ident);
            let clean = normalize_channel_name(&name);
            let (channel, already) = store.join_channel(&clean, caller.clone()).await?;
            let tail_msgs = store.read_messages(&clean, Some(tail)).await?;
            if json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&serde_json::json!({
                        "alreadyMember": already,
                        "channel": channel,
                        "tail": tail_msgs,
                    }))?
                );
                return Ok(());
            }
            if already {
                println!("Already a member of #{} as @{}", clean, caller.handle);
            } else {
                println!("Joined #{} as @{}", clean, caller.handle);
            }
            if !tail_msgs.is_empty() {
                println!("\nRecent ({}):", tail_msgs.len());
                for m in &tail_msgs {
                    println!("  @{}: {}", m.from.handle, m.body);
                }
            }
            Ok(())
        }
        ChannelCmd::Leave { name, ident, json } => {
            let caller = resolve_caller(&ident);
            let clean = normalize_channel_name(&name);
            match store.leave_channel(&clean, caller.clone()).await? {
                Some(ch) => {
                    if json {
                        println!(
                            "{}",
                            serde_json::to_string_pretty(&serde_json::json!({ "channel": ch }))?
                        );
                    } else {
                        println!("Left #{}", clean);
                    }
                }
                None => anyhow::bail!("channel '#{}' does not exist", clean),
            }
            Ok(())
        }
        ChannelCmd::Members { name, json } => {
            let clean = normalize_channel_name(&name);
            let channels = store.list_channels().await?;
            let ch = channels
                .into_iter()
                .find(|c| c.name == clean)
                .ok_or_else(|| anyhow::anyhow!("channel '#{}' does not exist", clean))?;
            if json {
                println!("{}", serde_json::to_string_pretty(&ch.members)?);
                return Ok(());
            }
            println!("#{} — {} member(s)", clean, ch.members.len());
            for m in &ch.members {
                println!(
                    "  @{:<24} {}",
                    m.handle,
                    m.card_id.as_deref().unwrap_or("(user)")
                );
            }
            Ok(())
        }
        ChannelCmd::Send { name, message, ident, images, json } => {
            let caller = resolve_caller(&ident);
            let clean = normalize_channel_name(&name);
            // Auto-join on first send so the roster stays in sync.
            let _ = store.join_channel(&clean, caller.clone()).await;
            let body = message.join(" ");
            let kept = warn_skipped_images(images);
            let msg = store
                .send_message(&clean, caller.clone(), body.clone(), kept)
                .await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&msg)?);
            } else {
                println!("@{} → #{}: {}", caller.handle, clean, body);
            }
            Ok(())
        }
        ChannelCmd::History { name, tail, json } => {
            let clean = normalize_channel_name(&name);
            let msgs = store.read_messages(&clean, Some(tail)).await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&msgs)?);
                return Ok(());
            }
            for m in &msgs {
                println!("[{}] @{}: {}", m.ts.to_rfc3339(), m.from.handle, m.body);
            }
            Ok(())
        }
        ChannelCmd::Delete { name, json } => {
            let clean = normalize_channel_name(&name);
            let removed = store.delete_channel(&clean).await?;
            if json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&serde_json::json!({
                        "deleted": removed,
                        "channel": clean,
                    }))?
                );
                return Ok(());
            }
            if removed {
                println!("Deleted #{}", clean);
            } else {
                anyhow::bail!("channel '#{}' does not exist", clean);
            }
            Ok(())
        }
        ChannelCmd::Edit { name, message_id, ident, json, body } => {
            let caller = resolve_caller(&ident);
            let clean = normalize_channel_name(&name);
            let new_body = body.join(" ");
            let msg = store
                .edit_channel_message(&clean, &message_id, caller.clone(), new_body.clone())
                .await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&msg)?);
            } else {
                println!("edited {} in #{}: {}", message_id, clean, new_body);
            }
            Ok(())
        }
        ChannelCmd::DeleteMsg { name, message_id, ident, json } => {
            let caller = resolve_caller(&ident);
            let clean = normalize_channel_name(&name);
            let msg = store
                .delete_channel_message(&clean, &message_id, caller.clone())
                .await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&msg)?);
            } else {
                println!("deleted {} in #{}", message_id, clean);
            }
            Ok(())
        }
        ChannelCmd::React { name, message_id, emoji, ident, json } => {
            let caller = resolve_caller(&ident);
            let clean = normalize_channel_name(&name);
            let msg = store
                .react_channel_message(&clean, &message_id, caller.clone(), emoji.clone())
                .await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&msg)?);
            } else {
                println!("@{} reacted {} on {} in #{}", caller.handle, emoji, message_id, clean);
            }
            Ok(())
        }
        ChannelCmd::Rename { old, new, json } => {
            let renamed = store.rename_channel(&old, &new).await?;
            if json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&serde_json::json!({
                        "renamed": renamed,
                        "from": normalize_channel_name(&old),
                        "to": normalize_channel_name(&new),
                    }))?
                );
                return Ok(());
            }
            if renamed {
                println!(
                    "Renamed #{} → #{}",
                    normalize_channel_name(&old),
                    normalize_channel_name(&new)
                );
            } else {
                anyhow::bail!(
                    "rename failed (source '#{}' missing, target name '#{}' invalid, or names equal)",
                    normalize_channel_name(&old),
                    normalize_channel_name(&new)
                );
            }
            Ok(())
        }
    }
}

async fn run_dm(cmd: DmCmd, store: &ChannelsStore) -> anyhow::Result<()> {
    match cmd {
        DmCmd::Send { to, message, ident, images, json } => {
            let from = resolve_caller(&ident);
            let target = parse_target(&to);
            let body = message.join(" ");
            let kept = warn_skipped_images(images);
            let msg = store
                .send_dm(from.clone(), target.clone(), body.clone(), kept)
                .await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&msg)?);
            } else {
                println!("@{} → {}: {}", from.handle, to, body);
            }
            Ok(())
        }
        DmCmd::Read { other, ident, tail, json } => {
            // Resolve identity from --as / env / fallback. If nothing was given
            // AND the env vars are unset, refuse — we'd silently read the wrong
            // thread (orchestration footgun).
            let env_handle = std::env::var("KANBAN_HANDLE").ok();
            let env_card = std::env::var("KANBAN_CARD_ID").ok();
            let ambient = !ident.as_user
                && ident.as_handle.is_none()
                && ident.as_card_id.is_none()
                && env_handle.is_none()
                && env_card.is_none();
            if ambient {
                anyhow::bail!(
                    "dm read: caller identity is ambient — pass --as <handle> / --as-card-id <id> / --as-user, or set KANBAN_HANDLE / KANBAN_CARD_ID. Refusing rather than silently reading the user thread."
                );
            }
            let me = resolve_caller(&ident);
            let target = parse_target(&other);
            let msgs = store
                .read_dm_messages(&me, &target, Some(tail))
                .await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&msgs)?);
                return Ok(());
            }
            for m in &msgs {
                println!("[{}] @{}: {}", m.ts.to_rfc3339(), m.from.handle, m.body);
            }
            Ok(())
        }
        DmCmd::Edit { other, message_id, ident, json, body } => {
            let me = resolve_caller(&ident);
            let target = parse_target(&other);
            let new_body = body.join(" ");
            let msg = store
                .edit_dm_message(&me, &target, &message_id, me.clone(), new_body.clone())
                .await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&msg)?);
            } else {
                println!("edited {} in dm with {}: {}", message_id, other, new_body);
            }
            Ok(())
        }
        DmCmd::DeleteMsg { other, message_id, ident, json } => {
            let me = resolve_caller(&ident);
            let target = parse_target(&other);
            let msg = store
                .delete_dm_message(&me, &target, &message_id, me.clone())
                .await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&msg)?);
            } else {
                println!("deleted {} in dm with {}", message_id, other);
            }
            Ok(())
        }
        DmCmd::React { other, message_id, emoji, ident, json } => {
            let me = resolve_caller(&ident);
            let target = parse_target(&other);
            let msg = store
                .react_dm_message(&me, &target, &message_id, me.clone(), emoji.clone())
                .await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&msg)?);
            } else {
                println!("@{} reacted {} on {} in dm with {}", me.handle, emoji, message_id, other);
            }
            Ok(())
        }
        DmCmd::List { json } => {
            let pairs = store.list_dm_pairs().await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&pairs)?);
                return Ok(());
            }
            if pairs.is_empty() {
                println!("No DM threads yet.");
                return Ok(());
            }
            for p in &pairs {
                println!("{p}");
            }
            Ok(())
        }
    }
}
