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
    "/v1/cards/{id}": {
      "parameters": [{"$ref": "#/components/parameters/CardId"}],
      "get": {"summary": "One card", "responses": {"200": {"description": "ok", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Card"}}}}, "404": {"$ref": "#/components/responses/Error"}}}
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
    "/v1/cards/{id}/queue/{promptId}": {
      "parameters": [{"$ref": "#/components/parameters/CardId"}, {"name": "promptId", "in": "path", "required": true, "description": "an id from the card's queuedPrompts", "schema": {"type": "string"}}],
      "post": {"summary": "Send a queued prompt now, interrupting the turn when one runs", "responses": {"204": {"description": "sent"}, "404": {"$ref": "#/components/responses/Error"}, "409": {"$ref": "#/components/responses/Error"}}},
      "delete": {"summary": "Drop a queued prompt", "responses": {"204": {"description": "removed"}, "404": {"$ref": "#/components/responses/Error"}}}
    },
    "/v1/cards/{id}/interrupt": {
      "parameters": [{"$ref": "#/components/parameters/CardId"}],
      "post": {"summary": "Interrupt the current turn", "responses": {"204": {"description": "done"}, "404": {"$ref": "#/components/responses/Error"}, "409": {"$ref": "#/components/responses/Error"}}}
    },
    "/v1/cards/{id}/resume": {
      "parameters": [{"$ref": "#/components/parameters/CardId"}],
      "post": {"summary": "Start the card's session again when it ended", "responses": {"200": {"description": "ok", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Card"}}}}, "404": {"$ref": "#/components/responses/Error"}}}
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
      "Health": {"type": "object", "properties": {"app": {"type": "string"}, "version": {"type": "string"}, "apiVersion": {"type": "integer"}, "hostName": {"type": "string"}, "features": {"type": "array", "items": {"type": "string", "enum": ["images", "queue", "terminalScroll"]}, "description": "what the server supports beyond apiVersion 1; missing on older servers"}}},
      "Device": {"type": "object", "properties": {"id": {"type": "string"}, "name": {"type": "string"}, "scope": {"type": "string", "enum": ["full", "agent"]}, "createdAt": {"type": "string", "format": "date-time"}, "lastSeenAt": {"type": ["string", "null"], "format": "date-time"}}},
      "PR": {"type": "object", "properties": {"number": {"type": "integer"}, "url": {"type": ["string", "null"]}, "title": {"type": ["string", "null"]}, "status": {"type": ["string", "null"], "description": "open, draft, merged or closed"}}},
      "Terminal": {"type": "object", "properties": {"sessionName": {"type": "string"}, "label": {"type": "string"}, "isPrimary": {"type": "boolean"}}},
      "Card": {
        "type": "object",
        "description": "isLive, isBusy and archived are left out when false, queuedPromptCount when 0, queuedPrompts, terminals and prs when empty, null fields always; a missing key means that default.",
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
          "runtime": {"type": "string", "enum": ["tmux", "agtop", "machine", "none"]},
          "isLive": {"type": "boolean"},
          "isBusy": {"type": "boolean"},
          "sessionId": {"type": ["string", "null"]},
          "terminals": {"type": "array", "items": {"$ref": "#/components/schemas/Terminal"}},
          "prs": {"type": "array", "items": {"$ref": "#/components/schemas/PR"}},
          "queuedPromptCount": {"type": "integer"},
          "queuedPrompts": {"type": "array", "items": {"$ref": "#/components/schemas/QueuedPrompt"}, "description": "oldest first"},
          "parentCardId": {"type": ["string", "null"]},
          "archived": {"type": "boolean"},
          "lastActivity": {"type": ["string", "null"], "format": "date-time"},
          "updatedAt": {"type": "string", "format": "date-time"}
        }
      },
      "Project": {"type": "object", "properties": {"path": {"type": "string"}, "name": {"type": "string"}}},
      "Board": {"type": "object", "properties": {"cards": {"type": "array", "items": {"$ref": "#/components/schemas/Card"}}, "projects": {"type": "array", "items": {"$ref": "#/components/schemas/Project"}}, "generatedAt": {"type": "string", "format": "date-time"}}},
      "Message": {"type": "object", "properties": {"id": {"type": "string"}, "role": {"type": "string", "enum": ["user", "assistant", "tool", "system"]}, "text": {"type": "string"}, "at": {"type": ["string", "null"], "format": "date-time"}}},
      "Transcript": {"type": "object", "properties": {"cardId": {"type": "string"}, "messages": {"type": "array", "items": {"$ref": "#/components/schemas/Message"}}, "olderCursor": {"type": ["string", "null"]}}},
      "TaskRequest": {
        "type": "object",
        "required": ["project", "prompt"],
        "properties": {
          "project": {"type": "string", "description": "a project path, or a project name as the board lists it"},
          "prompt": {"type": "string"},
          "name": {"type": "string"},
          "worktree": {"type": "string", "description": "worktree name, empty for a random one; omit to run in the project checkout"},
          "assistant": {"type": "string", "description": "claude, codex or gemini"},
          "model": {"type": "string"},
          "launch": {"type": "boolean", "description": "false only creates the card in the backlog"},
          "images": {"type": "array", "maxItems": 6, "items": {"$ref": "#/components/schemas/Image"}}
        }
      },
      "PromptRequest": {"type": "object", "required": ["text"], "properties": {"text": {"type": "string", "description": "may be empty when images has some"}, "mode": {"type": "string", "enum": ["queue", "now"], "default": "queue"}, "images": {"type": "array", "maxItems": 6, "items": {"$ref": "#/components/schemas/Image"}}}},
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
