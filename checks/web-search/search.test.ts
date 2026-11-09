// Backend selection and the three search backends against a mocked fetch.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import http from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
  backendName,
  SETUP_MESSAGE,
  searchDescription,
  selectBackend,
} from "../../extensions/web-search/config.ts";
import { runSearch, type FetchLike } from "../../extensions/web-search/search.ts";

const SEARX = "http://127.0.0.1:8888";
const TAVILY_KEY = "tvly-test-0123456789abcdef";
const BRAVE_KEY = "brave-test-fedcba9876543210";

interface Call {
  url: string;
  method: string;
  headers: Record<string, string>;
  body?: string;
}

function mockFetch(respond: (call: Call) => Response | Promise<Response>): FetchLike & { calls: Call[] } {
  const calls: Call[] = [];
  const f = (async (url: string, init: { method: string; headers: Record<string, string>; body?: string; signal: AbortSignal }) => {
    const call = { url, method: init.method, headers: init.headers, body: init.body };
    calls.push(call);
    return respond(call);
  }) as FetchLike & { calls: Call[] };
  f.calls = calls;
  return f;
}

const json = (v: unknown, status = 200) =>
  new Response(JSON.stringify(v), { status, headers: { "content-type": "application/json" } });

// ---- selection --------------------------------------------------------------

test("selection: nothing set is unconfigured", () => {
  assert.equal(selectBackend({}).kind, "none");
  assert.equal(selectBackend({ PI_SEARX_URL: "  ", TAVILY_API_KEY: "", BRAVE_API_KEY: "\t" }).kind, "none");
});

test("selection: each single variable selects its backend", () => {
  assert.deepEqual(selectBackend({ PI_SEARX_URL: ` ${SEARX}/ ` }), { kind: "searxng", base: SEARX });
  assert.deepEqual(selectBackend({ TAVILY_API_KEY: ` ${TAVILY_KEY} ` }), { kind: "tavily", key: TAVILY_KEY });
  assert.deepEqual(selectBackend({ BRAVE_API_KEY: BRAVE_KEY }), { kind: "brave", key: BRAVE_KEY });
});

test("selection: precedence SearXNG > Tavily > Brave; whitespace-only ignored", () => {
  const all = { PI_SEARX_URL: SEARX, TAVILY_API_KEY: TAVILY_KEY, BRAVE_API_KEY: BRAVE_KEY };
  assert.equal(selectBackend(all).kind, "searxng");
  assert.equal(selectBackend({ ...all, PI_SEARX_URL: " " }).kind, "tavily");
  assert.equal(selectBackend({ BRAVE_API_KEY: BRAVE_KEY, TAVILY_API_KEY: TAVILY_KEY }).kind, "tavily");
  assert.equal(selectBackend({ BRAVE_API_KEY: BRAVE_KEY, TAVILY_API_KEY: "   " }).kind, "brave");
});

test("selection: a path prefix is kept, trailing slashes dropped", () => {
  assert.deepEqual(selectBackend({ PI_SEARX_URL: "https://search.example.org/searx//" }), {
    kind: "searxng",
    base: "https://search.example.org/searx",
  });
});

test("selection: an invalid PI_SEARX_URL stays SearXNG (no fallback)", () => {
  for (const bad of ["not a url", "ftp://example.org", "127.0.0.1:8888"]) {
    const b = selectBackend({ PI_SEARX_URL: bad, TAVILY_API_KEY: TAVILY_KEY });
    assert.deepEqual(b, { kind: "searxng-invalid", value: bad }, bad);
  }
});

test("descriptions name the backend and the privacy property", () => {
  const searx = searchDescription(selectBackend({ PI_SEARX_URL: SEARX }));
  assert.match(searx, /SearXNG/);
  assert.ok(searx.includes(SEARX));
  assert.doesNotMatch(searx, /third.party service/i);
  assert.match(searx, /no third party/i);
  for (const [env, name] of [[{ TAVILY_API_KEY: TAVILY_KEY }, "Tavily"], [{ BRAVE_API_KEY: BRAVE_KEY }, "Brave"]] as const) {
    const d = searchDescription(selectBackend(env));
    assert.match(d, new RegExp(name));
    assert.match(d, /third party/i);
    assert.ok(!d.includes(TAVILY_KEY) && !d.includes(BRAVE_KEY));
  }
  const none = searchDescription(selectBackend({}));
  assert.match(none, /not configured/i);
  assert.ok(none.includes(SETUP_MESSAGE.split("\n")[0]));
  for (const env of [{ PI_SEARX_URL: SEARX }, { TAVILY_API_KEY: TAVILY_KEY }, {}]) {
    assert.match(searchDescription(selectBackend(env)), /title.*URL.*snippet/i);
  }
});

