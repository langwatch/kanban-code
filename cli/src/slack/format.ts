/// Formats Claude Code transcript (.jsonl) lines into Slack messages, porting
/// the rendering lessons from Kanban Code's chat view (TranscriptReader):
/// compact tool labels, merged consecutive assistant lines, summarized results.

export interface SlackPost {
  role: "assistant" | "user";
  text: string; // Slack mrkdwn
}

const MAX_TEXT = 2800; // keep individual posts readable / within Slack block limits

function truncate(s: string, max = MAX_TEXT): string {
  const t = s.trim();
  return t.length > max ? t.slice(0, max) + "…" : t;
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

/// Render one assistant message's content blocks into Slack mrkdwn.
function renderAssistantContent(content: any): string {
  if (typeof content === "string") return truncate(content);
  if (!Array.isArray(content)) return "";

  const parts: string[] = [];
  for (const block of content) {
    switch (block?.type) {
      case "text":
        if (block.text?.trim()) parts.push(truncate(block.text));
        break;
      case "thinking":
        if (block.thinking?.trim()) parts.push(`💭 _${truncate(block.thinking, 280)}_`);
        break;
      case "tool_use": {
        const label = toolLabel(block.name, block.input ?? {});
        parts.push(PROSE_TOOLS.has(block.name) ? label : fenceBlock(label));
        break;
      }
      default:
        break;
    }
  }
  return parts.join("\n");
}

function role(obj: any): string | undefined {
  return obj?.type ?? obj?.message?.role;
}

/// Convert a batch of transcript lines into Slack posts, merging consecutive
/// assistant lines (Claude writes thinking and the reply on separate lines) into
/// one logical message. User turns and tool_result lines are not emitted here —
/// the bridge posts agent activity; relayed human messages already appear in
/// Slack, and automated prompts are announced separately.
export function formatTranscriptLines(objs: any[]): SlackPost[] {
  const posts: SlackPost[] = [];
  let buffer: string[] = [];

  const flush = () => {
    const text = buffer.join("\n").trim();
    if (text) posts.push({ role: "assistant", text });
    buffer = [];
  };

  for (const obj of objs) {
    if (role(obj) === "assistant") {
      const rendered = renderAssistantContent(obj.message?.content ?? obj.content);
      if (rendered) buffer.push(rendered);
    } else {
      flush();
    }
  }
  flush();
  return posts;
}
