// web_fetch against an injected transport and resolver: SSRF guard at every
// hop, connect-time pinning, redirects, content types, size caps, charsets,
// timeouts. Private addresses are assembled at run time (leak scan).
import assert from "node:assert/strict";
import http from "node:http";
import net from "node:net";
import { test } from "node:test";
import zlib from "node:zlib";
import { decodeText, mediaKind } from "../../extensions/web-search/decode.ts";
import {
  createNodeTransport,
  pinnedLookup,
  type Resolver,
  type Transport,
  type TransportRequest,
  webFetch,
} from "../../extensions/web-search/fetch.ts";

const v4 = (...o: number[]) => o.join(".");
const PUBLIC = "93.184.216.34";
const PRIVATE = v4(10, 0, 0, 7);
const http_ = (host: string, path = "/") => `${"http"}://${host}${path}`;

interface Reply {
  status?: number;
  statusText?: string;
  headers?: Record<string, string>;
  body?: string | Buffer | Buffer[];
}

interface Mock {
  transport: Transport;
  requests: TransportRequest[];
  closed: number;
  pulled: number;
}

function mockTransport(route: (url: URL) => Reply): Mock {
  const m: Mock = { requests: [], closed: 0, pulled: 0, transport: async () => ({}) as never };
  m.transport = async (req) => {
    m.requests.push(req);
    const r = route(req.url);
    const parts = r.body === undefined ? [] : Array.isArray(r.body) ? r.body : [Buffer.from(r.body)];
    return {
      status: r.status ?? 200,
      statusText: r.statusText ?? "OK",
      headers: Object.fromEntries(Object.entries(r.headers ?? { "content-type": "text/plain" }).map(([k, v]) => [k.toLowerCase(), v])),
      body: (async function* () {
        for (const p of parts) {
          m.pulled++;
          yield p;
        }
      })(),
      close: () => {
        m.closed++;
      },
    };
  };
  return m;
}

const publicResolver: Resolver = async () => [PUBLIC];
const run = (url: string, m: Mock, extra: Partial<Parameters<typeof webFetch>[1]> = {}) =>
  webFetch(url, { transport: m.transport, resolver: publicResolver, ...extra });

// ---- success shape -------------------------------------------------------------------

