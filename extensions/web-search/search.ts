// web_search: one request to the selected backend, normalised results and
// the model-facing text. The fetch function can be injected (tests mock it);
// by default SearXNG is asked over a direct node:http(s) connection and the
// third-party APIs through the global fetch.

import http from "node:http";
import https from "node:https";
import { backendName, type Backend, SETUP_MESSAGE, secretsOf, USER_AGENT } from "./config.ts";
import { capSnippet, cleanInline, collapseWhitespace, safeText } from "./text.ts";

export interface FetchInit {
  method: string;
  headers: Record<string, string>;
  body?: string;
  signal: AbortSignal;
}

/** The part of a fetch `Response` this module reads. */
export interface FetchResponse {
  status: number;
  body: ReadableStream<Uint8Array> | null;
  headers?: { get(name: string): string | null };
}

/** The subset of the global `fetch` this module uses. */
export type FetchLike = (url: string, init: FetchInit) => Promise<FetchResponse>;

export interface SearchParams {
  query: string;
  count?: number;
}

export interface SearchResult {
  title: string;
  url: string;
  snippet: string;
}

export interface SearchDetails {
  backend: string;
  query: string;
  count: number;
  results: SearchResult[];
  answer?: string;
}

export interface SearchDeps {
  /** default: `directFetch` for SearXNG, the global fetch for Tavily and Brave */
  fetch?: FetchLike;
  signal?: AbortSignal;
  timeoutMs?: number;
}

export const SEARCH_TIMEOUT_MS = 20_000;
export const MAX_BACKEND_BYTES = 1024 * 1024;
const TAVILY_URL = "https://api.tavily.com/search";
const BRAVE_URL = "https://api.search.brave.com/res/v1/web/search";

interface Raw {
  results: unknown[];
  answer?: unknown;
}

interface Request {
  url: string;
  init: Omit<FetchInit, "signal">;
  /** names the target in "unreachable" errors */
  target: string;
  /** maps the parsed body to raw results, or null if malformed */
  parse: (body: unknown) => Raw | null;
  /** extra text for HTTP errors */
  httpError: (status: number, body: string) => string;
  unreachableHint: string;
}

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);

function redactor(secrets: string[]): (s: string) => string {
  const keys = secrets.filter((k) => k.length >= 4);
  return (s) => keys.reduce((acc, k) => acc.split(k).join("[redacted]"), s);
}

function searxRequest(base: string, query: string): Request {
  const hint =
    "Make sure JSON output is enabled on the instance (search.formats in its settings.yml must include json; " +
    "a 403 is the usual symptom) and that PI_SEARX_URL points at the instance root.";
  return {
    url: `${base}/search?${new URLSearchParams({ q: query, format: "json" })}`,
    init: { method: "GET", headers: { "user-agent": USER_AGENT, accept: "application/json" } },
    target: base,
    parse: (body) => (isObject(body) && Array.isArray(body.results) ? { results: body.results } : null),
    httpError: () => hint,
    unreachableHint:
      "The instance (with programs.pi.search.local: the on-demand local service) is probably not running.",
  };
}

function tavilyRequest(key: string, query: string, count: number): Request {
  return {
    url: TAVILY_URL,
    init: {
      method: "POST",
      headers: {
        "user-agent": USER_AGENT,
        "content-type": "application/json",
        accept: "application/json",
        authorization: `Bearer ${key}`,
      },
      body: JSON.stringify({ query, max_results: count, include_answer: true, search_depth: "basic" }),
    },
    target: "api.tavily.com",
    parse: (body) => (isObject(body) && Array.isArray(body.results) ? { results: body.results, answer: body.answer } : null),
    httpError: (_status, body) => collapseWhitespace(body).slice(0, 200),
    unreachableHint: "",
  };
}

function braveRequest(key: string, query: string, count: number): Request {
  return {
    url: `${BRAVE_URL}?${new URLSearchParams({ q: query, count: String(count) })}`,
    init: {
      method: "GET",
      headers: { "user-agent": USER_AGENT, accept: "application/json", "x-subscription-token": key },
    },
    target: "api.search.brave.com",
    parse: (body) => {
      if (!isObject(body)) return null;
      if (body.web === undefined) return { results: [] };
      return isObject(body.web) && Array.isArray(body.web.results) ? { results: body.web.results } : null;
    },
    httpError: (status) => {
      if (status === 429) return "The rate limit or the monthly free quota of the key is exhausted.";
      if (status === 401 || status === 403) return "The API key (BRAVE_API_KEY) is invalid.";
      return "";
    },
    unreachableHint: "",
  };
}

