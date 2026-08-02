import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { cardForTmuxSession, currentTmuxSessionName } from "./broadcast.js";
import { readLinks, readSettings } from "./data.js";
import { slugifyDisplay, truncateSlug } from "./handles.js";
import { descendantIds, subagentDepth } from "./hierarchy.js";
import { commandInboxDir, commandResponsesDir } from "./paths.js";
import {
  FORCED_COMPACT_OFFSET_TOKENS,
  STEER_COMPACT_OFFSET_TOKENS,
  tokenLabel,
} from "./self-compact.js";
import type { CodingAssistant, Link } from "./types.js";

export { ancestorIds, descendantIds, subagentDepth, subagentRelationship } from "./hierarchy.js";
export type { SubagentRelationship } from "./hierarchy.js";

/**
 * `enqueuePrompt` is card-level rather than subagent-level: the CLI cannot append
 * to a card's prompt queue itself because the running app owns links.json.
 */
export type SubagentOperation =
  | "spawn"
  | "fork"
  | "archive"
  | "resume"
  | "enqueuePrompt"
  | "relinkSession"
  | "setModel"
  | "setContextThreshold";

export interface SubagentCommandRequest {
  id: string;
  operation: SubagentOperation;
  createdAt: string;
  parentCardId: string;
  cardId?: string;
  /** Card whose transcript a fork copies. Defaults to the requesting parent. */
  sourceCardId?: string;
  /** Child card name, which also becomes its chat handle. */
  name?: string;
  prompt?: string;
  assistant?: CodingAssistant;
  model?: string;
  contextThresholdTokens?: number;
  /** Transcript a relink points the card at. */
  sessionId?: string;
  sessionPath?: string;
}

export interface SubagentCommandResponse {
  id: string;
  ok: boolean;
  cardId?: string;
  error?: string;
}

export const depthLimitError = (maximumDepth: number): string =>
  `You already reached the user-defined maximum subagent depth of ${maximumDepth}. ` +
  "You cannot spawn another subagent. Do the work yourself.";

export const missingForkSessionError = (cardId: string): string =>
  `Card ${cardId} has no session to fork. ` +
  "Use `kanban subagent spawn` to start a new child instead.";

export const maximumSupportedSubagentDepth = 5;

export function resolveSubagentPrompt(args: string[], stdin: string): string {
  if (args.length > 0 && !(args.length === 1 && args[0] === "-")) {
    return args.join(" ");
  }
  return stdin;
}

export const missingHandleError =
  "A --handle is required so the subagent has a readable @handle in chat, " +
  "for example --handle parser-bug.";

/**
 * Subagent handles are derived from the card name, so requiring an explicit
 * short handle keeps DMs readable instead of slugifying the first line of a
 * long delegated goal.
 */
export function normalizeSubagentHandle(raw: string): string {
  const slug = truncateSlug(slugifyDisplay(raw.replace(/^@/, "")));
  if (!slug) {
    throw new Error(
      `Handle "${raw}" has no letters or digits. Use something like --handle parser-bug.`
    );
  }
  return slug;
}

export function normalizeMaximumDepth(value: number | undefined): number {
  return Math.min(maximumSupportedSubagentDepth, Math.max(0, value ?? 1));
}

export function currentCardOrThrow(links: Link[] = readLinks()): Link {
  const tmuxSession = currentTmuxSessionName();
  if (!tmuxSession) {
    throw new Error(
      "Could not detect the current tmux session. Run this command from an agent inside a Kanban Code card."
    );
  }
  const card = cardForTmuxSession(links, tmuxSession);
  if (!card || card.tmuxLink?.sessionName !== tmuxSession) {
    throw new Error(
      `Tmux session "${tmuxSession}" is not the primary assistant session of a Kanban Code card.`
    );
  }
  return card;
}

export function validateCanSpawn(parent: Link, links: Link[] = readLinks()): number {
  const maximumDepth = normalizeMaximumDepth(readSettings().subagents?.maximumDepth);
  if (maximumDepth === 0 || subagentDepth(parent.id, links) >= maximumDepth) {
    throw new Error(depthLimitError(maximumDepth));
  }
  return maximumDepth;
}

export function buildSubagentPrompt(
  parent: Link,
  childPrompt: string,
  contextThresholdTokens?: number,
  handle?: string
): string {
  const compactInstruction = contextThresholdTokens
    ? `This card has a ${tokenLabel(contextThresholdTokens)} context threshold. You get a queued nudge at ${tokenLabel(contextThresholdTokens)} tokens, a steered reminder mid-turn at ${tokenLabel(contextThresholdTokens + STEER_COMPACT_OFFSET_TOKENS)}, and an interrupt with a forced /compact at ${tokenLabel(contextThresholdTokens + FORCED_COMPACT_OFFSET_TOKENS)}. Compact yourself before that last one, and always pass a post-compact continuation message to \`kanban self-compact\`.`
    : undefined;
  return [
    handle ? `Your chat handle is @${handle}.` : undefined,
    `You are a Kanban Code subagent owned by card ${parent.id} (${parent.name ?? "untitled parent"}).`,
    "Work independently on the goal below.",
    "Use `kanban parent dm <message>` to report progress or ask the parent a question.",
    "When the goal is fully reached, use `kanban parent dm-and-self-archive <message>` to report the result and archive yourself.",
    "The parent can resume you later if follow-up work is needed.",
    compactInstruction,
    "",
    "Goal:",
    childPrompt,
  ].filter((line): line is string => line !== undefined).join("\n");
}

