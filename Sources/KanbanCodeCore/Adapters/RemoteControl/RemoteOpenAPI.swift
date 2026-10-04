import Foundation

/// OpenAPI 3.1 description of docs/remote-control.md, served at
/// `/.well-known/openapi.json` so agents can discover the API.
enum RemoteOpenAPI {
    static let document = #"""
{
  "openapi": "3.1.0",
  "info": {
    "title": "Kanban Code remote control",
    "version": "1",
    "description": "Drive Kanban Code on a Mac: read the board and transcripts, start coding tasks, send prompts. Every call except /v1/health and this document needs Authorization: Bearer <token>. WebSocket clients may pass ?token= instead. Scope agent cannot open terminals. Errors are {\"error\": \"...\"}: 401 unknown token, 403 scope, 404 unknown card, 400 bad request, 409 no live session."
  },
  "servers": [{"url": "http://127.0.0.1:7780"}],
  "security": [{"bearer": []}],
  "paths": {
    "/v1/health": {
      "get": {"summary": "Liveness and version", "security": [], "responses": {"200": {"description": "ok", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Health"}}}}}}
    },
    "/v1/me": {
      "get": {"summary": "The device the token belongs to", "responses": {"200": {"description": "ok", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Device"}}}}, "401": {"$ref": "#/components/responses/Error"}}}
    },
    "/v1/board": {
      "parameters": [{"$ref": "#/components/parameters/All"}],
      "get": {"summary": "The working set (no archived, no All Sessions, the 30 most recent Done) and projects; all=1 for every card", "responses": {"200": {"description": "ok", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Board"}}}}, "401": {"$ref": "#/components/responses/Error"}}}
    },
    "/v1/cards/search": {
      "parameters": [
        {"name": "q", "in": "query", "schema": {"type": "string"}, "description": "words separated by spaces; every word must be in the card's title, the first lines of its prompt, its project, branch, or a pull request (#N, title), whatever the case or the accents. Empty lists the most recent cards of the scope."},
        {"name": "limit", "in": "query", "schema": {"type": "integer", "default": 50, "maximum": 200}},
        {"name": "scope", "in": "query", "schema": {"type": "string", "enum": ["all", "older", "archived"], "default": "all"}, "description": "older: only cards outside the working set (archived, All Sessions, older Done). archived: archived cards that are not subagents."},
        {"name": "local", "in": "query", "schema": {"type": "string", "enum": ["1"]}, "description": "answer from this master's cards only, without asking its peers"}
      ],
      "get": {"summary": "Search every card this master and its peers know, archived and All Sessions included: board cards first, then the most recently active", "responses": {"200": {"description": "ok", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/CardSearchResult"}}}}, "400": {"$ref": "#/components/responses/Error"}, "401": {"$ref": "#/components/responses/Error"}}}
    },
    "/v1/machines": {
      "get": {"summary": "The machines a task can run on: this master (kind this, where a task with no machine runs), the other masters and the ssh machines", "responses": {"200": {"description": "ok", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/MachineList"}}}}, "401": {"$ref": "#/components/responses/Error"}}}
    },
    "/v1/cards/{id}": {
      "parameters": [{"$ref": "#/components/parameters/CardId"}],
      "get": {"summary": "One card", "responses": {"200": {"description": "ok", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Card"}}}}, "404": {"$ref": "#/components/responses/Error"}}},
      "patch": {"summary": "Rename, move, archive or pin the card: {\"name\", \"column\", \"archived\", \"pinned\"}, each optional; archived false brings an archived card back; syncs to the other masters", "responses": {"200": {"description": "ok", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Card"}}}}, "404": {"$ref": "#/components/responses/Error"}, "409": {"$ref": "#/components/responses/Error"}}},
      "delete": {"summary": "Delete an archived card with its subagents, sessions and conversation file", "responses": {"204": {"description": "deleted"}, "404": {"$ref": "#/components/responses/Error"}, "409": {"$ref": "#/components/responses/Error"}}}
    },
    "/v1/cards/{id}/transcript": {
      "parameters": [
        {"$ref": "#/components/parameters/CardId"},
        {"name": "limit", "in": "query", "schema": {"type": "integer", "default": 50, "minimum": 1, "maximum": 500}},
        {"name": "before", "in": "query", "description": "olderCursor of a previous page", "schema": {"type": "string"}}
      ],
      "get": {"summary": "Newest messages of the card's conversation, oldest first", "responses": {"200": {"description": "ok", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Transcript"}}}}, "404": {"$ref": "#/components/responses/Error"}}}
    },
    "/v1/tasks": {
      "post": {
        "summary": "Create a card and launch its session with the project's defaults",
        "requestBody": {"required": true, "content": {"application/json": {"schema": {"$ref": "#/components/schemas/TaskRequest"}}}},
        "responses": {"201": {"description": "created", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Card"}}}}, "400": {"$ref": "#/components/responses/Error"}}
      }
    },
    "/v1/cards/{id}/prompt": {
      "parameters": [{"$ref": "#/components/parameters/CardId"}],
      "post": {
        "summary": "Send a prompt. queue: delivered when the turn ends (at once when idle). now: interrupts the turn first.",
        "requestBody": {"required": true, "content": {"application/json": {"schema": {"$ref": "#/components/schemas/PromptRequest"}}}},
        "responses": {"204": {"description": "accepted"}, "404": {"$ref": "#/components/responses/Error"}, "409": {"$ref": "#/components/responses/Error"}}
      }
    },
    "/v1/cards/{id}/side-chat": {
      "parameters": [{"$ref": "#/components/parameters/CardId"}],
      "post": {
        "summary": "Start a side chat run: btw answers a question about the session, catchup sums up what happened since the human's last message. The run reads the session and writes nothing into it. Poll the run for its answer.",
        "requestBody": {"required": true, "content": {"application/json": {"schema": {"$ref": "#/components/schemas/SideChatRequest"}}}},
        "responses": {"201": {"description": "started", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/SideChatRun"}}}}, "400": {"$ref": "#/components/responses/Error"}, "404": {"$ref": "#/components/responses/Error"}, "409": {"$ref": "#/components/responses/Error"}}
      }
    },
    "/v1/cards/{id}/side-chat/{runId}": {
      "parameters": [{"$ref": "#/components/parameters/CardId"}, {"name": "runId", "in": "path", "required": true, "schema": {"type": "string"}}],
      "get": {"summary": "The run and its answer so far", "responses": {"200": {"description": "the run", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/SideChatRun"}}}}, "404": {"$ref": "#/components/responses/Error"}}},
      "delete": {"summary": "Stop the run and forget it", "responses": {"204": {"description": "stopped"}}}
    },
    "/v1/cards/{id}/slash-commands": {
      "parameters": [{"$ref": "#/components/parameters/CardId"}],
      "get": {"summary": "What the card's chat composer offers after /: the chat's own commands, the agent's, and the skills and custom commands the session can run, read on the master that owns the card", "responses": {"200": {"description": "the commands", "content": {"application/json": {"schema": {"type": "array", "items": {"$ref": "#/components/schemas/SlashCommand"}}}}}, "404": {"$ref": "#/components/responses/Error"}}}
    },
    "/v1/cards/{id}/queue/{promptId}": {
      "parameters": [{"$ref": "#/components/parameters/CardId"}, {"name": "promptId", "in": "path", "required": true, "description": "an id from the card's queuedPrompts", "schema": {"type": "string"}}],
      "post": {"summary": "Send a queued prompt now, interrupting the turn when one runs", "responses": {"204": {"description": "sent"}, "404": {"$ref": "#/components/responses/Error"}, "409": {"$ref": "#/components/responses/Error"}}},
      "patch": {"summary": "Replace the text of a queued prompt; {\"text\": \"...\"}", "responses": {"204": {"description": "edited"}, "400": {"$ref": "#/components/responses/Error"}, "404": {"$ref": "#/components/responses/Error"}}},
      "delete": {"summary": "Drop a queued prompt", "responses": {"204": {"description": "removed"}, "404": {"$ref": "#/components/responses/Error"}}}
    },
    "/v1/cli": {
      "post": {"summary": "Run a kanban channel or dm command on this master (the channels home), for another master; full scope. {\"argv\", \"cwd\", \"env\": {\"KANBAN_CARD_ID\", \"KANBAN_HUMAN_HANDLE\"}, \"images\": [{\"name\", \"base64\"}]} -> {\"stdout\", \"stderr\", \"code\"}", "responses": {"200": {"description": "RemoteCLIResult"}, "400": {"$ref": "#/components/responses/Error"}, "403": {"$ref": "#/components/responses/Error"}}}
    },
    "/v1/channels/files": {
      "get": {"summary": "The files of the channels directory (not read-state.json, drafts.json): {\"files\": [{\"path\", \"size\", \"mtime\"}]}", "responses": {"200": {"description": "RemoteChannelFiles"}}}
    },
    "/v1/channels/files/{path}": {
      "parameters": [{"name": "path", "in": "path", "required": true, "description": "relative to channels/, may hold slashes", "schema": {"type": "string"}}],
      "get": {"summary": "A channel file from ?offset= on", "responses": {"200": {"description": "file bytes"}, "404": {"$ref": "#/components/responses/Error"}}},
      "put": {"summary": "Create a channel file that does not exist yet (the first pairing copies a master's channels); full scope", "responses": {"204": {"description": "created"}, "409": {"$ref": "#/components/responses/Error"}}}
    },
    "/v1/cards/{id}/interrupt": {
      "parameters": [{"$ref": "#/components/parameters/CardId"}],
      "post": {"summary": "Interrupt the current turn", "responses": {"204": {"description": "done"}, "404": {"$ref": "#/components/responses/Error"}, "409": {"$ref": "#/components/responses/Error"}}}
    },
    "/v1/cards/{id}/resume": {
      "parameters": [{"$ref": "#/components/parameters/CardId"}],
      "post": {"summary": "Start the card's session again when it ended", "responses": {"200": {"description": "ok", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Card"}}}}, "404": {"$ref": "#/components/responses/Error"}}}
    },
    "/v1/cards/{id}/move": {
      "parameters": [{"$ref": "#/components/parameters/CardId"}],
      "post": {"summary": "Continue the card on another master (a handover) or machine; {\"to\": \"<machine id or name>\"|\"mac\"}", "responses": {"200": {"description": "ok", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Card"}}}}, "404": {"$ref": "#/components/responses/Error"}, "409": {"$ref": "#/components/responses/Error"}}}
    },
    "/v1/cards/{id}/worktree/remove": {
      "parameters": [{"$ref": "#/components/parameters/CardId"}],
      "post": {"summary": "Remove the card's worktree on the machine that holds it (the owning master runs it), then drop the worktree from the card, or the card when it has no session. Full scope", "responses": {"200": {"description": "{\"machine\", \"cardDeleted\"}"}, "403": {"$ref": "#/components/responses/Error"}, "404": {"$ref": "#/components/responses/Error"}, "409": {"$ref": "#/components/responses/Error"}}}
    },
    "/v1/cards/{id}/discover": {
      "parameters": [{"$ref": "#/components/parameters/CardId"}],
      "post": {"summary": "Re-scan the card's conversation for pushed branches and its pull requests, on the owning master", "responses": {"204": {"description": "done"}, "404": {"$ref": "#/components/responses/Error"}}}
    },
    "/v1/cards/{id}/pasted-image": {
      "parameters": [{"$ref": "#/components/parameters/CardId"}],
      "post": {"summary": "Keep an image pasted into the card's terminal as a file on the owning master. The body is the image bytes (PNG, JPEG, GIF or WebP, at most 20 MiB)", "requestBody": {"content": {"application/octet-stream": {"schema": {"type": "string", "format": "binary"}}}}, "responses": {"201": {"description": "{\"path\"}: the file on the owning master"}, "400": {"$ref": "#/components/responses/Error"}, "404": {"$ref": "#/components/responses/Error"}}}
    },
    "/v1/cards/{id}/handover": {
      "parameters": [{"$ref": "#/components/parameters/CardId"}],
      "get": {"summary": "What a master adopting the card needs: repository origin, branch, uncommitted changes, transcript size", "responses": {"200": {"description": "RemoteHandoverInfo"}, "404": {"$ref": "#/components/responses/Error"}}}
    },
    "/v1/cards/{id}/transcript/raw": {
      "parameters": [
        {"$ref": "#/components/parameters/CardId"},
        {"name": "offset", "in": "query", "schema": {"type": "integer", "default": 0}},
        {"name": "limit", "in": "query", "schema": {"type": "integer", "default": 4194304}}
      ],
      "get": {"summary": "Bytes of the transcript file from offset; X-Transcript-Size has the file size", "responses": {"200": {"description": "application/octet-stream"}, "404": {"$ref": "#/components/responses/Error"}}}
    },
    "/v1/events": {
      "parameters": [{"$ref": "#/components/parameters/All"}],
      "get": {"summary": "WebSocket. Text frames of Event: a board event on connect, then cards events (upserted, removed, projects) at most once per second, a ping every 20 s. Send {\"type\":\"resync\"} for a whole board again.", "responses": {"101": {"description": "switching protocols"}, "401": {"$ref": "#/components/responses/Error"}}}
    },
    "/v1/cards/{id}/terminal": {
      "parameters": [
        {"$ref": "#/components/parameters/CardId"},
        {"name": "session", "in": "query", "description": "a sessionName from the card's terminals; the primary one when omitted", "schema": {"type": "string"}},
        {"name": "cols", "in": "query", "schema": {"type": "integer", "default": 80}},
        {"name": "rows", "in": "query", "schema": {"type": "integer", "default": 24}}
      ],
      "get": {"summary": "WebSocket, scope full. Binary frames carry terminal bytes both ways; a text frame {\"type\":\"resize\",\"cols\":N,\"rows\":M} resizes; {\"type\":\"scroll\",\"lines\":N} scrolls a tmux terminal's history, up when N is positive (servers listing the terminalScroll feature).", "responses": {"101": {"description": "switching protocols"}, "403": {"$ref": "#/components/responses/Error"}, "404": {"$ref": "#/components/responses/Error"}}}
    }
  },
  "components": {
    "securitySchemes": {"bearer": {"type": "http", "scheme": "bearer"}},
    "parameters": {
      "CardId": {"name": "id", "in": "path", "required": true, "schema": {"type": "string"}},
      "All": {"name": "all", "in": "query", "description": "1 for every card instead of the working set", "schema": {"type": "string", "enum": ["1"]}}
    },
    "responses": {"Error": {"description": "refused", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Error"}}}}},
    "schemas": {
      "Error": {"type": "object", "required": ["error"], "properties": {"error": {"type": "string"}}},
      "Health": {"type": "object", "properties": {"app": {"type": "string"}, "version": {"type": "string"}, "apiVersion": {"type": "integer"}, "hostName": {"type": "string"}, "features": {"type": "array", "items": {"type": "string", "enum": ["images", "queue", "terminalScroll", "machines", "cardActions", "worktrees", "sideChat", "slashCommands"]}, "description": "what the server supports beyond apiVersion 1; missing on older servers"}}},
      "Device": {"type": "object", "properties": {"id": {"type": "string"}, "name": {"type": "string"}, "scope": {"type": "string", "enum": ["full", "agent"]}, "createdAt": {"type": "string", "format": "date-time"}, "lastSeenAt": {"type": ["string", "null"], "format": "date-time"}}},
      "PR": {"type": "object", "properties": {"number": {"type": "integer"}, "url": {"type": ["string", "null"]}, "title": {"type": ["string", "null"]}, "status": {"type": ["string", "null"], "description": "open, draft, merged or closed"}}},
      "Terminal": {"type": "object", "properties": {"sessionName": {"type": "string"}, "label": {"type": "string"}, "isPrimary": {"type": "boolean"}}},
      "Card": {
        "type": "object",
        "description": "isLive, isBusy, archived and pinned are left out when false, queuedPromptCount when 0, queuedPrompts, terminals and prs when empty, null fields always; a missing key means that default.",
        "required": ["id", "title", "column", "assistant", "runtime", "updatedAt"],
        "properties": {
          "id": {"type": "string"},
          "title": {"type": "string"},
          "column": {"type": "string", "enum": ["backlog", "in_progress", "requires_attention", "in_review", "done", "all_sessions"]},
          "projectPath": {"type": ["string", "null"]},
          "projectName": {"type": ["string", "null"]},
          "branch": {"type": ["string", "null"]},
          "worktreePath": {"type": ["string", "null"]},
          "assistant": {"type": "string", "description": "claude, codex or gemini"},
          "runtime": {"type": "string", "enum": ["tmux", "agtop", "machine", "none"], "description": "agtop: a rush host (rush was named agtop)"},
          "isLive": {"type": "boolean"},
          "isBusy": {"type": "boolean"},
          "sessionId": {"type": ["string", "null"]},
          "terminals": {"type": "array", "items": {"$ref": "#/components/schemas/Terminal"}},
          "prs": {"type": "array", "items": {"$ref": "#/components/schemas/PR"}},
          "queuedPromptCount": {"type": "integer"},
          "queuedPrompts": {"type": "array", "items": {"$ref": "#/components/schemas/QueuedPrompt"}, "description": "oldest first"},
          "parentCardId": {"type": ["string", "null"]},
          "archived": {"type": "boolean"},
          "pinned": {"type": "boolean"},
          "lastActivity": {"type": ["string", "null"], "format": "date-time"},
          "updatedAt": {"type": "string", "format": "date-time"},
          "machineId": {"type": ["string", "null"], "description": "the master that owns the card; send its prompts, transcript and terminal calls there"},
          "machineName": {"type": ["string", "null"]}
        }
      },
      "MachineList": {"type": "object", "properties": {"machines": {"type": "array", "items": {"type": "object", "required": ["name", "kind"], "properties": {"id": {"type": "string", "description": "machine id of a master"}, "name": {"type": "string", "description": "what TaskRequest.machine accepts"}, "kind": {"type": "string", "enum": ["this", "master", "ssh"]}, "online": {"type": "boolean"}, "alwaysOn": {"type": "boolean"}}}}}},
      "Machine": {"type": "object", "properties": {"id": {"type": "string"}, "name": {"type": "string"}}},
      "Project": {"type": "object", "properties": {"path": {"type": "string"}, "name": {"type": "string"}}},
      "CardSearchResult": {"type": "object", "required": ["cards"], "properties": {"cards": {"type": "array", "items": {"$ref": "#/components/schemas/Card"}}, "truncated": {"type": "boolean", "description": "more cards matched than limit; absent when false"}, "unreachable": {"type": "array", "items": {"type": "string"}, "description": "peer masters that did not answer in time; absent when empty"}}},
      "Board": {"type": "object", "properties": {"cards": {"type": "array", "items": {"$ref": "#/components/schemas/Card"}}, "projects": {"type": "array", "items": {"$ref": "#/components/schemas/Project"}}, "generatedAt": {"type": "string", "format": "date-time"}, "machine": {"$ref": "#/components/schemas/Machine", "description": "the master serving this board"}}},
      "Message": {"type": "object", "properties": {"id": {"type": "string"}, "role": {"type": "string", "enum": ["user", "assistant", "tool", "system"]}, "text": {"type": "string"}, "at": {"type": ["string", "null"], "format": "date-time"}}},
      "Transcript": {"type": "object", "properties": {"cardId": {"type": "string"}, "messages": {"type": "array", "items": {"$ref": "#/components/schemas/Message"}}, "olderCursor": {"type": ["string", "null"]}}},
      "TaskRequest": {
        "type": "object",
        "required": ["project", "prompt"],
        "properties": {
          "project": {"type": "string", "description": "a project path, or a project name as the board lists it"},
          "prompt": {"type": "string"},
          "human": {"type": "boolean", "description": "true only when the human typed the prompt himself in the app; ignored for scope agent"},
          "name": {"type": "string"},
          "worktree": {"type": "string", "description": "worktree name, empty for a random one; omit to run in the project checkout"},
          "assistant": {"type": "string", "description": "claude, codex or gemini"},
          "model": {"type": "string"},
          "launch": {"type": "boolean", "description": "false only creates the card in the backlog"},
          "images": {"type": "array", "maxItems": 6, "items": {"$ref": "#/components/schemas/Image"}},
          "machine": {"type": "string", "description": "where the card runs: a name from GET /v1/machines, or mac/local/here for this master; omit for the project default"}
        }
      },
      "PromptRequest": {"type": "object", "required": ["text"], "properties": {"text": {"type": "string", "description": "may be empty when images has some"}, "mode": {"type": "string", "enum": ["queue", "now"], "default": "queue"}, "images": {"type": "array", "maxItems": 6, "items": {"$ref": "#/components/schemas/Image"}}, "human": {"type": "boolean", "description": "true only when the human typed and sent this himself in a chat composer; ignored for scope agent"}}},
      "SlashCommand": {"type": "object", "required": ["name", "description", "source"], "properties": {"name": {"type": "string", "description": "without the leading slash; a plugin's is plugin:name"}, "description": {"type": "string", "description": "one line"}, "source": {"type": "string", "enum": ["kanban", "agent", "project", "user", "plugin"]}}},
      "SideChatRequest": {"type": "object", "required": ["kind"], "properties": {"kind": {"type": "string", "enum": ["btw", "catchup"]}, "question": {"type": "string", "description": "required for btw"}, "fresh": {"type": "boolean", "description": "catchup: run a new one even when the card's last catch-up still covers the session"}, "catchUpId": {"type": "string", "description": "btw: the run id of the catch-up this follows up on, so the exchange is kept with it"}, "history": {"type": "array", "description": "earlier exchanges of the same side chat, oldest first", "items": {"type": "object", "required": ["question", "answer"], "properties": {"question": {"type": "string"}, "answer": {"type": "string"}}}}}},
      "SideChatRun": {"type": "object", "properties": {"finishedAt": {"type": ["string", "null"], "format": "date-time"}, "reopened": {"type": ["boolean", "null"], "description": "true for the card's last catch-up returned again, finished, because the session has no message after the last one it covers"}, "followUps": {"type": ["array", "null"], "description": "the follow-ups asked in the side chat of a reopened catch-up", "items": {"type": "object", "properties": {"question": {"type": "string"}, "answer": {"type": "string"}}}}, "id": {"type": "string"}, "cardId": {"type": "string"}, "kind": {"type": "string", "enum": ["btw", "catchup"]}, "state": {"type": "string", "enum": ["running", "done", "failed"]}, "text": {"type": "string", "description": "the answer so far. A catchup answers in JSON Lines: {\"section\": \"asked|status|report|facts|waiting|blocked|other\", \"text\", \"refs\": [\"m7\"]}"}, "error": {"type": ["string", "null"]}, "since": {"type": ["object", "null"], "description": "the human's last message, where a catchup starts", "properties": {"text": {"type": "string"}, "at": {"type": ["string", "null"], "format": "date-time"}, "offset": {"type": ["integer", "null"]}}}, "refs": {"type": ["array", "null"], "description": "the messages a catchup can cite", "items": {"type": "object", "properties": {"ref": {"type": "string"}, "offset": {"type": "integer", "description": "byte offset in the transcript; a transcript message id starts with it"}, "role": {"type": "string"}, "at": {"type": ["string", "null"], "format": "date-time"}, "preview": {"type": "string"}}}}}},
      "Image": {"type": "object", "required": ["mediaType", "data"], "properties": {"mediaType": {"type": "string", "enum": ["image/png", "image/jpeg", "image/gif", "image/webp"]}, "data": {"type": "string", "contentEncoding": "base64", "description": "at most 5 MiB decoded"}}},
      "QueuedPrompt": {"type": "object", "required": ["id", "text"], "properties": {"id": {"type": "string"}, "text": {"type": "string"}, "imageCount": {"type": "integer", "description": "left out when 0"}}},
      "Event": {"type": "object", "properties": {
        "type": {"type": "string", "enum": ["board", "cards", "ping"]},
        "board": {"$ref": "#/components/schemas/Board"},
        "upserted": {"type": "array", "items": {"$ref": "#/components/schemas/Card"}},
        "removed": {"type": "array", "items": {"type": "string"}},
        "projects": {"type": "array", "items": {"$ref": "#/components/schemas/Project"}}
      }}
    }
  }
}
"""#
}
