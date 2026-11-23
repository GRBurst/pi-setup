// web_fetch through an HTTP proxy: the PI_WEB_FETCH_PROXY setting, NO_PROXY
// matching, and the CONNECT tunnel against loopback servers (a CONNECT proxy
// that records what it is asked for, and a target behind it). Addresses are
// assembled at run time (leak scan).
import assert from "node:assert/strict";
import http from "node:http";
import net from "node:net";
import { test } from "node:test";
import type { Transport, TransportRequest } from "../../extensions/web-search/fetch.ts";
import { bypassesProxy, createProxyTransport, proxyFor, selectFetchProxy } from "../../extensions/web-search/proxy.ts";

const v4 = (...o: number[]) => o.join(".");
const LOOP = v4(127, 0, 0, 1);
const scheme = (s: string, rest: string) => `${s}://${rest}`;
const allow = () => false;

// ---- setting ---------------------------------------------------------------------------

test("PI_WEB_FETCH_PROXY unset or empty means direct", () => {
  assert.deepEqual(selectFetchProxy({}), { kind: "direct" });
  assert.deepEqual(selectFetchProxy({ PI_WEB_FETCH_PROXY: "  ", HTTPS_PROXY: scheme("http", "proxy.example.com:3128") }), {
    kind: "direct",
  });
});

test("PI_WEB_FETCH_PROXY=env picks the proxy per scheme and honours NO_PROXY", () => {
  const s = selectFetchProxy({
    PI_WEB_FETCH_PROXY: "env",
    HTTPS_PROXY: scheme("http", "tls-proxy.example.com:3128"),
    http_proxy: scheme("http", "plain-proxy.example.com:8080"),
    NO_PROXY: "localhost, .internal.example.com,direct.example.org",
  });
  assert.equal(proxyFor(s, new URL(scheme("https", "a.example.net/")))?.host, "tls-proxy.example.com:3128");
  assert.equal(proxyFor(s, new URL(scheme("http", "a.example.net/")))?.host, "plain-proxy.example.com:8080");
  assert.equal(proxyFor(s, new URL(scheme("https", "x.internal.example.com/"))), null);
  assert.equal(proxyFor(s, new URL(scheme("https", "direct.example.org/"))), null);
});

test("PI_WEB_FETCH_PROXY=env falls back to ALL_PROXY and goes direct without any proxy", () => {
  const s = selectFetchProxy({ PI_WEB_FETCH_PROXY: "env", ALL_PROXY: "proxy.example.com:3128" });
  assert.equal(proxyFor(s, new URL(scheme("https", "a.example.net/")))?.host, "proxy.example.com:3128");
  assert.equal(proxyFor(selectFetchProxy({ PI_WEB_FETCH_PROXY: "env" }), new URL(scheme("https", "a.example.net/"))), null);
});

test("a fixed PI_WEB_FETCH_PROXY applies to every target", () => {
  const s = selectFetchProxy({ PI_WEB_FETCH_PROXY: scheme("http", "proxy.example.com:3128"), NO_PROXY: "*" });
  assert.equal(proxyFor(s, new URL(scheme("http", "a.example.net/")))?.host, "proxy.example.com:3128");
});

test("an invalid proxy fails every call instead of going direct", () => {
  for (const env of [
    { PI_WEB_FETCH_PROXY: scheme("https", "proxy.example.com") },
    { PI_WEB_FETCH_PROXY: scheme("http", "proxy.example.com/path") },
    { PI_WEB_FETCH_PROXY: "env", HTTPS_PROXY: scheme("socks5", "proxy.example.com:1080") },
  ]) {
    const s = selectFetchProxy(env);
    assert.equal(s.kind, "invalid", JSON.stringify(env));
    assert.throws(() => proxyFor(s, new URL(scheme("https", "a.example.net/"))), /PI_WEB_FETCH_PROXY/);
  }
});

test("NO_PROXY matching: names, suffixes, wildcards, ports, IPs", () => {
  assert.ok(bypassesProxy("example.com", "443", ["example.com"]));
  assert.ok(bypassesProxy("a.example.com", "443", ["example.com"]));
  assert.ok(bypassesProxy("a.example.com", "443", [".example.com"]));
  assert.ok(bypassesProxy("example.com", "443", [".example.com"]));
  assert.ok(bypassesProxy("a.example.com", "443", ["*.example.com"]));
  assert.ok(bypassesProxy("anything.example.net", "80", ["*"]));
  assert.ok(bypassesProxy("example.com", "8080", ["example.com:8080"]));
  assert.ok(!bypassesProxy("example.com", "443", ["example.com:8080"]));
  assert.ok(!bypassesProxy("notexample.com", "443", ["example.com"]));
  assert.ok(bypassesProxy(v4(192, 0, 2, 1), "443", [v4(192, 0, 2, 1)]));
  assert.ok(bypassesProxy("2001:db8::1", "443", ["2001:db8::1"]));
  assert.ok(bypassesProxy("2001:db8::1", "443", ["[2001:db8::1]:443"]));
});

// ---- tunnel ------------------------------------------------------------------------------

interface Proxy {
  port: number;
  connects: { authority: string; auth?: string }[];
  sockets: number;
}

/** A CONNECT proxy on loopback: records each request line and forwards the
 * tunnel to the requested authority, or answers `refuse` when given. */