test("HTML page: header, converted content, details", async () => {
  const m = mockTransport(() => ({
    headers: { "content-type": "text/html; charset=utf-8" },
    body: "<html><head><title>Hello</title></head><body><nav>n</nav><h1>Hi</h1><p>See <a href='/x'>x</a>.</p></body></html>",
  }));
  const r = await run("https://example.com/page#frag", m);
  assert.equal(r.text, "Title: Hello\nURL: https://example.com/page\n\n# Hi\n\nSee [x](https://example.com/x).");
  assert.equal(m.requests[0].url.href, "https://example.com/page");
  assert.deepEqual(m.requests[0].addresses, [PUBLIC]);
  assert.equal(m.requests[0].host, "example.com");
  const h = m.requests[0].headers;
  assert.match(h["user-agent"], /^pi-setup-web-search\//);
  assert.match(h.accept, /^text\/html/);
  assert.ok(h.accept.indexOf("text/markdown") < h.accept.indexOf("*/*"));
  assert.equal(h["accept-encoding"], "gzip, deflate, br");
  assert.ok(!("cookie" in h) && !("authorization" in h));
  assert.equal(r.details.status, 200);
  assert.equal(r.details.title, "Hello");
  assert.equal(r.details.url, "https://example.com/page#frag");
  assert.equal(r.details.finalUrl, "https://example.com/page");
  assert.equal(r.details.contentType, "text/html; charset=utf-8");
  assert.equal(r.details.truncated, false);
  assert.equal(r.details.chars, r.text.length);
  assert.ok(r.details.bytes > 0);
  assert.equal(m.closed, 1);
});

test("plain text, markdown, JSON (pretty), XML (raw)", async () => {
  const cases: [string, string, string][] = [
    ["text/plain", "a  b\n", "a  b\n"],
    ["text/markdown", "# T\n", "# T\n"],
    ["application/json", '{"a":[1,2]}', '{\n  "a": [\n    1,\n    2\n  ]\n}'],
    ["application/ld+json", '{"a":1}', '{\n  "a": 1\n}'],
    ["application/json", "{broken", "{broken"],
    ["application/xml", "<r><x>1</x></r>", "<r><x>1</x></r>"],
    ["image/svg+xml", "<svg/>", "<svg/>"],
  ];
  for (const [type, body, out] of cases) {
    const r = await run("https://example.com/f", mockTransport(() => ({ headers: { "content-type": type }, body })));
    assert.equal(r.text, `URL: https://example.com/f\n\n${out}`, type);
  }
});

test("redirects: followed, final URL and requested URL in the header", async () => {
  const m = mockTransport((u): Reply =>
    u.pathname === "/old" ? { status: 301, headers: { location: "/new" } } : { headers: { "content-type": "text/plain" }, body: "moved" },
  );
  const r = await run("https://example.com/old", m);
  assert.equal(r.text, "URL: https://example.com/new\nRequested URL: https://example.com/old\n\nmoved");
  assert.equal(r.details.finalUrl, "https://example.com/new");
  assert.equal(m.closed, 2);
});

test("redirects: 5 hops are followed, the 6th fails with the limit", async () => {
  const chain = (hops: number) =>
    mockTransport((u) => {
      const n = Number(u.pathname.slice(1));
      return n < hops ? { status: 302, headers: { location: `/${n + 1}` } } : { body: "end" };
    });
  const ok = await run("https://example.com/0", chain(5));
  assert.match(ok.text, /URL: https:\/\/example\.com\/5/);
  await assert.rejects(run("https://example.com/0", chain(6)), /too many redirects.*5/i);
});

test("redirects: every followed status; 3xx without Location; other 3xx are HTTP errors", async () => {
  for (const status of [301, 302, 303, 307, 308]) {
    const r = await run("https://example.com/a", mockTransport((u) => (u.pathname === "/a" ? { status, headers: { location: "/b" } } : { body: "b" })));
    assert.match(r.text, /\/b\n/, String(status));
  }
  await assert.rejects(run("https://example.com/", mockTransport(() => ({ status: 302, headers: {} }))), /302.*Location/);
  await assert.rejects(run("https://example.com/", mockTransport(() => ({ status: 304, statusText: "Not Modified", headers: { location: "/x" } }))), /HTTP 304 Not Modified/);
});

test("redirect to a private address or to file: is blocked at that hop", async () => {
  for (const target of [http_(PRIVATE, "/admin"), http_("[::1]"), "file:///etc/passwd", http_("localhost", ":8080/")]) {
    const m = mockTransport((u) => (u.hostname === "example.com" ? { status: 302, headers: { location: target } } : { body: "secret" }));
    await assert.rejects(run("https://example.com/", m), /not permitted|only http and https/, target);
    assert.equal(m.requests.length, 1, target);
  }
});

test("redirect to a host name resolving privately is blocked", async () => {
  const m = mockTransport((u) => (u.hostname === "example.com" ? { status: 302, headers: { location: "https://internal.example/" } } : { body: "secret" }));
  const resolver: Resolver = async (h) => (h === "internal.example" ? [PRIVATE] : [PUBLIC]);
  await assert.rejects(run("https://example.com/", m, { resolver }), (e: Error) => e.message.includes("internal.example") && e.message.includes(PRIVATE));
  assert.equal(m.requests.length, 1);
});

// ---- guard before I/O ------------------------------------------------------------------

test("blocked targets never reach the resolver or the transport", async () => {
  let resolved = 0;
  const resolver: Resolver = async () => {
    resolved++;
    return [PUBLIC];
  };
  const m = mockTransport(() => ({ body: "x" }));
  for (const u of ["file:///etc/passwd", "ftp://example.com/", http_("localhost"), http_(v4(127, 0, 0, 1)), http_("[fd00::1]"), "nonsense"]) {
    await assert.rejects(run(u, m, { resolver }), Error, u);
  }
  assert.equal(resolved, 0);
  assert.equal(m.requests.length, 0);
});

test("a host resolving to one public and one private address is blocked", async () => {
  const m = mockTransport(() => ({ body: "x" }));
  await assert.rejects(
    run("https://mixed.example/", m, { resolver: async () => [PUBLIC, PRIVATE] }),
    (e: Error) => e.message.includes("mixed.example") && e.message.includes(PRIVATE) && /not permitted/.test(e.message),
  );
  assert.equal(m.requests.length, 0);
});

test("DNS failure names the host", async () => {
  const resolver: Resolver = async () => {
    throw Object.assign(new Error("getaddrinfo ENOTFOUND nowhere.example"), { code: "ENOTFOUND" });
  };
  await assert.rejects(run("https://nowhere.example/", mockTransport(() => ({})), { resolver }), /nowhere\.example/);
});

test("IP literals skip DNS and are pinned as given", async () => {
  let resolved = 0;
  const m = mockTransport(() => ({ body: "x" }));
  await run(http_(PUBLIC), m, {
    resolver: async () => {
      resolved++;
      return [PUBLIC];
    },
  });
  assert.equal(resolved, 0);
  assert.deepEqual(m.requests[0].addresses, [PUBLIC]);
});

test("connect-time pin: a second, private DNS answer is never used", async () => {
  let calls = 0;
  const rebinding: Resolver = async () => (calls++ === 0 ? [PUBLIC] : [PRIVATE]);
  const m = mockTransport(() => ({ body: "x" }));
  await run("https://rebind.example/", m, { resolver: rebinding });
  assert.equal(calls, 1);
  assert.deepEqual(m.requests[0].addresses, [PUBLIC]);
});

test("pinnedLookup answers only with the validated addresses and refuses blocked ones", async () => {
  const lookup = pinnedLookup([PUBLIC, "2606:4700::1111"]);
  const all = await new Promise<unknown>((res, rej) => lookup("rebind.example", { all: true }, (e, a) => (e ? rej(e) : res(a))));
  assert.deepEqual(all, [
    { address: PUBLIC, family: 4 },
    { address: "2606:4700::1111", family: 6 },
  ]);
  const one = await new Promise<unknown[]>((res, rej) => lookup("rebind.example", { family: 6 }, (e, a, f) => (e ? rej(e) : res([a, f]))));
  assert.deepEqual(one, ["2606:4700::1111", 6]);
  const bad = pinnedLookup([PRIVATE]);
  await assert.rejects(new Promise((res, rej) => bad("x.example", { all: true }, (e, a) => (e ? rej(e) : res(a)))), /not permitted/);
});

test("nodeTransport connects to the pinned address, not to a fresh lookup", async (t) => {
  const server = http.createServer((req, res) => {
    res.writeHead(200, { "content-type": "text/plain", "x-host": req.headers.host ?? "" });
    res.end("pinned");
  });
  await new Promise<void>((res) => server.listen(0, v4(127, 0, 0, 1), res));
  t.after(() => server.close());
  const port = (server.address() as { port: number }).port;
  // `.invalid` never resolves: reaching the server proves the pin was used.
  // The guard is disabled for this loopback server only.
  const transport = createNodeTransport(() => false);
  const res = await transport({
    url: new URL(`${"http"}://pinned.invalid:${port}/x`),
    host: "pinned.invalid",
    addresses: [v4(127, 0, 0, 1)],
    headers: { "user-agent": "test" },
    signal: new AbortController().signal,
  });
  const chunks: Buffer[] = [];
  for await (const c of res.body) chunks.push(Buffer.from(c));
  res.close();
  assert.equal(res.status, 200);
  assert.equal(res.headers["x-host"], `pinned.invalid:${port}`);
  assert.equal(Buffer.concat(chunks).toString(), "pinned");
});

// ---- response checks --------------------------------------------------------------------

test("HTTP errors carry status and reason", async () => {
  await assert.rejects(run("https://example.com/", mockTransport(() => ({ status: 404, statusText: "Not Found", body: "nope" }))), /HTTP 404 Not Found/);
  await assert.rejects(run("https://example.com/", mockTransport(() => ({ status: 503, statusText: "Service Unavailable" }))), /HTTP 503/);
});

test("content types: allowlist, case-insensitive, parameters ignored", async () => {
  for (const type of ["TEXT/HTML; Charset=UTF-8", "text/csv", "application/xhtml+xml", "application/atom+xml", "application/vnd.api+json"]) {
    await run("https://example.com/", mockTransport(() => ({ headers: { "content-type": type }, body: "<p>x</p>" })));
  }
  for (const type of ["image/png", "application/pdf", "application/octet-stream", "video/mp4", "application/zip"]) {
    const m = mockTransport(() => ({ headers: { "content-type": type }, body: "x" }));
    await assert.rejects(run("https://example.com/", m), (e: Error) => e.message.includes(type), type);
    assert.equal(m.pulled, 0, type);
    assert.equal(m.closed, 1, type);
  }
});

test("missing content type is sniffed", async () => {
  const sniff = (body: string | Buffer) => run("https://example.com/", mockTransport(() => ({ headers: {}, body })));
  assert.equal((await sniff("\ufeff  <!DOCTYPE html><title>T</title><p>x</p>")).text, "Title: T\nURL: https://example.com/\n\nx");
  assert.equal((await sniff("<HTML><p>y</p>")).text, "URL: https://example.com/\n\ny");
  assert.equal((await sniff("<p>not sniffed as html</p>")).text, "URL: https://example.com/\n\n<p>not sniffed as html</p>");
  await assert.rejects(sniff(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x00, 0x01])), /binary/);
});

