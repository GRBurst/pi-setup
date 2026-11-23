// web_fetch through an HTTP proxy, for a machine whose only way out is one
// (opt-in through PI_WEB_FETCH_PROXY; unset, web_fetch connects directly).
// Every target, http and https, goes through a CONNECT tunnel to the checked
// IP address, never to the host name: the proxy opens the connection to the
// address this side validated, so a second DNS answer at the proxy cannot
// move it to another one. TLS runs end to end inside the tunnel and verifies
// the certificate against the host name; the Host header carries the name.
// Plain-text CONNECT, written by hand on a net socket: no proxy agent and no
// runtime-specific CONNECT support needed.

import http from "node:http";
import https from "node:https";
import net from "node:net";
import tls from "node:tls";
import { isBlockedAddress } from "./address.ts";
import type { Transport, TransportRequest } from "./fetch.ts";

type Env = Record<string, string | undefined>;

export type ProxySetting =
  | { kind: "direct" }
  | { kind: "fixed"; proxy: URL }
  | { kind: "env"; http: URL | null; https: URL | null; noProxy: string[] }
  | { kind: "invalid"; reason: string };

/** The proxy URL, or an error text: only `http://[user:password@]host[:port]`. */
function proxyUrl(value: string, name: string): URL | string {
  let u: URL;
  try {
    u = new URL(value.includes("://") ? value : `http://${value}`);
  } catch {
    return `${name} is not a valid URL`;
  }
  if (u.protocol !== "http:") return `${name} must be an http:// proxy (got ${u.protocol})`;
  if ((u.pathname !== "/" && u.pathname !== "") || u.search || u.hash) return `${name} must be a proxy origin without a path`;
  return u;
}

const first = (env: Env, ...names: string[]): [string, string] | undefined => {
  for (const n of names) {
    const v = env[n]?.trim();
    if (v) return [n, v];
  }
  return undefined;
};

/** PI_WEB_FETCH_PROXY: unset or empty = direct; `env` = the proxy variables
 * of the environment (`https_proxy`/`HTTPS_PROXY` for https targets,
 * `http_proxy`/`HTTP_PROXY` for http, either falling back to `all_proxy`/
 * `ALL_PROXY`, with `no_proxy`/`NO_PROXY` going direct); anything else = one
 * http:// proxy for every target. An invalid value fails every call instead
 * of going direct. */
export function selectFetchProxy(env: Env): ProxySetting {
  const setting = env.PI_WEB_FETCH_PROXY?.trim();
  if (!setting) return { kind: "direct" };
  if (setting !== "env") {
    const u = proxyUrl(setting, "PI_WEB_FETCH_PROXY");
    return typeof u === "string" ? { kind: "invalid", reason: u } : { kind: "fixed", proxy: u };
  }
  const pick = (...names: string[]): URL | null | string => {
    const found = first(env, ...names);
    return found === undefined ? null : proxyUrl(found[1], found[0]);
  };
  const all = ["all_proxy", "ALL_PROXY"];
  const httpP = pick("http_proxy", "HTTP_PROXY", ...all);
  const httpsP = pick("https_proxy", "HTTPS_PROXY", ...all);
  for (const p of [httpP, httpsP]) if (typeof p === "string") return { kind: "invalid", reason: p };
  const noProxy = (first(env, "no_proxy", "NO_PROXY")?.[1] ?? "")
    .split(/[\s,]+/)
    .map((e) => e.trim().toLowerCase())
    .filter((e) => e !== "");
  return { kind: "env", http: httpP as URL | null, https: httpsP as URL | null, noProxy };
}

const unbracket = (h: string) => (h.startsWith("[") && h.endsWith("]") ? h.slice(1, -1) : h);

function splitEntry(raw: string): { host: string; port?: string } {
  if (net.isIPv6(raw)) return { host: raw };
  const bracketed = /^\[([^\]]+)\](?::(\d+))?$/.exec(raw);
  if (bracketed) return { host: bracketed[1], port: bracketed[2] };
  const withPort = /^([^:]+):(\d+)$/.exec(raw);
  if (withPort) return { host: withPort[1], port: withPort[2] };
  return { host: raw };
}

/** Whether `host` (name or IP literal, no brackets) on `port` matches a
 * NO_PROXY list: `*`, exact names and IPs, domain suffixes (`.example.com`
 * or `example.com`, both covering subdomains), optionally with `:port`. */
export function bypassesProxy(host: string, port: string, noProxy: string[]): boolean {
  const h = host.toLowerCase().replace(/\.$/, "");
  return noProxy.some((raw) => {
    if (raw === "*") return true;
    const { host: name, port: entryPort } = splitEntry(raw);
    const entry = name.replace(/^\*?\./, ".").replace(/\.$/, "");
    if (entryPort !== undefined && entryPort !== port) return false;
    if (entry.startsWith(".")) return h.endsWith(entry) || h === entry.slice(1);
    return h === entry || h.endsWith(`.${entry}`);
  });
}

/** The proxy for a target URL under `setting`, or null for a direct connection. */
export function proxyFor(setting: ProxySetting, url: URL): URL | null {
  switch (setting.kind) {
    case "direct":
      return null;
    case "invalid":
      throw new Error(`PI_WEB_FETCH_PROXY: ${setting.reason}.`);
    case "fixed":
      return setting.proxy;
    case "env": {
      const port = url.port || (url.protocol === "https:" ? "443" : "80");
      if (bypassesProxy(unbracket(url.hostname), port, setting.noProxy)) return null;
      return url.protocol === "https:" ? setting.https : setting.http;
    }
  }
}