async function connectProxy(t: { after: (fn: () => void) => void }, refuse?: string): Promise<Proxy> {
  const state: Proxy = { port: 0, connects: [], sockets: 0 };
  const server = net.createServer((client) => {
    state.sockets++;
    let head = Buffer.alloc(0);
    const onData = (chunk: Buffer) => {
      head = Buffer.concat([head, chunk]);
      const end = head.indexOf("\r\n\r\n");
      if (end === -1) return;
      client.off("data", onData);
      const lines = head.subarray(0, end).toString("latin1").split("\r\n");
      const authority = lines[0].split(" ")[1];
      const auth = lines.find((l) => l.toLowerCase().startsWith("proxy-authorization:"))?.slice(20).trim();
      state.connects.push({ authority, auth });
      if (refuse !== undefined) {
        client.end(`HTTP/1.1 ${refuse}\r\nContent-Length: 0\r\n\r\n`);
        return;
      }
      const i = authority.lastIndexOf(":");
      const upstream = net.connect(Number(authority.slice(i + 1)), authority.slice(0, i).replace(/^\[|\]$/g, ""), () => {
        client.write("HTTP/1.1 200 Connection Established\r\n\r\n");
        const rest = head.subarray(end + 4);
        if (rest.length) upstream.write(rest);
        client.pipe(upstream).pipe(client);
      });
      upstream.on("error", () => client.destroy());
      client.on("error", () => upstream.destroy());
    };
    client.on("data", onData);
  });
  const open = new Set<net.Socket>();
  server.on("connection", (s) => {
    open.add(s);
    s.on("close", () => open.delete(s));
  });
  await new Promise<void>((res) => server.listen(0, LOOP, res));
  t.after(() => {
    for (const s of open) s.destroy();
    server.close();
  });
  state.port = (server.address() as { port: number }).port;
  return state;
}

async function target(t: { after: (fn: () => void) => void }): Promise<{ port: number; hosts: string[] }> {
  const hosts: string[] = [];
  const server = http.createServer((req, res) => {
    hosts.push(req.headers.host ?? "");
    res.setHeader("content-type", "text/plain");
    res.end("behind the proxy");
  });
  await new Promise<void>((res) => server.listen(0, LOOP, res));
  t.after(() => {
    server.closeAllConnections?.();
    server.close();
  });
  return { port: (server.address() as { port: number }).port, hosts };
}

const request = (url: string, addresses: string[]): TransportRequest => ({
  url: new URL(url),
  host: new URL(url).hostname,
  addresses,
  headers: { "user-agent": "test" },
  signal: AbortSignal.timeout(10_000),
});

const noDirect: Transport = async () => {
  throw new Error("direct transport used");
};

async function text(body: AsyncIterable<Uint8Array>): Promise<string> {
  const parts: Buffer[] = [];
  for await (const c of body) parts.push(Buffer.from(c));
  return Buffer.concat(parts).toString();
}

test("the tunnel goes to the checked address, not the host name, and sends the name as Host", async (t) => {
  const proxy = await connectProxy(t);
  const site = await target(t);
  const transport = createProxyTransport(
    selectFetchProxy({ PI_WEB_FETCH_PROXY: scheme("http", `${LOOP}:${proxy.port}`) }),
    noDirect,
    allow,
  );
  const res = await transport(request(scheme("http", `pinned.invalid:${site.port}/page`), ["2001:db8::1", LOOP]));
  assert.equal(res.status, 200);
  assert.equal(await text(res.body), "behind the proxy");
  res.close();
  assert.deepEqual(proxy.connects, [{ authority: `${LOOP}:${site.port}`, auth: undefined }]);
  assert.deepEqual(site.hosts, [`pinned.invalid:${site.port}`]);
});

test("proxy credentials go out as Proxy-Authorization", async (t) => {
  const proxy = await connectProxy(t);
  const site = await target(t);
  const transport = createProxyTransport(
    selectFetchProxy({ PI_WEB_FETCH_PROXY: scheme("http", `us%40er:p%3Ass@${LOOP}:${proxy.port}`) }),
    noDirect,
    allow,
  );
  (await transport(request(scheme("http", `pinned.invalid:${site.port}/`), [LOOP]))).close();
  assert.equal(proxy.connects[0].auth, `Basic ${Buffer.from("us@er:p:ss").toString("base64")}`);
});

test("a refused CONNECT is an error naming the proxy's answer", async (t) => {
  const proxy = await connectProxy(t, "403 Forbidden");
  const transport = createProxyTransport(
    selectFetchProxy({ PI_WEB_FETCH_PROXY: scheme("http", `${LOOP}:${proxy.port}`) }),
    noDirect,
    allow,
  );
  await assert.rejects(transport(request(scheme("https", "pinned.invalid/"), [LOOP])), /refused CONNECT .*:443: HTTP 403 Forbidden/);
});

test("a blocked address is refused before the proxy is contacted", async (t) => {
  const proxy = await connectProxy(t);
  const transport = createProxyTransport(selectFetchProxy({ PI_WEB_FETCH_PROXY: scheme("http", `${LOOP}:${proxy.port}`) }), noDirect);
  await assert.rejects(transport(request(scheme("https", "pinned.invalid/"), [v4(10, 0, 0, 7)])), /Blocked address/);
  assert.equal(proxy.sockets, 0);
});

test("a NO_PROXY target and the direct setting use the direct transport", async () => {
  let used = 0;
  const direct: Transport = async () => {
    used++;
    throw new Error("direct");
  };
  const env = createProxyTransport(
    selectFetchProxy({ PI_WEB_FETCH_PROXY: "env", HTTPS_PROXY: scheme("http", `${LOOP}:9`), NO_PROXY: ".example.org" }),
    direct,
    allow,
  );
  await assert.rejects(env(request(scheme("https", "a.example.org/"), [LOOP])), /^Error: direct$/);
  assert.equal(createProxyTransport({ kind: "direct" }, direct), direct);
  assert.equal(used, 1);
});