test("mediaKind table", () => {
  assert.equal(mediaKind("text/html"), "html");
  assert.equal(mediaKind("application/xhtml+xml"), "html");
  assert.equal(mediaKind("text/xml"), "xml");
  assert.equal(mediaKind("application/rss+xml"), "xml");
  assert.equal(mediaKind("application/problem+json"), "json");
  assert.equal(mediaKind("text/x-shellscript"), "text");
  assert.equal(mediaKind("application/javascript"), null);
});

const CAP = 2 * 1024 * 1024;

test("size: declared Content-Length over the cap fails before reading", async () => {
  const m = mockTransport(() => ({ headers: { "content-type": "text/plain", "content-length": String(CAP + 1) }, body: "x" }));
  await assert.rejects(run("https://example.com/", m), (e: Error) => e.message.includes(String(CAP)) && e.message.includes(String(CAP + 1)));
  assert.equal(m.pulled, 0);
  assert.equal(m.closed, 1);
});

test("size: a streamed body over the cap fails", async () => {
  const chunk = Buffer.alloc(256 * 1024, 0x61);
  const m = mockTransport(() => ({ headers: { "content-type": "text/plain" }, body: Array.from({ length: 12 }, () => chunk) }));
  await assert.rejects(run("https://example.com/", m), new RegExp(String(CAP)));
  assert.ok(m.pulled < 12, `pulled ${m.pulled}`);
  assert.equal(m.closed, 1);
});

