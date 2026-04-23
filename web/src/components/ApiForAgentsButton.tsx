import { useState } from "react";
import { Bot, Check, Copy } from "lucide-react";
import { openApiSpecUrl } from "@/lib/api";
import { cn } from "@/lib/utils";

/** Thin wrapper around the Clipboard API so tests can inject a stub without
 *  fighting jsdom's read-only `navigator.clipboard`. Returns true on
 *  success, false when the API isn't available (in which case the caller
 *  falls back to opening the URL in a new tab). */
export async function copyToClipboard(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch { return false; }
}

/** Small header action that hands off the OpenAPI spec URL to another
 *  engineer's agent. Click copies the tokenized URL to the clipboard and
 *  briefly swaps the icon for a checkmark. */
export interface ApiForAgentsButtonProps {
  className?: string;
  /** Injected by tests. Production uses `copyToClipboard`. */
  copy?: (text: string) => Promise<boolean>;
}
export function ApiForAgentsButton({ className, copy = copyToClipboard }: ApiForAgentsButtonProps): React.ReactElement {
  const [copied, setCopied] = useState(false);

  async function onCopy(): Promise<void> {
    const url = openApiSpecUrl();
    const ok = await copy(url);
    if (ok) {
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } else {
      // Fallback: open in a new tab so the user can copy from the address bar.
      window.open(url, "_blank", "noreferrer,noopener");
    }
  }

  return (
    <button
      type="button"
      onClick={onCopy}
      aria-label="Copy API URL for agents"
      title="Copy OpenAPI spec URL — paste into your agent (MCP, ChatGPT, etc)"
      className={cn(
        "inline-flex items-center gap-1.5 h-7 px-2 rounded-md text-xs",
        "text-muted-foreground hover:text-foreground hover:bg-accent",
        "border border-border/60",
        "transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
        className,
      )}
    >
      {copied ? <Check className="h-3 w-3" /> : <Bot className="h-3 w-3" />}
      <span>{copied ? "Copied" : "API for Agents"}</span>
      {!copied && <Copy className="h-3 w-3 opacity-60" />}
    </button>
  );
}