const MAX_PROXY_HEAD = 16 * 1024;

/** Opens a CONNECT tunnel through `proxy` to `address`:`port` and resolves
 * with the raw socket once the proxy answered 2xx. */
export function openTunnel(proxy: URL, address: string, port: number, signal: AbortSignal): Promise<net.Socket> {
  return new Promise((resolve, reject) => {
    if (signal.aborted) return reject(signal.reason);
    const authority = net.isIPv6(address) ? `[${address}]:${port}` : `${address}:${port}`;
    const proxyPort = Number(proxy.port) || 80;
    const socket = net.connect({ host: unbracket(proxy.hostname), port: proxyPort });
    let settled = false;
    const fail = (e: Error) => {
      if (settled) return;
      settled = true;
      signal.removeEventListener("abort", onAbort);
      socket.destroy();
      reject(e);
    };
    const onAbort = () => fail(signal.reason instanceof Error ? signal.reason : new Error("aborted"));
    signal.addEventListener("abort", onAbort, { once: true });
    socket.once("error", (e) => fail(new Error(`proxy ${proxy.host} failed (${(e as { code?: string }).code ?? e.message})`)));
    socket.once("close", () => fail(new Error(`proxy ${proxy.host} closed the connection before answering CONNECT ${authority}`)));
    socket.once("connect", () => {
      const auth =
        proxy.username || proxy.password
          ? `Proxy-Authorization: Basic ${Buffer.from(`${decodeURIComponent(proxy.username)}:${decodeURIComponent(proxy.password)}`).toString("base64")}\r\n`
          : "";
      socket.write(`CONNECT ${authority} HTTP/1.1\r\nHost: ${authority}\r\n${auth}\r\n`);
    });
    let head = Buffer.alloc(0);
    const onData = (chunk: Buffer) => {
      head = Buffer.concat([head, chunk]);
      const end = head.indexOf("\r\n\r\n");
      if (end === -1) {
        if (head.length > MAX_PROXY_HEAD) fail(new Error(`proxy ${proxy.host} sent an oversized CONNECT response`));
        return;
      }
      socket.off("data", onData);
      const status = /^HTTP\/1\.[01] (\d{3})([^\r\n]*)/.exec(head.subarray(0, end).toString("latin1"));
      if (status === null) return fail(new Error(`proxy ${proxy.host} sent an invalid CONNECT response`));
      if (!status[1].startsWith("2")) {
        return fail(new Error(`proxy ${proxy.host} refused CONNECT ${authority}: HTTP ${status[1]}${status[2].trimEnd()}`));
      }
      const rest = head.subarray(end + 4);
      if (rest.length > 0) socket.unshift(rest);
      settled = true;
      signal.removeEventListener("abort", onAbort);
      socket.removeAllListeners("close");
      socket.removeAllListeners("error");
      resolve(socket);
    };
    socket.on("data", onData);
  });
}

/** The address a tunnel goes to: the first IPv4 address (a proxy without
 * IPv6 is common), else the first one. */
const tunnelAddress = (addresses: string[]) => addresses.find((a) => net.isIPv4(a)) ?? addresses[0];

/** A `lookup` that always fails: the request must use the tunnel socket, so a
 * runtime that ignored `createConnection` fails closed instead of going out
 * on its own. */
const noLookup = ((hostname: string, _o: unknown, cb: (e: Error) => void) =>
  cb(Object.assign(new Error(`direct connection to "${hostname}" refused: web_fetch goes through the proxy`), { code: "EPROXYONLY" }))) as unknown as net.LookupFunction;

/** The transport for `setting`: per request, through the proxy that
 * `proxyFor` picks, or `direct` when it picks none. `isBlocked` exists for
 * tests against loopback servers. */
export function createProxyTransport(
  setting: ProxySetting,
  direct: Transport,
  isBlocked: (a: string) => boolean = isBlockedAddress,
): Transport {
  if (setting.kind === "direct") return direct;
  return async (req: TransportRequest) => {
    const proxy = proxyFor(setting, req.url);
    if (proxy === null) return direct(req);
    const address = tunnelAddress(req.addresses);
    if (address === undefined) throw new Error(`no address for "${req.host}"`);
    if (isBlocked(address)) {
      throw new Error(`Blocked address ${address} for "${req.host}": local, private and internal targets are not permitted.`);
    }
    const secure = req.url.protocol === "https:";
    const port = Number(req.url.port) || (secure ? 443 : 80);
    const raw = await openTunnel(proxy, address, port, req.signal);
    const socket = secure
      ? tls.connect({ socket: raw, host: req.host, servername: net.isIP(req.host) ? undefined : req.host })
      : raw;
    return new Promise((resolve, reject) => {
      const r = (secure ? https : http).request(
        {
          protocol: req.url.protocol,
          hostname: req.host,
          port,
          path: req.url.pathname + req.url.search,
          method: "GET",
          headers: req.headers,
          agent: undefined,
          createConnection: () => socket,
          lookup: noLookup,
          signal: req.signal,
        },
        (res) => {
          if (res.socket !== socket) {
            res.destroy();
            reject(new Error(`the response for "${req.host}" did not come through the proxy tunnel; refused`));
            return;
          }
          resolve({
            status: res.statusCode ?? 0,
            statusText: res.statusMessage ?? "",
            headers: res.headers,
            body: res,
            close: () => {
              res.destroy();
              socket.destroy();
            },
          });
        },
      );
      r.on("error", (e) => {
        socket.destroy();
        reject(e);
      });
      r.end();
    });
  };
}
