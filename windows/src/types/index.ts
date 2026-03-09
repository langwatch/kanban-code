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

export interface PrLink {
  number: number;
  url?: string;
  status?: string;
  title?: string;
  body?: string;
  approvalCount?: number;
  unresolvedThreads?: number;
  mergeStateStatus?: string;
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
}

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