test("size: a small compressed body expanding past the cap fails", async () => {
  const bomb = zlib.gzipSync(Buffer.alloc(16 * 1024 * 1024, 0x61));
  assert.ok(bomb.length < 64 * 1024);
  const m = mockTransport(() => ({ headers: { "content-type": "text/plain", "content-encoding": "gzip" }, body: bomb }));
  await assert.rejects(run("https://example.com/", m), new RegExp(String(CAP)));
});

test("gzip, deflate (zlib and raw) and br are decoded", async () => {
  const text = "decoded text \u00e9";
  const cases: [string, Buffer][] = [
    ["gzip", zlib.gzipSync(text)],
    ["x-gzip", zlib.gzipSync(text)],
    ["deflate", zlib.deflateSync(text)],
    ["deflate", zlib.deflateRawSync(text)],
    ["br", zlib.brotliCompressSync(text)],
    ["identity", Buffer.from(text)],
  ];
  for (const [enc, body] of cases) {
    const r = await run("https://example.com/", mockTransport(() => ({ headers: { "content-type": "text/plain; charset=utf-8", "content-encoding": enc }, body })));
    assert.equal(r.text, `URL: https://example.com/\n\n${text}`, enc);
    assert.equal(r.details.bytes, body.length, enc);
  }
  await assert.rejects(run("https://example.com/", mockTransport(() => ({ headers: { "content-type": "text/plain", "content-encoding": "zstd" }, body: "x" }))), /zstd/);
});