export function assertOwnedSubagent(caller: Link, target: Link, links: Link[]): void {
  if (!descendantIds(caller.id, links).has(target.id)) {
    throw new Error(`Card ${target.id} is not a subagent owned by ${caller.id}.`);
  }
}

export function makeSubagentRequest(
  operation: SubagentOperation,
  parentCardId: string,
  fields: Omit<Partial<SubagentCommandRequest>, "id" | "operation" | "createdAt" | "parentCardId"> = {}
): SubagentCommandRequest {
  return {
    id: randomUUID().toLowerCase(),
    operation,
    createdAt: new Date().toISOString(),
    parentCardId,
    ...fields,
  };
}

/**
 * Claude Code applies `/model <name>` directly. Codex's `/model` takes no
 * argument and opens a picker, so passing a name there just submits the whole
 * thing as an ordinary prompt.
 */
export function modelSwitchCommand(model: string, assistant: CodingAssistant = "claude"): string {
  const name = model.trim().replace(/^\/?(model\s+)?/i, "");
  if (!name) throw new Error("A model name is required, for example opus or gpt-5.");
  return assistant === "codex" ? "/model" : `/model ${name}`;
}

/** Whether the assistant applies a named model switch without further input. */
export function appliesModelSwitchDirectly(assistant: CodingAssistant): boolean {
  return assistant !== "codex";
}

/**
 * Switching models mid-conversation invalidates the prompt cache, so assistants
 * ask before doing it. Claude Code renders "Switch model?" with a numbered list,
 * Codex a similar picker; in both the wanted option is the selected default, so
 * accepting is a bare Enter.
 */
export function needsModelSwitchConfirmation(pane: string): boolean {
  if (/^\s*[❯>]?\s*1\.\s*Yes/im.test(pane)) return true;
  return /Switch model\?/i.test(pane) && /\b1\./.test(pane);
}

export function kanbanCodeIsRunning(): boolean {
  try {
    execFileSync("pgrep", ["-x", "KanbanCode"], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

/**
 * A running Kanban Code drains this mailbox on its own poll loop, and `open`
 * pulls focus away from whatever the user is looking at — including the very
 * terminal pane this command was typed into. So only use the deep link to wake
 * the app when it is not running at all.
 */
function defaultNotify(requestId: string): void {
  if (kanbanCodeIsRunning()) return;
  execFileSync("open", ["-g", `kanbancode://command/${requestId}`], { stdio: "ignore" });
}

export interface SubmitSubagentRequestOptions {
  timeoutMs?: number;
  notify?: (requestId: string) => void;
}

export async function submitSubagentRequest(
  request: SubagentCommandRequest,
  options: SubmitSubagentRequestOptions = {}
): Promise<SubagentCommandResponse> {
  const inbox = commandInboxDir();
  const responses = commandResponsesDir();
  mkdirSync(inbox, { recursive: true });
  mkdirSync(responses, { recursive: true });
  const requestPath = join(inbox, `${request.id}.json`);
  const tempPath = `${requestPath}.tmp`;
  const responsePath = join(responses, `${request.id}.json`);
  writeFileSync(tempPath, JSON.stringify(request, null, 2));
  renameSync(tempPath, requestPath);

  const notify = options.notify ?? defaultNotify;
  try {
    notify(request.id);
  } catch (error) {
    rmSync(requestPath, { force: true });
    throw new Error(`Could not contact Kanban Code: ${String(error)}`);
  }

  const timeoutMs = options.timeoutMs ?? 120_000;
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(responsePath)) {
      let response: SubagentCommandResponse;
      try {
        response = JSON.parse(readFileSync(responsePath, "utf-8")) as SubagentCommandResponse;
      } catch (error) {
        rmSync(responsePath, { force: true });
        rmSync(requestPath, { force: true });
        throw new Error(`Kanban Code returned an invalid subagent response: ${String(error)}`);
      }
      rmSync(responsePath, { force: true });
      rmSync(requestPath, { force: true });
      if (response.id !== request.id) {
        throw new Error(
          `Kanban Code returned a mismatched subagent response: expected ${request.id}, received ${response.id}.`
        );
      }
      return response;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  rmSync(requestPath, { force: true });
  rmSync(tempPath, { force: true });
  throw new Error(
    `Kanban Code did not process the subagent command within ${Math.ceil(timeoutMs / 1_000)} seconds.`
  );
}