/** Same-origin redirects the direct SearXNG connection follows (a trailing
 * slash or a path prefix behind a reverse proxy); any other redirect is
 * returned as is and reported with its target. */
export const MAX_SEARX_REDIRECTS = 3;
const REDIRECT_STATUSES = new Set([301, 302, 303, 307, 308]);

/** A FetchLike over node:http/https with a direct connection: no
 * environment proxy (Bun's global fetch honours HTTP_PROXY even for a
 * loopback URL, so queries meant for the user's own instance could leave
 * the machine), no connection pooling, no content encoding. It follows at
 * most MAX_SEARX_REDIRECTS redirects within the same origin. */
export const directFetch: FetchLike = async (url, init) => {
  let target = new URL(url);
  let method = init.method;
  let body = init.body;
  for (let hops = 0; ; hops++) {
    const res = await directRequest(target, { ...init, method, body });
    const location = res.headers?.get("location");
    if (!REDIRECT_STATUSES.has(res.status) || !location || hops >= MAX_SEARX_REDIRECTS) return res;
    let next: URL;
    try {
      next = new URL(location, target);
    } catch {
      return res;
    }
    if (next.origin !== target.origin) return res;
    await res.body?.cancel().catch(() => {});
    if (res.status === 303 || ((res.status === 301 || res.status === 302) && method === "POST")) {
      method = "GET";
      body = undefined;
    }
    target = next;
  }
};

function directRequest(target: URL, init: FetchInit): Promise<FetchResponse> {
  return new Promise((resolve, reject) => {
    const request = (target.protocol === "https:" ? https : http).request(
      target,
      {
        method: init.method,
        headers: { ...init.headers, "accept-encoding": "identity" },
        agent: false,
        signal: init.signal,
      },
      (res) => {
        const chunks = res[Symbol.asyncIterator]();
        const body = new ReadableStream<Uint8Array>({
          async pull(controller) {
            try {
              const step = await chunks.next();
              if (step.done) controller.close();
              else controller.enqueue(new Uint8Array(step.value));
            } catch (e) {
              controller.error(e);
            }
          },
          cancel() {
            res.destroy();
          },
        });
        const headers = {
          get: (name: string) => {
            const v = res.headers[name.toLowerCase()];
            return v === undefined ? null : Array.isArray(v) ? v.join(", ") : v;
          },
        };
        resolve({ status: res.statusCode ?? 0, body, headers });
      },
    );
    request.on("error", reject);
    request.end(init.body);
  });
}

const defaultFetch = (backend: Backend): FetchLike => (backend.kind === "searxng" ? directFetch : globalThis.fetch);

async function readCapped(res: FetchResponse, cap: number, name: string): Promise<string> {
  if (!res.body) return "";
  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > cap) {
      await reader.cancel().catch(() => {});
      throw new Error(`${name} returned a response larger than 1 MiB; refusing to parse it.`);
    }
    chunks.push(value);
  }
  return Buffer.concat(chunks).toString("utf8");
}

function causeOf(e: unknown): string {
  const err = e as { message?: unknown; code?: unknown; cause?: { message?: unknown; code?: unknown } };
  const inner = err?.cause;
  const code = inner?.code ?? err?.code;
  const message = inner?.message ?? err?.message ?? String(e);
  return typeof code === "string" && !String(message).includes(code) ? `${code}: ${message}` : String(message);
}

/** The URL in its serialised form (line breaks and tabs removed, spaces and
 * control characters percent-encoded, so it cannot forge a line), or null
 * if it is not an absolute URL. */
function absoluteUrl(raw: string): string | null {
  try {
    return new URL(raw.trim()).href;
  } catch {
    return null;
  }
}

function normalise(raw: unknown[], count: number, snippetField: string): SearchResult[] {
  const out: SearchResult[] = [];
  for (const r of raw) {
    if (out.length >= count) break;
    if (!isObject(r)) continue;
    const url = typeof r.url === "string" ? absoluteUrl(r.url) : null;
    if (url === null) continue;
    out.push({ title: cleanInline(r.title), url, snippet: capSnippet(cleanInline(r[snippetField])) });
  }
  return out;
}

export function formatResults(results: SearchResult[], answer?: string): string {
  const parts: string[] = [];
  if (answer) parts.push(`Answer: ${answer}`);
  if (results.length === 0) parts.push("No results.");
  results.forEach((r, i) => {
    const head = `${i + 1}. ${r.title || "(untitled)"} \u2014 ${r.url}`;
    parts.push(r.snippet ? `${head}\n   ${r.snippet}` : head);
  });
  return parts.join("\n\n");
}