test("display names", () => {
  assert.equal(backendName(selectBackend({ PI_SEARX_URL: SEARX })), `SearXNG (${SEARX})`);
  assert.equal(backendName(selectBackend({ TAVILY_API_KEY: TAVILY_KEY })), "Tavily");
  assert.equal(backendName(selectBackend({ BRAVE_API_KEY: BRAVE_KEY })), "Brave Search");
});

// ---- unconfigured / invalid / empty query -------------------------------------

test("unconfigured: setup message lists the variables in order, no request", async () => {
  const f = mockFetch(() => json({}));
  await assert.rejects(runSearch(selectBackend({}), { query: "nix" }, { fetch: f }), (e: Error) => {
    assert.match(e.message, /no web-search backend configured/i);
    const order = ["PI_SEARX_URL", "TAVILY_API_KEY", "BRAVE_API_KEY"].map((v) => e.message.indexOf(v));
    assert.ok(order.every((i) => i >= 0) && order[0] < order[1] && order[1] < order[2], String(order));
    assert.match(e.message, /http:\/\/127\.0\.0\.1:8888/);
    assert.match(e.message, /programs\.pi\.search\.searxUrl/);
    assert.match(e.message, /programs\.pi\.search\.local/);
    return true;
  });
  assert.equal(f.calls.length, 0);
});

test("invalid PI_SEARX_URL: error names the variable and value, no fallback request", async () => {
  const f = mockFetch(() => json({}));
  const b = selectBackend({ PI_SEARX_URL: "nope", TAVILY_API_KEY: TAVILY_KEY, BRAVE_API_KEY: BRAVE_KEY });
  await assert.rejects(runSearch(b, { query: "nix" }, { fetch: f }), /PI_SEARX_URL.*"nope"/);
  assert.equal(f.calls.length, 0);
});

test("whitespace-only query is an error without a request", async () => {
  const f = mockFetch(() => json({ results: [] }));
  await assert.rejects(runSearch(selectBackend({ PI_SEARX_URL: SEARX }), { query: "  \n " }, { fetch: f }), /query must not be empty/i);
  assert.equal(f.calls.length, 0);
});

// ---- SearXNG ------------------------------------------------------------------