test("timeout and abort give different errors", async () => {
  const hanging: Transport = (req) =>
    new Promise((_, reject) => req.signal.addEventListener("abort", () => reject(req.signal.reason), { once: true }));
  await assert.rejects(webFetch("https://example.com/", { transport: hanging, resolver: publicResolver, timeoutMs: 30 }), /timed out after 0\.03 s/);
  await assert.rejects(
    webFetch("https://example.com/", { transport: hanging, resolver: publicResolver, hopTimeoutMs: 20 }),
    (e: Error) => /timed out/.test(e.message) && !/aborted/.test(e.message),
  );
  const ac = new AbortController();
  const p = webFetch("https://example.com/", { transport: hanging, resolver: publicResolver, signal: ac.signal });
  setTimeout(() => ac.abort(), 5);
  await assert.rejects(p, (e: Error) => /aborted/.test(e.message) && !/timed out/.test(e.message));
  const already = new AbortController();
  already.abort();
  await assert.rejects(webFetch("https://example.com/", { transport: hanging, resolver: publicResolver, signal: already.signal }), /aborted/);
});

test("a slow body hits the timeout too", async () => {
  const dribble: Transport = async (req) => ({
    status: 200,
    statusText: "OK",
    headers: { "content-type": "text/plain" },
    body: (async function* () {
      yield Buffer.from("a");
      await new Promise((_, reject) => req.signal.addEventListener("abort", () => reject(req.signal.reason), { once: true }));
    })(),
    close: () => {},
  });
  await assert.rejects(webFetch("https://example.com/", { transport: dribble, resolver: publicResolver, timeoutMs: 30 }), /timed out/);
  const silent: Transport = async () => ({
    status: 200,
    statusText: "OK",
    headers: { "content-type": "text/plain" },
    body: (async function* () {
      await new Promise(() => {}); // ignores the signal entirely
    })(),
    close: () => {},
  });
  await assert.rejects(webFetch("https://example.com/", { transport: silent, resolver: publicResolver, timeoutMs: 30 }), /timed out/);
});

// ---- charsets -------------------------------------------------------------------------

test("charset: header, then meta, then BOM, then UTF-8; unknown labels fall back", () => {
  const latin1 = Buffer.from([0x63, 0x61, 0x66, 0xe9]);
  assert.equal(decodeText(latin1, "iso-8859-1", "text"), "caf\u00e9");
  const meta = Buffer.concat([Buffer.from('<meta charset="windows-1252"><p>'), Buffer.from([0x93, 0x71, 0x94])]);
  assert.match(decodeText(meta, undefined, "html"), /\u201cq\u201d/);
  const httpEquiv = Buffer.concat([Buffer.from('<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=ISO-8859-1">'), Buffer.from([0xe9])]);
  assert.match(decodeText(httpEquiv, undefined, "html"), /\u00e9$/);
  assert.equal(decodeText(meta, undefined, "text").includes("\u201c"), false);
  assert.equal(decodeText(Buffer.from([0xff, 0xfe, 0x68, 0x00, 0x69, 0x00]), undefined, "text"), "hi");
  assert.equal(decodeText(Buffer.from([0xfe, 0xff, 0x00, 0x68, 0x00, 0x69]), undefined, "text"), "hi");
  assert.equal(decodeText(Buffer.from([0xef, 0xbb, 0xbf, 0x68]), undefined, "text"), "h");
  assert.equal(decodeText(Buffer.from("h\u00e9"), undefined, "text"), "h\u00e9");
  assert.equal(decodeText(Buffer.from("h\u00e9"), "no-such-charset", "text"), "h\u00e9");
  assert.equal(decodeText(Buffer.from([0x68, 0xff, 0x69]), "utf-8", "text"), "h\ufffdi");
  assert.equal(decodeText(latin1, "ISO-8859-1", "html"), "caf\u00e9");
});

test("charset from the header reaches the page text", async () => {
  const r = await run("https://example.com/", mockTransport(() => ({ headers: { "content-type": "text/html; charset=iso-8859-1" }, body: Buffer.from([0x3c, 0x70, 0x3e, 0xe9]) })));
  assert.equal(r.text, "URL: https://example.com/\n\n\u00e9");
});

// ---- output cap -------------------------------------------------------------------------

