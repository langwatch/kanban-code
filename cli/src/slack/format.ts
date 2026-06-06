/// Formats Claude Code transcript (.jsonl) lines into Slack messages, porting
/// the rendering lessons from Kanban Code's chat view (TranscriptReader):
/// compact tool labels, summarized results.

export interface SlackPost {
  role: "assistant" | "user";
  /// "text"     -> assistant or user prose (lands in the channel root and
  ///               becomes the new thread anchor for following tool calls).
  /// "tool"     -> a tool_use / shell-exec block (lands in the thread under
  ///               the most recent text post; consecutive ones coalesce).
  /// "thinking" -> a brief thinking-trace excerpt (also lands in the thread).
  kind: "text" | "tool" | "thinking";
  text: string; // Slack mrkdwn
  /// True when this post is the final output of the turn — no more work is
  /// coming. The bridge uses this to suppress the "is working…" pill that
  /// would otherwise sit on the channel indefinitely. Set on the codex
  /// out-of-credits sentinel AND on the final assistant text post of any
  /// normal codex turn (when task_complete lands in the same poll batch).
  terminal?: boolean;
}

const MAX_TEXT = 2800; // keep individual posts readable / within Slack block limits

function truncate(s: string, max = MAX_TEXT): string {
  const t = s.trim();
  return t.length > max ? t.slice(0, max) + "…" : t;
}

/// Header shown above each mirrored prompt. It marks the text as the input the
/// agent received (not the agent's own reply), so a reader can tell the two
/// apart in the channel.
export const RECEIVED_MESSAGE_HEADER = ">>> Received user message";

/// Format an injected prompt for the channel: the header, then the body in
/// italics (Slack mrkdwn uses _underscores_ for italic; * and ** do not work).
export function formatReceivedMessage(text: string): string {
  return `${RECEIVED_MESSAGE_HEADER}\n\n_${text}_`;
}

/// Keep the last 3 path components (mirrors TranscriptReader.shortenPath).
export function shortenPath(path: string): string {
  const parts = path.split("/").filter(Boolean);
  if (parts.length <= 3) return path;
  return ".../" + parts.slice(-3).join("/");
}

/// Compact one-line label for a tool_use block (mirrors extractToolInfo +
/// the special-tool cases of parseToolUse).
export function toolLabel(name: string, input: Record<string, any> = {}): string {
  switch (name) {
    case "Bash": {
      const display = input.description || String(input.command ?? "").slice(0, 200);
      return `Bash(${display})`;
    }
    case "Read":
    case "Write":
    case "Edit":
    case "NotebookEdit":
      return `${name}(${shortenPath(String(input.file_path ?? ""))})`;
    case "Grep": {
      const pathPart = input.path ? ` in ${shortenPath(String(input.path))}` : "";
      return `Grep("${input.pattern ?? ""}"${pathPart})`;
    }
    case "Glob":
      return `Glob(${input.pattern ?? ""})`;
    case "Agent":
      return `Agent(${input.description || String(input.prompt ?? "").slice(0, 80)})`;
    case "Skill":
      return `Skill(${input.skill ?? ""})`;
    case "TaskCreate":
      return `TaskCreate(${input.subject ?? ""})`;
    case "TaskUpdate":
      return `TaskUpdate(${input.status ? `${input.taskId}: ${input.status}` : input.taskId ?? ""})`;
    case "EnterPlanMode":
      return "📋 entered plan mode";
    case "ExitPlanMode":
      return `📋 exit plan mode${input.plan ? `\n${truncate(String(input.plan), 1500)}` : ""}`;
    case "AskUserQuestion": {
      const qs = (input.questions ?? []).map((q: any) => `• ${q.question}`).join("\n");
      return `❓ asking:\n${qs}`;
    }
    default:
      return `${name}(…)`;
  }
}

/// Tools whose label is emoji-prefixed prose (status / plan / questions), not a
/// command. These render as plain text; everything else is a command-style
/// label shown in a fenced code block.
const PROSE_TOOLS = new Set(["EnterPlanMode", "ExitPlanMode", "AskUserQuestion"]);

/// Wrap a command-style tool label in a triple-backtick code block.
function fenceBlock(label: string): string {
  return "```\n" + label + "\n```";
}

function role(obj: any): string | undefined {
  return obj?.type ?? obj?.message?.role;
}

/// Emit one SlackPost per content block on an assistant turn. Each block keeps
/// its own kind so the bridge can route it correctly (text -> channel root and
/// new thread anchor, tool/thinking -> thread under the previous text).
function emitAssistantBlocks(content: any, out: SlackPost[]): void {
  if (typeof content === "string") {
    const t = truncate(content);
    if (t) out.push({ role: "assistant", kind: "text", text: t });
    return;
  }
  if (!Array.isArray(content)) return;
  for (const block of content) {
    switch (block?.type) {
      case "text": {
        if (block.text?.trim()) out.push({ role: "assistant", kind: "text", text: truncate(block.text) });
        break;
      }
      case "thinking": {
        if (block.thinking?.trim()) {
          out.push({ role: "assistant", kind: "thinking", text: `💭 _${truncate(block.thinking, 280)}_` });
        }
        break;
      }
      case "tool_use": {
        const label = toolLabel(block.name, block.input ?? {});
        const text = PROSE_TOOLS.has(block.name) ? label : fenceBlock(label);
        out.push({ role: "assistant", kind: "tool", text });
        break;
      }
      default:
        break;
    }
  }
}