test("SearXNG: request shape and mapping", async () => {
  const f = mockFetch(() =>
    json({
      results: [
        { title: "One", url: "https://one.example/", content: "first <b>hit</b>" },
        { title: "No URL", url: "", content: "dropped" },
        { title: 7, url: "https://two.example/", content: null },
        { title: "Three", url: "https://three.example/", content: "third" },
      ],
    }),
  );
  const r = await runSearch(selectBackend({ PI_SEARX_URL: "http://127.0.0.1:8888/searx/" }), { query: " nix flakes ", count: 2 }, { fetch: f });
  assert.equal(f.calls.length, 1);
  const u = new URL(f.calls[0].url);
  assert.equal(f.calls[0].method, "GET");
  assert.equal(u.origin + u.pathname, "http://127.0.0.1:8888/searx/search");
  assert.equal(u.searchParams.get("q"), "nix flakes");
  assert.equal(u.searchParams.get("format"), "json");
  assert.match(f.calls[0].headers["user-agent"], /^pi-setup-web-search\//);
  assert.equal(r.text, "1. One \u2014 https://one.example/\n   first hit\n\n2. (untitled) \u2014 https://two.example/");
  assert.deepEqual(r.details, {
    backend: "SearXNG (http://127.0.0.1:8888/searx)",
    query: "nix flakes",
    count: 2,
    results: [
      { title: "One", url: "https://one.example/", snippet: "first hit" },
      { title: "", url: "https://two.example/", snippet: "" },
    ],
  });
});

test("SearXNG: zero results", async () => {
  const r = await runSearch(selectBackend({ PI_SEARX_URL: SEARX }), { query: "x" }, { fetch: mockFetch(() => json({ results: [] })) });
  assert.equal(r.text, "No results.");
  assert.equal(r.details.count, 5);
});

test("SearXNG: 403 hints at JSON output and the instance root", async () => {
  const f = mockFetch(() => new Response("Forbidden", { status: 403 }));
  await assert.rejects(runSearch(selectBackend({ PI_SEARX_URL: SEARX }), { query: "x" }, { fetch: f }), (e: Error) => {
    assert.match(e.message, /SearXNG/);
    assert.match(e.message, /403/);
    assert.match(e.message, /json/);
    assert.match(e.message, /PI_SEARX_URL/);
    return true;
  });
});

test("SearXNG: non-JSON body or no results array is an unexpected response", async () => {
  for (const body of ["<html>", JSON.stringify({ answers: [] }), JSON.stringify([1, 2])]) {
    const f = mockFetch(() => new Response(body, { status: 200 }));
    await assert.rejects(runSearch(selectBackend({ PI_SEARX_URL: SEARX }), { query: "x" }, { fetch: f }), /SearXNG.*unexpected response/s, body);
  }
});

test("SearXNG: connection refused names the URL and hints at the service", async () => {
  const f = mockFetch(() => {
    throw new TypeError("fetch failed", { cause: Object.assign(new Error("connect ECONNREFUSED 127.0.0.1:8888"), { code: "ECONNREFUSED" }) });
  });
  await assert.rejects(runSearch(selectBackend({ PI_SEARX_URL: SEARX }), { query: "x" }, { fetch: f }), (e: Error) => {
    assert.ok(e.message.includes(SEARX));
    assert.match(e.message, /ECONNREFUSED/);
    assert.match(e.message, /not running/);
    assert.match(e.message, /programs\.pi\.search\.local/);
    return true;
  });
});

test("timeout and abort are distinguishable", async () => {
  const slow: FetchLike = (_url, init) =>
    new Promise((_, reject) => init.signal.addEventListener("abort", () => reject(init.signal.reason), { once: true }));
  await assert.rejects(runSearch(selectBackend({ PI_SEARX_URL: SEARX }), { query: "x" }, { fetch: slow, timeoutMs: 20 }), /timed out/);
  const ac = new AbortController();
  const p = runSearch(selectBackend({ TAVILY_API_KEY: TAVILY_KEY }), { query: "x" }, { fetch: slow, signal: ac.signal });
  ac.abort();
  await assert.rejects(p, (e: Error) => /aborted/i.test(e.message) && !/timed out/.test(e.message));
});

test("backend body is read with a 1 MiB cap", async () => {
  const big = JSON.stringify({ results: [{ title: "x".repeat(2 * 1024 * 1024), url: "https://a.example/" }] });
  const f = mockFetch(() => new Response(big, { status: 200 }));
  await assert.rejects(runSearch(selectBackend({ PI_SEARX_URL: SEARX }), { query: "x" }, { fetch: f }), /1 MiB/);
});

// ---- Tavily -------------------------------------------------------------------

test("Tavily: request shape, answer leads, mapping", async () => {
  const f = mockFetch(() =>
    json({
      answer: "Nix is a package manager.",
      results: [
        { title: "Nix", url: "https://nixos.org/", content: "Reproducible builds" },
        { title: "Pi", url: "https://pi.example/", content: "Agent" },
      ],
    }),
  );
  const r = await runSearch(selectBackend({ TAVILY_API_KEY: TAVILY_KEY }), { query: "what is nix", count: 3 }, { fetch: f });
  const c = f.calls[0];
  assert.equal(c.method, "POST");
  assert.equal(c.url, "https://api.tavily.com/search");
  assert.equal(c.headers.authorization, `Bearer ${TAVILY_KEY}`);
  assert.equal(c.headers["content-type"], "application/json");
  const body = JSON.parse(c.body ?? "{}");
  assert.equal(body.query, "what is nix");
  assert.equal(body.max_results, 3);
  assert.equal(body.include_answer, true);
  assert.equal(body.search_depth, "basic");
  assert.ok(!("api_key" in body));
  assert.equal(
    r.text,
    "Answer: Nix is a package manager.\n\n1. Nix \u2014 https://nixos.org/\n   Reproducible builds\n\n2. Pi \u2014 https://pi.example/\n   Agent",
  );
  assert.equal(r.details.answer, "Nix is a package manager.");
  assert.equal(r.details.backend, "Tavily");
});

test("Tavily: error excerpt at most 200 characters, key redacted", async () => {
  const f = mockFetch(() => new Response(`{"detail":"invalid key ${TAVILY_KEY}"}` + "z".repeat(500), { status: 401 }));
  await assert.rejects(runSearch(selectBackend({ TAVILY_API_KEY: TAVILY_KEY }), { query: "x" }, { fetch: f }), (e: Error) => {
    assert.match(e.message, /Tavily/);
    assert.match(e.message, /401/);
    assert.ok(!e.message.includes(TAVILY_KEY));
    const excerpt = e.message.slice(e.message.indexOf("{"));
    assert.ok(excerpt.length <= 200, `excerpt ${excerpt.length}`);
    return true;
  });
});

test("Tavily: malformed response", async () => {
  const f = mockFetch(() => json({ nothing: true }));
  await assert.rejects(runSearch(selectBackend({ TAVILY_API_KEY: TAVILY_KEY }), { query: "x" }, { fetch: f }), /Tavily.*unexpected response/);
});

// ---- Brave ----------------------------------------------------------------------

test("Brave: request shape, HTML stripped from snippets", async () => {
  const f = mockFetch(() =>
    json({
      web: {
        results: [
          { title: "A &amp; B", url: "https://a.example/", description: "The <strong>Nix</strong>   package\nmanager" },
          { title: "B", url: 12, description: "no url" },
        ],
      },
    }),
  );
  const r = await runSearch(selectBackend({ BRAVE_API_KEY: BRAVE_KEY }), { query: "nix", count: 4 }, { fetch: f });
  const c = f.calls[0];
  const u = new URL(c.url);
  assert.equal(c.method, "GET");
  assert.equal(u.origin + u.pathname, "https://api.search.brave.com/res/v1/web/search");
  assert.equal(u.searchParams.get("q"), "nix");
  assert.equal(u.searchParams.get("count"), "4");
  assert.equal(c.headers.accept, "application/json");
  assert.equal(c.headers["x-subscription-token"], BRAVE_KEY);
  assert.equal(r.text, "1. A & B \u2014 https://a.example/\n   The Nix package manager");
  assert.equal(r.details.backend, "Brave Search");
});

test("Brave: missing web object means zero results", async () => {
  const r = await runSearch(selectBackend({ BRAVE_API_KEY: BRAVE_KEY }), { query: "x" }, { fetch: mockFetch(() => json({ type: "search" })) });
  assert.equal(r.text, "No results.");
});

test("Brave: 429 and 401 hints", async () => {
  const b = selectBackend({ BRAVE_API_KEY: BRAVE_KEY });
  await assert.rejects(runSearch(b, { query: "x" }, { fetch: mockFetch(() => new Response("", { status: 429 })) }), /Brave Search.*429.*(rate limit|quota)/s);
  await assert.rejects(runSearch(b, { query: "x" }, { fetch: mockFetch(() => new Response("", { status: 401 })) }), /Brave Search.*401.*key.*invalid/s);
  await assert.rejects(runSearch(b, { query: "x" }, { fetch: mockFetch(() => new Response("", { status: 403 })) }), /403.*key.*invalid/s);
});

test("snippets are capped at 500 characters", async () => {
  const f = mockFetch(() => json({ results: [{ title: "t", url: "https://a.example/", content: "word ".repeat(300) }] }));
  const r = await runSearch(selectBackend({ PI_SEARX_URL: SEARX }), { query: "x" }, { fetch: f });
  assert.ok(r.details.results[0].snippet.length <= 500);
  assert.ok(r.details.results[0].snippet.endsWith("\u2026"));
});

// ---- property: keys never leak ---------------------------------------------------

function rng(seed: number) {
  let s = seed >>> 0;
  return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 2 ** 32);
}