test("long page truncated at 50 KiB / 2000 lines with a note", async () => {
  const body = Array.from({ length: 5000 }, (_, i) => `line ${i}`).join("\n");
  const r = await run("https://example.com/", mockTransport(() => ({ headers: { "content-type": "text/plain" }, body })));
  assert.equal(r.details.truncated, true);
  const lines = r.text.split("\n");
  assert.ok(lines.length <= 2002);
  assert.match(lines[lines.length - 1], /truncated.*of \d+ lines.*omitted/i);
  assert.ok(Buffer.byteLength(r.text) <= 50 * 1024 + 200);
});

// ---- connect check, DNS stalls, caps that act at once, decoder errors ---------------------

async function loopbackServer(t: { after: (fn: () => void) => void }, handler: http.RequestListener): Promise<number> {
  const server = http.createServer(handler);
  await new Promise<void>((res) => server.listen(0, v4(127, 0, 0, 1), res));
  t.after(() => {
    server.closeAllConnections?.();
    server.close();
  });
  return (server.address() as { port: number }).port;
}

test("nodeTransport fails closed when the peer is not a checked address", async (t) => {
  const port = await loopbackServer(t, (_req, res) => res.end("reached"));
  // A lookup that answers with another address than the checked one stands in
  // for a runtime that ignores the pinned lookup and resolves on its own.
  const unpinned = createNodeTransport(
    () => false,
    () => pinnedLookup([v4(127, 0, 0, 1)], () => false),
  );
  await assert.rejects(
    unpinned({
      url: new URL(`${"http"}://pinned.invalid:${port}/`),
      host: "pinned.invalid",
      addresses: [v4(127, 0, 0, 2)],
      headers: { "user-agent": "test" },
      signal: new AbortController().signal,
    }),
    (e: Error) => e.message.includes(`connected to ${v4(127, 0, 0, 1)}`) && e.message.includes("not one of the checked addresses"),
  );
});

// A raw TCP server that records every byte it receives: the peer check must run
// before the request is written. Over TLS the request can only follow a completed
// handshake, which this server never answers, so a refusal from the connect check
// is the proof there; Node writes nothing at all, Bun's native TLS may already
// have sent its ClientHello, but never anything else.
async function byteCounter(t: { after: (fn: () => void) => void }): Promise<{ port: number; received: () => Buffer }> {
  const chunks: Buffer[] = [];
  const sockets = new Set<net.Socket>();
  const server = net.createServer((s) => {
    sockets.add(s);
    s.on("data", (d) => chunks.push(d));
    s.on("error", () => {});
  });
  await new Promise<void>((res) => server.listen(0, v4(127, 0, 0, 1), res));
  t.after(() => {
    for (const s of sockets) s.destroy();
    server.close();
  });
  return { port: (server.address() as { port: number }).port, received: () => Buffer.concat(chunks) };
}

/** The content types of the TLS records in `b` (22 handshake, 21 alert, 23 application data). */
function tlsRecordTypes(b: Buffer): number[] {
  const types: number[] = [];
  for (let i = 0; i + 5 <= b.length; i += 5 + b.readUInt16BE(i + 3)) types.push(b[i]);
  return types;
}

for (const scheme of ["http", "https"]) {
  test(`nodeTransport (${scheme}) checks the peer at connect: no request byte reaches an unchecked address`, async (t) => {
    const counter = await byteCounter(t);
    const unpinned = createNodeTransport(
      () => false,
      () => pinnedLookup([v4(127, 0, 0, 1)], () => false),
    );
    await assert.rejects(
      unpinned({
        url: new URL(`${scheme}://pinned.invalid:${counter.port}/secret-path`),
        host: "pinned.invalid",
        addresses: [v4(127, 0, 0, 2)],
        headers: { "user-agent": "test", authorization: "never sent" },
        signal: AbortSignal.timeout(5000),
      }),
      (e: Error) => e.message.includes(`connected to ${v4(127, 0, 0, 1)}`) && e.message.includes("not one of the checked addresses"),
    );
    await new Promise((res) => setTimeout(res, 200));
    const got = counter.received();
    if (scheme === "http") assert.equal(got.length, 0);
    else assert.ok(tlsRecordTypes(got).every((type) => type === 22 || type === 21), got.subarray(0, 16).toString("hex"));
    assert.ok(!got.includes("secret-path") && !got.includes("never sent"));
  });
}

