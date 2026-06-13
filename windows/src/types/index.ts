// TypeScript types mirroring Rust/Swift domain entities

export type KanbanColumn =
  | "backlog"
  | "in_progress"
  | "requires_attention"
  | "in_review"
  | "done"
  | "all_sessions";

export const COLUMN_DISPLAY: Record<KanbanColumn, string> = {
  backlog: "Backlog",
  in_progress: "In Progress",
  requires_attention: "Waiting",
  in_review: "In Review",
  done: "Done",
  all_sessions: "All Sessions",
};

export const COLUMNS: KanbanColumn[] = [
  "backlog",
  "in_progress",
  "requires_attention",
  "in_review",
  "done",
  "all_sessions",
];

export interface SessionLink {
  sessionId: string;
  sessionPath?: string;
  sessionNumber?: number;
}

export interface WorktreeLink {
  path: string;
  branch?: string;
}

export interface PrCheckRun {
  name: string;
  conclusion?: string;
}

export interface PrLink {
  number: number;
  url?: string;
  status?: string;
  title?: string;
  body?: string;
  approvalCount?: number;
  unresolvedThreads?: number;
  mergeStateStatus?: string;
  /** APPROVED / CHANGES_REQUESTED / REVIEW_REQUIRED */
  reviewDecision?: string;
  /** Flattened statusCheckRollup. Empty when no CI configured. */
  checkRuns?: PrCheckRun[];
}

export interface IssueLink {
  number: number;
  url?: string;
  title?: string;
  body?: string;
}

export interface ManualOverrides {
  worktreePath: boolean;
  tmuxSession: boolean;
  name: boolean;
  column: boolean;
  prLink: boolean;
  issueLink: boolean;
  dismissedPrs?: number[];
  branchWatermark?: number;
}

export interface QueuedPrompt {
  id: string;
  body: string;
  sendAutomatically: boolean;
}

export interface Link {
  id: string;
  name?: string;
  projectPath?: string;
  column: KanbanColumn;
  createdAt: string;
  updatedAt: string;
  lastActivity?: string;
  manualOverrides: ManualOverrides;
  manuallyArchived: boolean;
  source: "discovered" | "hook" | "github_issue" | "manual";
  promptBody?: string;
  sessionLink?: SessionLink;
  worktreeLink?: WorktreeLink;
  prLinks: PrLink[];
  issueLink?: IssueLink;
  discoveredBranches?: string[];
  isRemote: boolean;
  isLaunching?: boolean;
  queuedPrompts?: QueuedPrompt[];
  /** Manual sort position within a column; undefined = time-based ordering. */
  sortOrder?: number;
  /** Coding assistant that owns this card. Drives which CLI runs in the
   *  terminal. Defaults to "claude" for legacy/macOS-written cards. */
  assistantId?: AssistantId;
}

export type AssistantId = "claude" | "gemini";

export const ASSISTANT_DISPLAY: Record<AssistantId, string> = {
  claude: "Claude Code",
  gemini: "Gemini CLI",
};

export const ASSISTANT_CLI: Record<AssistantId, string> = {
  claude: "claude",
  gemini: "gemini",
};

export interface Session {
  id: string;
  name?: string;
  firstPrompt?: string;
  projectPath?: string;
  gitBranch?: string;
  messageCount: number;
  modifiedTime: string;
  jsonlPath?: string;
}

export type ActivityState =
  | "activelyWorking"
  | "needsAttention"
  | "idleWaiting"
  | "ended"
  | "stale";

export interface CardDto {
  id: string;
  link: Link;
  session?: Session;
  activityState?: ActivityState;
  displayTitle: string;
  projectName?: string;
  relativeTime: string;
  showSpinner: boolean;
}

export interface BoardStateDto {
  cards: CardDto[];
  lastRefresh?: string;
}

export interface Project {
  path: string;
  name?: string;
  githubFilter?: string;
  repoRoot?: string;
  /** Per-project prompt prefix override (falls back to Settings.promptTemplate). */
  promptTemplate?: string;
}

export interface GlobalViewSettings {
  excludedPaths: string[];
}

export interface GitHubSettings {
  defaultFilter: string;
  pollIntervalSeconds: number;
  mergeCommand: string;
}

export interface NotificationSettings {
  notificationsEnabled: boolean;
  pushoverEnabled: boolean;
  pushoverToken?: string;
  pushoverUserKey?: string;
  renderMarkdownImage: boolean;
}

export interface SessionTimeoutSettings {
  activeThresholdMinutes: number;
}

/** Byte-compatible with macOS RemoteSettings — same JSON field names. */
export interface RemoteSettings {
  host: string;
  remotePath: string;
  localPath: string;
  /** Omitted = use Mutagen defaults from mutagen.rs::default_ignores(). */
  syncIgnores?: string[];
}

export type SyncStatusKind =
  | "disabled"
  | "watching"
  | "scanning"
  | "staging"
  | "conflicts"
  | "paused"
  | "error";

export interface SyncStatus {
  kind: SyncStatusKind;
  sessionName?: string;
  conflictCount: number;
  message?: string;
}

export interface RemoteHostStatus {
  host: string;
  online: boolean;
  since?: string;
}

export interface RemotePrereqs {
  mutagenAvailable: boolean;
  bashAvailable: boolean;
  sshAvailable: boolean;
  mutagenPath?: string;
  bashPath?: string;
}

export interface Settings {
  projects: Project[];
  globalView: GlobalViewSettings;
  github: GitHubSettings;
  notifications: NotificationSettings;
  sessionTimeout: SessionTimeoutSettings;
  promptTemplate: string;
  githubIssuePromptTemplate: string;
  hasCompletedOnboarding: boolean;
  editor: string;
  terminalFontSize: number;
  /** Shell command for the embedded terminal — space-separated tokens. Default "cmd.exe". */
  terminalShell: string;
  remote?: RemoteSettings;
}

export interface DependencyStatus {
  claudeAvailable: boolean;
  gitAvailable: boolean;
  ghAvailable: boolean;
  ghAuthenticated: boolean;
}

export interface ContentBlock {
  kind: "text" | "tool_use" | "tool_result" | "thinking";
  text: string;
}

export interface Turn {
  index: number;
  role: "user" | "assistant";
  textPreview: string;
  timestamp?: string;
  contentBlocks: ContentBlock[];
}

export interface TranscriptPage {
  turns: Turn[];
  totalTurns: number;
  hasMore: boolean;
  nextOffset: number;
}