test("property: API keys never appear in output, details, errors or descriptions", async () => {
  const rand = rng(42);
  const pick = <T>(xs: T[]) => xs[Math.floor(rand() * xs.length)];
  const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789-_";
  const key = () => Array.from({ length: 16 + Math.floor(rand() * 24) }, () => pick([...alphabet])).join("");
  for (let i = 0; i < 200; i++) {
    const tavily = key();
    const brave = key();
    const env: Record<string, string> = {};
    if (rand() < 0.3) env.PI_SEARX_URL = pick([SEARX, "bad url", " "]);
    if (rand() < 0.6) env.TAVILY_API_KEY = pick([tavily, ` ${tavily} `, ""]);
    if (rand() < 0.6) env.BRAVE_API_KEY = brave;
    const status = pick([200, 200, 401, 403, 429, 500]);
    // A hostile backend that reflects the whole request everywhere.
    const f = mockFetch((c) => {
      const echo = JSON.stringify(c);
      return new Response(
        JSON.stringify({ answer: echo, results: [{ title: echo, url: `https://e.example/${encodeURIComponent(echo)}`, content: echo }], web: { results: [{ title: echo, url: "https://e.example/", description: echo }] } }),
        { status },
      );
    });
    const b = selectBackend(env);
    const texts = [searchDescription(b), backendName(b)];
    try {
      const r = await runSearch(b, { query: pick(["x", " y "]), count: 1 + Math.floor(rand() * 10) }, { fetch: f });
      texts.push(r.text, JSON.stringify(r.details));
    } catch (e) {
      texts.push(String((e as Error).message), String((e as Error).stack));
    }
    for (const t of texts) {
      assert.ok(!t.includes(tavily), `tavily key leaked (case ${i}): ${t.slice(0, 200)}`);
      assert.ok(!t.includes(brave), `brave key leaked (case ${i}): ${t.slice(0, 200)}`);
      assert.ok(!t.includes(encodeURIComponent(tavily)) && !t.includes(encodeURIComponent(brave)));
    }
  }
});