test("nodeTransport names a checked but blocked peer as blocked", async (t) => {
  const counter = await byteCounter(t);
  const transport = createNodeTransport(
    (a) => a === v4(127, 0, 0, 1),
    () => pinnedLookup([v4(127, 0, 0, 1)], () => false),
  );
  await assert.rejects(
    transport({
      url: new URL(`http://pinned.invalid:${counter.port}/`),
      host: "pinned.invalid",
      addresses: [v4(127, 0, 0, 1)],
      headers: { "user-agent": "test" },
      signal: AbortSignal.timeout(5000),
    }),
    (e: Error) =>
      e.message.includes(`connected to ${v4(127, 0, 0, 1)}`) &&
      /blocked address/.test(e.message) &&
      !e.message.includes("not one of the checked addresses"),
  );
  await new Promise((res) => setTimeout(res, 200));
  assert.equal(counter.received().length, 0);
});

test("abort and timeout are honoured while the DNS lookup stalls", async () => {
  const stalled: Resolver = () => new Promise((res) => setTimeout(() => res([PUBLIC]), 3000));
  const m = mockTransport(() => ({ body: "x" }));
  const ac = new AbortController();
  setTimeout(() => ac.abort(), 20);
  let t0 = Date.now();
  await assert.rejects(run("https://slow-dns.example/", m, { resolver: stalled, signal: ac.signal }), /aborted/);
  assert.ok(Date.now() - t0 < 1000, `abort took ${Date.now() - t0} ms`);
  t0 = Date.now();
  await assert.rejects(run("https://slow-dns.example/", m, { resolver: stalled, timeoutMs: 50 }), /timed out after 0\.05 s/);
  assert.ok(Date.now() - t0 < 1000, `timeout took ${Date.now() - t0} ms`);
  assert.equal(m.requests.length, 0);
});

test("size: too large fails at once although the server keeps the connection open", async (t) => {
  const bomb = zlib.gzipSync(Buffer.alloc(64 * 1024 * 1024, 0x61), { level: 9 });
  const port = await loopbackServer(t, (_req, res) => {
    res.writeHead(200, { "content-type": "text/plain", "content-encoding": "gzip" });
    res.write(bomb.subarray(0, Math.min(bomb.length - 1, 64 * 1024))); // and never ends
  });
  const local = createNodeTransport(() => false);
  const transport: Transport = (req) => local({ ...req, addresses: [v4(127, 0, 0, 1)] });
  const t0 = Date.now();
  await assert.rejects(webFetch(`${"http"}://stall.example:${port}/`, { transport, resolver: publicResolver, hopTimeoutMs: 4000 }), /too large/);
  assert.ok(Date.now() - t0 < 2000, `took ${Date.now() - t0} ms`);
});

test("size: the raw (still encoded) body is capped too", async () => {
  // empty, non-final stored deflate blocks: raw bytes grow, decoded bytes stay 0
  const chunk = Buffer.concat(Array.from({ length: 13107 }, () => Buffer.from([0, 0, 0, 0xff, 0xff])));
  const m = mockTransport(() => ({ headers: { "content-type": "text/plain", "content-encoding": "deflate" }, body: Array.from({ length: 100 }, () => chunk) }));
  await assert.rejects(run("https://example.com/", m), /too large.*encoded/i);
  assert.ok(m.pulled < 100, `pulled ${m.pulled}`);
  assert.equal(m.closed, 1);
});

test("an empty encoded body is empty content; a broken one names the encoding and the host", async () => {
  for (const enc of ["gzip", "deflate", "br"]) {
    const r = await run("https://example.com/", mockTransport(() => ({ headers: { "content-type": "text/plain", "content-encoding": enc } })));
    assert.equal(r.text, "URL: https://example.com/\n\n(no readable text)", enc);
  }
  const cut = zlib.gzipSync("a text that is long enough to be cut in the middle").subarray(0, 20);
  for (const [enc, body] of [
    ["gzip", cut],
    ["br", Buffer.from("this is not brotli at all")],
  ] as const) {
    await assert.rejects(
      run("https://example.com/", mockTransport(() => ({ headers: { "content-type": "text/plain", "content-encoding": enc }, body }))),
      (e: Error) => e.message.includes(`${enc}-encoded body from example.com`),
    );
  }
});