/// Coalesce consecutive tool posts (same role) into a single post so a batch
/// of N parallel/sequential tool_use blocks turns into ONE Slack message in the
/// thread instead of N. Cuts API call volume — Slack's "high volume of
/// activity, not displaying some messages" rate-limit kicks in fast otherwise.
/// Text and thinking posts are NOT coalesced (text anchors a new thread, and
/// thinking-as-italic-quote doesn't merge cleanly).
function coalesceTools(posts: SlackPost[]): SlackPost[] {
  const out: SlackPost[] = [];
  for (const p of posts) {
    const last = out[out.length - 1];
    if (p.kind === "tool" && last?.kind === "tool" && last.role === p.role) {
      last.text = last.text + "\n" + p.text;
    } else {
      out.push({ ...p });
    }
  }
  return out;
}

/// Convert a batch of transcript lines into Slack posts. User turns and
/// tool_result lines are skipped: relayed human messages already appear in
/// Slack as that human's own message, and automated prompts are announced
/// separately by the daemon.
export function formatTranscriptLines(objs: any[]): SlackPost[] {
  const posts: SlackPost[] = [];
  for (const obj of objs) {
    if (role(obj) !== "assistant") continue;
    emitAssistantBlocks(obj.message?.content ?? obj.content, posts);
  }
  return coalesceTools(posts);
}

/// Format Codex rollout (.jsonl) records into Slack posts. Codex logs a stream
/// of records; we mirror the prompts the agent receives (user_message), the
/// agent's own messages (its "movement"), and the commands it runs, skipping
/// reasoning/system noise so the channel reads like the Claude mirror. Codex
/// gates command hooks behind a trust prompt, so this rollout tail is also how
/// a received prompt is announced (the Claude path uses the UserPromptSubmit
/// hook). Event shapes: event_msg{payload:{type:"user_message",message}} for an
/// injected prompt, {type:"agent_message",message} for assistant text, and
/// {type:"exec_command_begin",command} for shell runs. When Codex is out of
/// credits the turn ends with task_complete{last_agent_message:null} and the
/// preceding token_count carries rate_limits.credits.has_credits=false; we
/// mirror that as an explicit warning so the channel does not sit on a bare
/// "Received user message" with no explanation.
export function formatCodexRolloutLines(objs: any[]): SlackPost[] {
  const posts: SlackPost[] = [];
  let credits: { has_credits?: boolean; balance?: string } | undefined;
  let planType: string | undefined;
  for (const o of objs) {
    if (o?.type !== "event_msg") continue;
    const p = o.payload ?? {};
    if (p.type === "user_message" && typeof p.message === "string" && p.message.trim()) {
      posts.push({ role: "user", kind: "text", text: formatReceivedMessage(truncate(p.message)) });
    } else if (p.type === "agent_message" && typeof p.message === "string" && p.message.trim()) {
      posts.push({ role: "assistant", kind: "text", text: truncate(p.message) });
    } else if (p.type === "exec_command_begin") {
      const cmd = Array.isArray(p.command) ? p.command.join(" ") : String(p.command ?? "");
      if (cmd.trim()) {
        posts.push({
          role: "assistant",
          kind: "tool",
          text: fenceBlock(`$ ${truncate(cmd, 300)}`),
        });
      }
    } else if (p.type === "token_count" && p.rate_limits?.credits) {
      credits = p.rate_limits.credits;
      planType = p.rate_limits.plan_type;
    } else if (p.type === "task_complete") {
      if (p.last_agent_message == null && credits?.has_credits === false) {
        // Prompt was received but the turn produced no output because Codex ran
        // out of credits. Surface it instead of mirroring silence. Routed as
        // text so it anchors at the channel root (operators need to see it).
        // `terminal: true` tells the bridge not to attach the working pill to
        // this anchor — no more output is coming this turn, the pill would
        // otherwise sit on the channel indefinitely (Slack auto-clears the
        // built-in 2-min TTL but the refresh loop re-applies it forever).
        const plan = planType ? ` (plan: ${planType}, balance ${credits.balance ?? "0"})` : "";
        posts.push({
          role: "assistant",
          kind: "text",
          terminal: true,
          text: `:warning: Codex is out of credits${plan}. The prompt was received but no output was produced, and this will keep failing until credits are topped up at https://chatgpt.com/codex/settings/usage`,
        });
      } else {
        // Normal end of turn. Mark the most recent assistant text post in this
        // batch as terminal so the bridge clears the working pill on it
        // instead of setting a new one. The agent_message and task_complete
        // events are written back-to-back in the rollout, so the same poll
        // tick almost always sees both; the cross-batch case is covered by
        // bridge.ts watching the raw objs for task_complete.
        for (let i = posts.length - 1; i >= 0; i--) {
          if (posts[i].role === "assistant" && posts[i].kind === "text") {
            posts[i] = { ...posts[i], terminal: true };
            break;
          }
        }
      }
    }
  }
  return coalesceTools(posts);
}