// ---- the default transport -----------------------------------------------------------

test("SearXNG: the default transport ignores proxy variables (hostile HTTP_PROXY, NODE_USE_ENV_PROXY)", async (t) => {
  const proxied: string[] = [];
  const proxy = http.createServer((req, res) => {
    proxied.push(req.url ?? "");
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ results: [{ url: "https://proxy.example/", title: "via the proxy" }] }));
  });
  proxy.on("connect", (req, socket) => {
    proxied.push(`CONNECT ${req.url}`);
    socket.end("HTTP/1.1 403 Forbidden\r\n\r\n");
  });
  const searx = http.createServer((_req, res) => {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ results: [{ url: "https://direct.example/", title: "direct" }] }));
  });
  const listen = (s: http.Server) => new Promise<number>((res) => s.listen(0, "127.0.0.1", () => res((s.address() as { port: number }).port)));
  const [proxyPort, searxPort] = [await listen(proxy), await listen(searx)];
  const dir = mkdtempSync(join(tmpdir(), "web-search-proxy-"));
  t.after(() => {
    proxy.close();
    searx.close();
    rmSync(dir, { recursive: true, force: true });
  });
  // a fresh process, so the runtime reads the proxy variables at startup
  const script = join(dir, "search.mjs");
  const searchModule = new URL("../../extensions/web-search/search.ts", import.meta.url).href;
  writeFileSync(
    script,
    `const { runSearch } = await import(${JSON.stringify(searchModule)});\n` +
      `const r = await runSearch({ kind: "searxng", base: "http://127.0.0.1:${searxPort}" }, { query: "q" }, {});\n` +
      "console.log(JSON.stringify(r.details.results.map((x) => x.url)));\n",
  );
  const hostile = `http://127.0.0.1:${proxyPort}`;
  const env: Record<string, string> = { ...(process.env as Record<string, string>), NODE_USE_ENV_PROXY: "1", BUN_BE_BUN: "1" };
  for (const k of ["NO_PROXY", "no_proxy"]) delete env[k];
  for (const k of ["HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"]) env[k] = hostile;
  const out = await new Promise<string>((res, rej) =>
    execFile(process.execPath, [script], { env, timeout: 20_000 }, (e, stdout, stderr) => (e ? rej(new Error(`${e.message}\n${stderr}`)) : res(stdout))),
  );
  assert.deepEqual(proxied, []);
  assert.deepEqual(JSON.parse(out.trim().split("\n").at(-1) ?? ""), ["https://direct.example/"]);
});

