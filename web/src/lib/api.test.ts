import { describe, test, expect } from "vitest";
import { imageFilesystemPathToHttpUrl, openApiSpecUrl } from "./api";

function withToken(token: string, fn: () => void): void {
  const orig = window.location.href;
  window.history.replaceState(null, "", `/?token=${token}`);
  try { fn(); } finally { window.history.replaceState(null, "", orig); }
}

describe("imageFilesystemPathToHttpUrl", () => {
  test("maps a canonical absolute path to a tokenized /api/images URL", () => {
    withToken("tk_abc", () => {
      const url = imageFilesystemPathToHttpUrl(
        "/Users/me/.kanban-code/channels/images/img_abc123/0.png",
      );
      expect(url).toBe("/api/images/img_abc123/0.png?token=tk_abc");
    });
  });

  test("handles msg_ prefix (DM attachments reuse the same shape)", () => {
    withToken("t", () => {
      expect(imageFilesystemPathToHttpUrl("/x/channels/images/msg_xyz/2.jpg"))
        .toBe("/api/images/msg_xyz/2.jpg?token=t");
    });
  });

  test("returns null for a path that isn't under channels/images/", () => {
    withToken("t", () => {
      expect(imageFilesystemPathToHttpUrl("/tmp/random.png")).toBeNull();
    });
  });

  test("returns null when filename is missing", () => {
    withToken("t", () => {
      expect(imageFilesystemPathToHttpUrl("/x/channels/images/img_abc/")).toBeNull();
    });
  });
});

describe("openApiSpecUrl", () => {
  test("builds an absolute URL with the token baked in", () => {
    withToken("tk_abc123", () => {
      expect(openApiSpecUrl())
        .toBe(`${window.location.origin}/.well-known/openapi.json?token=tk_abc123`);
    });
  });

  test("omits the query entirely when there's no token", () => {
    const orig = window.location.href;
    window.history.replaceState(null, "", "/");
    try {
      expect(openApiSpecUrl())
        .toBe(`${window.location.origin}/.well-known/openapi.json`);
    } finally { window.history.replaceState(null, "", orig); }
  });
});
