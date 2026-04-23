import { useEffect, useRef, useState } from "react";
import { MessageList } from "./MessageList";
import { Composer } from "./Composer";
import { ThemeToggle } from "./ThemeToggle";
import { ApiForAgentsButton } from "./ApiForAgentsButton";
import * as api from "@/lib/api";
import type { ChannelInfo, ChannelMessage } from "@/lib/types";
import { Hash } from "lucide-react";

interface Props {
  channelName: string;
  myHandle: string;
}

function formatRemaining(ms: number): string {
  if (ms <= 0) return "expired";
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s}s remaining`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m} min remaining`;
  const h = Math.floor(m / 60);
  const rem = m % 60;
  return rem ? `${h}h ${rem}m remaining` : `${h}h remaining`;
}

export function ChatRoom({ channelName, myHandle }: Props): React.ReactElement {
  const [info, setInfo] = useState<ChannelInfo | null>(null);
  const [messages, setMessages] = useState<ChannelMessage[]>([]);
  const [infoError, setInfoError] = useState<string | null>(null);
  const [remainingMs, setRemainingMs] = useState<number>(0);
  const seenIds = useRef<Set<string>>(new Set());

  // Bootstrap: /info + /history, then run a long-poll loop.
  //
  // SSE is the natural fit here but Cloudflare quick-tunnel edges buffer
  // streaming responses indefinitely. Long-polling keeps each response
  // short-lived so the edge can't hold bytes (see cloudflare/cloudflared#199).
  useEffect(() => {
    const ctrl = new AbortController();
    let cancelled = false;
    (async () => {
      try {
        const i = await api.fetchInfo(channelName);
        if (cancelled) return;
        setInfo(i);
        setRemainingMs(i.remainingMs);
        const hist = await api.fetchHistory(channelName);
        if (cancelled) return;
        for (const m of hist) seenIds.current.add(m.id);
        setMessages(hist);

        let since = hist.length > 0 ? hist[hist.length - 1].id : "";
        while (!cancelled) {
          try {
            const { messages: incoming, lastId } = await api.pollForMessages(
              channelName, since, ctrl.signal,
            );
            if (cancelled) return;
            // Filter anything already seen — protects against the server
            // returning full history on an unknown `since`.
            const fresh = incoming.filter((m) => !seenIds.current.has(m.id));
            if (fresh.length > 0) {
              for (const m of fresh) seenIds.current.add(m.id);
              setMessages((prev) => [...prev, ...fresh]);
            }
            since = lastId || since;
          } catch (err) {
            if (cancelled || (err instanceof Error && err.name === "AbortError")) return;
            // Transient network blip — back off briefly then resume.
            await new Promise((r) => setTimeout(r, 1500));
          }
        }
      } catch (err) {
        if (!cancelled) setInfoError(err instanceof Error ? err.message : String(err));
      }
    })();
    return () => {
      cancelled = true;
      ctrl.abort();
    };
  }, [channelName, myHandle]);

  // Countdown ticker.
  useEffect(() => {
    if (!info) return;
    const expiresAt = new Date(info.expiresAt).getTime();
    const id = setInterval(() => {
      setRemainingMs(Math.max(0, expiresAt - Date.now()));
    }, 1000);
    return () => clearInterval(id);
  }, [info]);

  // Candidate list for @-mentions: every channel member (excluding the ext_
  // shadow of ourselves) plus the raw handle of the current user's friends
  // already connected via the jsonl.
  const mentionCandidates = info ? info.members.map((m) => m.handle) : [];

  const expired = info && remainingMs <= 0;

  if (infoError) {
    return (
      <div className="min-h-full grid place-items-center p-8">
        <div className="max-w-md space-y-3 text-center">
          <h2 className="text-lg font-semibold">Can't reach this channel</h2>
          <p className="text-sm text-muted-foreground">{infoError}</p>
          <p className="text-xs text-muted-foreground">
            The share link may have expired, or the host closed it.
          </p>
        </div>
      </div>
    );
  }

  return (
    <div className="h-full flex flex-col">
      <header className="border-b px-4 py-3 flex items-center gap-2">
        <Hash className="h-4 w-4 text-muted-foreground" />
        <h1 className="text-sm font-semibold">{channelName}</h1>
        {info && (
          <span className="text-xs text-muted-foreground ml-2">
            {info.members.length} member{info.members.length === 1 ? "" : "s"}
          </span>
        )}
        <span className="ml-auto text-xs text-muted-foreground tabular-nums">
          {formatRemaining(remainingMs)}
        </span>
        <ApiForAgentsButton />
        <ThemeToggle className="-mr-1" />
      </header>

      <MessageList messages={messages} ownHandle={`ext_${myHandle}`} />

      <Composer
        channelName={channelName}
        mentionCandidates={mentionCandidates}
        disabled={!info || Boolean(expired)}
        onSend={async (body, files) => {
          const imagePaths: string[] = [];
          for (const f of files) {
            try {
              const path = await api.uploadImage(channelName, f);
              imagePaths.push(path);
            } catch { /* best-effort */ }
          }
          await api.sendMessage(channelName, { handle: myHandle, body, imagePaths });
        }}
      />
    </div>
  );
}