test("SearXNG: the default transport passes status and body, caps the body and honours abort", async (t) => {
  let mode = "403";
  const searx = http.createServer((_req, res) => {
    if (mode === "403") {
      res.writeHead(403, { "content-type": "text/html" });
      res.end("forbidden");
    } else if (mode === "big") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(Buffer.alloc(2 * 1024 * 1024, 0x20));
    } // "hang": never answers
  });
  const port = await new Promise<number>((res) => searx.listen(0, "127.0.0.1", () => res((searx.address() as { port: number }).port)));
  t.after(() => {
    searx.closeAllConnections?.();
    searx.close();
  });
  const backend = { kind: "searxng", base: `http://127.0.0.1:${port}` } as const;
  await assert.rejects(runSearch(backend, { query: "q" }, {}), /HTTP 403\..*search\.formats/);
  mode = "big";
  await assert.rejects(runSearch(backend, { query: "q" }, {}), /larger than 1 MiB/);
  mode = "hang";
  const ac = new AbortController();
  setTimeout(() => ac.abort(), 30);
  await assert.rejects(runSearch(backend, { query: "q" }, { signal: ac.signal }), /aborted/);
  await assert.rejects(runSearch(backend, { query: "q" }, { timeoutMs: 30 }), /timed out/);
});

test("SearXNG: the default transport follows up to 3 same-origin redirects, then names the target", async (t) => {
  const seen: string[] = [];
  let other = 0;
  const elsewhere = http.createServer((_req, res) => {
    other++;
    res.end("{}");
  });
  const otherPort = await new Promise<number>((res) => elsewhere.listen(0, "127.0.0.1", () => res((elsewhere.address() as { port: number }).port)));
  const searx = http.createServer((req, res) => {
    seen.push(req.url ?? "");
    const u = new URL(req.url ?? "/", "http://127.0.0.1");
    const hop = (path: string, status = 301) => {
      res.writeHead(status, { location: path + u.search });
      res.end();
    };
    if (u.pathname === "/a/search") return hop("/b/search", 302);
    if (u.pathname === "/b/search") return hop("/c/search", 307);
    if (u.pathname === "/c/search") return hop("/searx/search", 308);
    if (u.pathname === "/loop/search") return hop("/loop/search");
    if (u.pathname === "/away/search") return hop(`http://127.0.0.1:${otherPort}/search`);
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ results: [{ title: "T", url: "https://r.example/", content: "" }] }));
  });
  const port = await new Promise<number>((res) => searx.listen(0, "127.0.0.1", () => res((searx.address() as { port: number }).port)));
  t.after(() => {
    for (const s of [searx, elsewhere]) {
      s.closeAllConnections?.();
      s.close();
    }
  });
  const base = (p: string) => ({ kind: "searxng", base: `http://127.0.0.1:${port}${p}` }) as const;
  const r = await runSearch(base("/a"), { query: "q" }, {});
  assert.equal(r.text, "1. T \u2014 https://r.example/");
  assert.deepEqual(
    seen.map((s) => s.split("?")[0]),
    ["/a/search", "/b/search", "/c/search", "/searx/search"],
  );
  assert.ok(seen.every((s) => s.endsWith("?q=q&format=json")));
  seen.length = 0;
  await assert.rejects(runSearch(base("/loop"), { query: "q" }, {}), (e: Error) => {
    assert.match(e.message, /redirected to http:\/\/127\.0\.0\.1:\d+\/loop\/search/);
    assert.doesNotMatch(e.message, /search\.formats/);
    return true;
  });
  assert.equal(seen.length, 4);
  await assert.rejects(runSearch(base("/away"), { query: "q" }, {}), (e: Error) => {
    assert.ok(e.message.includes(`redirected to http://127.0.0.1:${otherPort}/search`), e.message);
    assert.match(e.message, /PI_SEARX_URL/);
    assert.doesNotMatch(e.message, /search\.formats/);
    return true;
  });
  assert.equal(other, 0);
});

test("result URLs, titles and snippets cannot forge lines or carry control characters", async () => {
  const f = mockFetch(() =>
    json({
      results: [
        { title: "T\u001b[31mx\nY\u2028Z\u0000", url: " https://a.example/\nFAKE 2.\u0007 line\u0007", content: "c\r\n2. fake\u0085" },
        { title: "bad", url: "not a url\n3. fake", content: "" },
      ],
    }),
  );
  const r = await runSearch(selectBackend({ PI_SEARX_URL: SEARX }), { query: "x" }, { fetch: f });
  assert.equal(r.text, "1. T[31mx Y Z \u2014 https://a.example/FAKE%202.%07%20line\n   c 2. fake");
  assert.deepEqual(r.details.results, [{ title: "T[31mx Y Z", url: "https://a.example/FAKE%202.%07%20line", snippet: "c 2. fake" }]);
});
