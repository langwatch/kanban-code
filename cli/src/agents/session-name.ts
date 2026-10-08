import { readLinks, pasteTmuxPrompt, rushIdFromSessionName } from "../data.js";
import { Link } from "../types.js";
import { answerRushHost, rushHostInfo, rushPendingQuestion } from "./rush-host.js";

/// The session name an agent is reached by: the one on its card, which is a
/// rush host's `rush-<id>` for an agent on rush, else the slug, the tmux
/// session name every agent had before it got a card. Pass `links` to resolve
/// many agents from one read of links.json.
export function agentSessionName(slug: string, links?: Link[]): string {
  let all = links;
  if (!all) {
    try {
      all = readLinks();
    } catch {
      return slug;
    }
  }
  const cards = all.filter((l) => l.name === slug && l.tmuxLink?.sessionName);
  const card = cards.find((l) => !l.manuallyArchived) ?? cards[0];
  return card?.tmuxLink?.sessionName ?? slug;
}

/// Deliver a person's message to an agent's session. A rush host blocked on
/// a question takes it as the answer, since a plain message would wait in
/// its queue behind the question; everything else gets it as a prompt.
export function deliverAgentMessage(
  sessionName: string,
  text: string
): { ok: boolean; error?: string; answered?: boolean } {
  const rushId = rushIdFromSessionName(sessionName);
  if (rushId) {
    const host = rushHostInfo(rushId);
    if (host && rushPendingQuestion(host) !== undefined) {
      const res = answerRushHost(rushId, text);
      if (res.ok) return { ok: true, answered: true };
    }
  }
  return pasteTmuxPrompt(sessionName, text);
}
