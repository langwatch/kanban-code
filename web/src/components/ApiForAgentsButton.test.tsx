import { describe, test, expect, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { ApiForAgentsButton } from "./ApiForAgentsButton";

// Must be async: try/finally in a sync function runs the finally BEFORE
// the returned promise's async work completes, which would reset the URL
// out from under the clipboard click.
async function withToken(token: string, fn: () => Promise<void>): Promise<void> {
  const orig = window.location.href;
  window.history.replaceState(null, "", `/?token=${token}`);
  try { await fn(); } finally { window.history.replaceState(null, "", orig); }
}

describe("ApiForAgentsButton", () => {
  test("copies the tokenized OpenAPI URL via the injected copy fn", async () => {
    const copy = vi.fn(() => Promise.resolve(true));
    const user = userEvent.setup();
    await withToken("tk_unit", async () => {
      render(<ApiForAgentsButton copy={copy} />);
      await user.click(screen.getByRole("button", { name: /api url for agents/i }));
      await waitFor(() => expect(copy).toHaveBeenCalledWith(
        `${window.location.origin}/.well-known/openapi.json?token=tk_unit`,
      ));
    });
  });

  test("shows a transient 'Copied' state so the user has feedback", async () => {
    const copy = vi.fn(() => Promise.resolve(true));
    const user = userEvent.setup();
    await withToken("tk_unit", async () => {
      render(<ApiForAgentsButton copy={copy} />);
      await user.click(screen.getByRole("button", { name: /api url for agents/i }));
      expect(await screen.findByText("Copied")).toBeInTheDocument();
    });
  });

  test("opens the URL in a new tab when the clipboard isn't available", async () => {
    const copy = vi.fn(() => Promise.resolve(false));
    const openSpy = vi.spyOn(window, "open").mockReturnValue(null);
    const user = userEvent.setup();
    await withToken("tk_unit", async () => {
      render(<ApiForAgentsButton copy={copy} />);
      await user.click(screen.getByRole("button", { name: /api url for agents/i }));
      await waitFor(() => expect(openSpy).toHaveBeenCalledWith(
        `${window.location.origin}/.well-known/openapi.json?token=tk_unit`,
        "_blank",
        expect.stringContaining("noopener"),
      ));
    });
    openSpy.mockRestore();
  });
});
