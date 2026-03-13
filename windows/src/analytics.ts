import posthog from "posthog-js";

const POSTHOG_KEY = "phc_REPLACE_WITH_YOUR_KEY";
const POSTHOG_HOST = "https://us.i.posthog.com";

export function initAnalytics() {
  posthog.init(POSTHOG_KEY, {
    api_host: POSTHOG_HOST,
    autocapture: false,
    capture_pageview: false,
    persistence: "localStorage",
  });

  posthog.capture("app_opened", { platform: "windows" });
}

export function capture(event: string, properties: Record<string, unknown> = {}) {
  posthog.capture(event, { platform: "windows", ...properties });
}