/** Runs one search. Throws an Error with the cause on every failure. */
export async function runSearch(
  backend: Backend,
  params: SearchParams,
  deps: SearchDeps,
): Promise<{ text: string; details: SearchDetails }> {
  const redact = redactor(secretsOf(backend));
  try {
    return await search(backend, params, deps, redact);
  } catch (e) {
    const err = e instanceof Error ? e : new Error(String(e));
    throw new Error(redact(err.message));
  }
}

async function search(
  backend: Backend,
  params: SearchParams,
  deps: SearchDeps,
  redact: (s: string) => string,
): Promise<{ text: string; details: SearchDetails }> {
  if (backend.kind === "none") throw new Error(SETUP_MESSAGE);
  if (backend.kind === "searxng-invalid") {
    throw new Error(
      `PI_SEARX_URL is set to "${backend.value}", which is not a valid absolute http(s) URL ` +
        "of a SearXNG instance root (for example http://127.0.0.1:8888).",
    );
  }
  const query = typeof params.query === "string" ? params.query.trim() : "";
  if (query === "") throw new Error("The search query must not be empty.");
  const requested = Number.isFinite(params.count) ? Math.trunc(params.count as number) : 5;
  const count = Math.min(10, Math.max(1, requested));
  const name = backendName(backend);
  const req =
    backend.kind === "searxng"
      ? searxRequest(backend.base, query)
      : backend.kind === "tavily"
        ? tavilyRequest(backend.key, query, count)
        : braveRequest(backend.key, query, count);

  const timeoutMs = deps.timeoutMs ?? SEARCH_TIMEOUT_MS;
  const timeout = new AbortController();
  const timer = setTimeout(() => timeout.abort(), timeoutMs);
  const signals = [timeout.signal, ...(deps.signal ? [deps.signal] : [])];
  const signal = AbortSignal.any(signals);
  const stopped = (): Error | null => {
    if (deps.signal?.aborted) return new Error(`${name}: the search was aborted.`);
    if (timeout.signal.aborted) return new Error(`${name}: the search timed out after ${timeoutMs / 1000} s.`);
    return null;
  };
  try {
    let res: FetchResponse;
    try {
      res = await (deps.fetch ?? defaultFetch(backend))(req.url, { ...req.init, signal });
    } catch (e) {
      const why = stopped();
      if (why) throw why;
      const hint = req.unreachableHint ? ` ${req.unreachableHint}` : "";
      throw new Error(`${name}: cannot reach ${req.target} (${causeOf(e)}).${hint}`);
    }
    let body: string;
    try {
      body = await readCapped(res, MAX_BACKEND_BYTES, name);
    } catch (e) {
      throw stopped() ?? e;
    }
    const location = REDIRECT_STATUSES.has(res.status) ? res.headers?.get("location") : null;
    if (location) {
      let to: string;
      try {
        to = new URL(location, req.url).href;
      } catch {
        to = safeText(location);
      }
      throw new Error(
        `${name} returned HTTP ${res.status}, redirected to ${to.slice(0, 300)}; only ` +
          `${MAX_SEARX_REDIRECTS} redirects within the same origin are followed. Set PI_SEARX_URL to the address ` +
          "the instance answers at.",
      );
    }
    if (res.status < 200 || res.status > 299) {
      const extra = redact(req.httpError(res.status, redact(body)));
      throw new Error(`${name} returned HTTP ${res.status}.${extra ? ` ${extra}` : ""}`);
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(body);
    } catch {
      parsed = undefined;
    }
    const raw = req.parse(parsed);
    if (raw === null) {
      const hint = backend.kind === "searxng" ? ` ${req.httpError(res.status, "")}` : "";
      throw new Error(`${name} returned an unexpected response (expected JSON with a results list).${hint}`);
    }
    const snippetField = backend.kind === "brave" ? "description" : "content";
    const results = normalise(raw.results, count, snippetField).map((r) => ({
      title: redact(r.title),
      url: redact(r.url),
      snippet: redact(r.snippet),
    }));
    const answer = backend.kind === "tavily" ? redact(cleanInline(raw.answer)) : "";
    const details: SearchDetails = { backend: name, query, count, results };
    if (answer) details.answer = answer;
    return { text: formatResults(results, answer || undefined), details };
  } finally {
    clearTimeout(timer);
  }
}
