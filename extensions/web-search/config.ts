// Backend selection from the environment and the model-facing texts that
// depend on it. Read once at load; exactly one backend is active.

export type Backend =
  | { kind: "none" }
  | { kind: "searxng"; base: string }
  | { kind: "searxng-invalid"; value: string }
  | { kind: "tavily"; key: string }
  | { kind: "brave"; key: string };

export const USER_AGENT = "pi-setup-web-search/1.0";

export const SETUP_MESSAGE = [
  "No web-search backend configured.",
  "Set one of these environment variables (the first one set wins), then restart pi or run /reload:",
  "  1. PI_SEARX_URL    a self-hosted SearXNG instance, e.g. http://127.0.0.1:8888 (private and free: queries stay on your instance)",
  "  2. TAVILY_API_KEY  Tavily, a third-party service (ranked results plus a synthesized answer)",
  "  3. BRAVE_API_KEY   the Brave Search API, a third-party service (free tier available)",
  "With the pi-setup Nix module: programs.pi.search.searxUrl sets PI_SEARX_URL; programs.pi.search.local runs an on-demand SearXNG on http://127.0.0.1:8888.",
].join("\n");

type Env = Record<string, string | undefined>;

function setting(env: Env, name: string): string | undefined {
  const v = env[name]?.trim();
  return v ? v : undefined;
}

/** The SearXNG base URL (origin plus path prefix, no trailing slash), or
 * null if `value` is not a plain absolute http(s) URL. */
function searxBase(value: string): string | null {
  let u: URL;
  try {
    u = new URL(value);
  } catch {
    return null;
  }
  if (u.protocol !== "http:" && u.protocol !== "https:") return null;
  if (u.username || u.password || u.search || u.hash) return null;
  return u.origin + u.pathname.replace(/\/+$/, "");
}

/** Precedence: PI_SEARX_URL, TAVILY_API_KEY, BRAVE_API_KEY. An invalid
 * PI_SEARX_URL still selects SearXNG, so no query falls back to a paid
 * third-party service. */
export function selectBackend(env: Env): Backend {
  const searx = setting(env, "PI_SEARX_URL");
  if (searx !== undefined) {
    const base = searxBase(searx);
    return base === null ? { kind: "searxng-invalid", value: searx } : { kind: "searxng", base };
  }
  const tavily = setting(env, "TAVILY_API_KEY");
  if (tavily !== undefined) return { kind: "tavily", key: tavily };
  const brave = setting(env, "BRAVE_API_KEY");
  if (brave !== undefined) return { kind: "brave", key: brave };
  return { kind: "none" };
}

export function backendName(b: Backend): string {
  switch (b.kind) {
    case "searxng":
      return `SearXNG (${b.base})`;
    case "searxng-invalid":
      return "SearXNG (invalid PI_SEARX_URL)";
    case "tavily":
      return "Tavily";
    case "brave":
      return "Brave Search";
    case "none":
      return "none";
  }
}

const RESULT_SHAPE = "Returns a ranked list of results, each with title, URL and snippet.";

export function searchDescription(b: Backend): string {
  switch (b.kind) {
    case "searxng":
      return `Search the web via the self-hosted SearXNG instance at ${b.base}. Queries stay on that instance (no third party). ${RESULT_SHAPE}`;
    case "searxng-invalid":
      return `Search the web via a self-hosted SearXNG instance. PI_SEARX_URL is set but not a valid http(s) URL, so every call fails until it is fixed. ${RESULT_SHAPE}`;
    case "tavily":
      return `Search the web via Tavily: queries are sent to that third party. ${RESULT_SHAPE} May lead with a synthesized answer.`;
    case "brave":
      return `Search the web via the Brave Search API: queries are sent to that third party. ${RESULT_SHAPE}`;
    case "none":
      return `Search the web. Not configured: ${SETUP_MESSAGE.split("\n")[0]} Calling this tool returns setup instructions. ${RESULT_SHAPE}`;
  }
}

/** The secrets of a backend, for redaction. */
export function secretsOf(b: Backend): string[] {
  return b.kind === "tavily" || b.kind === "brave" ? [b.key] : [];
}
