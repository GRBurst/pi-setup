// web_fetch: download one public page with the SSRF guard applied at every
// hop and at connect time, decode it and convert it locally. The transport
// and the resolver are injected; the defaults use node:http/https and the
// system resolver. Global fetch is not used: it cannot pin the checked
// address, so a DNS answer that changes between check and connect could
// reach a blocked address.

import dns from "node:dns";
import http from "node:http";
import https from "node:https";
import type { LookupFunction } from "node:net";
import { Readable, type Transform, Writable } from "node:stream";
import { pipeline } from "node:stream/promises";
import zlib from "node:zlib";
import { checkResolved, isBlockedAddress, sameAddress, type Target, validateTarget } from "./address.ts";
import { USER_AGENT } from "./config.ts";
import { decodeText, type Kind, mediaKind, parseContentType, sniffKind } from "./decode.ts";
import { htmlToMarkdown } from "./html.ts";
import { truncateOutput } from "./text.ts";

export interface TransportRequest {
  url: URL;
  /** host name, or the IP literal without brackets */
  host: string;
  /** the validated addresses; the connection must go to one of these */
  addresses: string[];
  headers: Record<string, string>;
  signal: AbortSignal;
}

export interface TransportResponse {
  status: number;
  statusText: string;
  /** lower-case header names */
  headers: Record<string, string | string[] | undefined>;
  /** the body as received (still content-encoded) */
  body: AsyncIterable<Uint8Array>;
  /** releases the connection */
  close(): void;
}

export type Transport = (req: TransportRequest) => Promise<TransportResponse>;
/** All addresses (A and AAAA) of a host name. */
export type Resolver = (host: string) => Promise<string[]>;

export interface FetchDeps {
  transport?: Transport;
  resolver?: Resolver;
  signal?: AbortSignal;
  timeoutMs?: number;
  hopTimeoutMs?: number;
}

export interface FetchDetails {
  url: string;
  finalUrl: string;
  status: number;
  contentType: string;
  bytes: number;
  chars: number;
  truncated: boolean;
  title?: string;
}

export const FETCH_TIMEOUT_MS = 30_000;
export const HOP_TIMEOUT_MS = 20_000;
export const MAX_BODY_BYTES = 2 * 1024 * 1024;
/** received bytes, still content-encoded (a stream can grow without decoding to anything) */
export const MAX_RAW_BYTES = 4 * 1024 * 1024;
export const MAX_REDIRECTS = 5;
const REDIRECTS = new Set([301, 302, 303, 307, 308]);
const ACCEPT = "text/html, application/xhtml+xml, text/markdown;q=0.9, text/plain;q=0.9, */*;q=0.8";

const familyOf = (a: string) => (a.includes(":") ? 6 : 4);

/** A `lookup` for node:net that answers only with the pre-validated
 * addresses (no second DNS query) and refuses any blocked one. */
export function pinnedLookup(addresses: string[], isBlocked: (a: string) => boolean = isBlockedAddress): LookupFunction {
  return ((hostname: string, options: { all?: boolean; family?: number | string }, callback: (...args: unknown[]) => void) => {
    const bad = addresses.find(isBlocked);
    if (bad !== undefined) {
      callback(Object.assign(new Error(`Blocked address ${bad} for "${hostname}": local, private and internal targets are not permitted.`), { code: "EBLOCKED" }));
      return;
    }
    const family = options.family === "IPv4" ? 4 : options.family === "IPv6" ? 6 : Number(options.family) || 0;
    const usable = addresses.filter((a) => family === 0 || familyOf(a) === family);
    if (usable.length === 0) {
      callback(Object.assign(new Error(`No IPv${family} address for "${hostname}".`), { code: "ENOTFOUND" }));
    } else if (options.all) {
      callback(null, usable.map((address) => ({ address, family: familyOf(address) })));
    } else {
      callback(null, usable[0], familyOf(usable[0]));
    }
  }) as unknown as LookupFunction;
}

/** The node:http/https transport. The connection is pinned through
 * `lookup`; when the socket connects, before the request (or the TLS
 * handshake) is written, the peer address must be one of the checked
 * addresses and not blocked, so a runtime that ignored `lookup` fails
 * closed without sending anything to an unchecked address. The response is
 * checked again as a second line. `isBlocked` and
 * `lookupFor` exist for tests against a loopback server; production code
 * uses the defaults. */
export function createNodeTransport(
  isBlocked: (a: string) => boolean = isBlockedAddress,
  lookupFor: (addresses: string[]) => LookupFunction = (addresses) => pinnedLookup(addresses, isBlocked),
): Transport {
  return (req) =>
    new Promise((resolve, reject) => {
      const refusal = (peer: string | undefined): Error | null => {
        if (peer === undefined || !req.addresses.some((a) => sameAddress(a, peer))) {
          return new Error(
            `connected to ${peer ?? "an unknown address"} for "${req.host}", which is not one of the checked addresses ` +
              `(${req.addresses.join(", ")}); the connection is refused`,
          );
        }
        if (isBlocked(peer)) {
          return new Error(
            `connected to ${peer} for "${req.host}", a blocked address: local, private and internal targets are not permitted`,
          );
        }
        return null;
      };
      const mod = req.url.protocol === "https:" ? https : http;
      const r = mod.request(
        {
          protocol: req.url.protocol,
          hostname: req.host,
          port: req.url.port || undefined,
          path: req.url.pathname + req.url.search,
          method: "GET",
          headers: req.headers,
          agent: false, // no pooling, no environment proxy
          lookup: lookupFor(req.addresses),
          signal: req.signal,
        },
        (res) => {
          const refused = refusal(res.socket?.remoteAddress);
          if (refused !== null) {
            res.destroy();
            reject(refused);
            return;
          }
          resolve({
            status: res.statusCode ?? 0,
            statusText: res.statusMessage ?? "",
            headers: res.headers,
            body: res,
            close: () => res.destroy(),
          });
        },
      );
      r.on("socket", (socket) => {
        const onConnect = () => {
          const refused = refusal(socket.remoteAddress);
          if (refused !== null) r.destroy(refused);
        };
        // first in line: ahead of the queued request bytes and the TLS start
        if (socket.connecting) socket.prependOnceListener("connect", onConnect);
        else onConnect();
      });
      r.on("error", reject);
      r.end();
    });
}

export const systemResolver: Resolver = async (host) => {
  const found = await dns.promises.lookup(host, { all: true, verbatim: true });
  return found.map((a) => a.address);
};

const header = (h: TransportResponse["headers"], name: string): string | undefined => {
  const v = h[name];
  return Array.isArray(v) ? v[0] : v;
};

function decompressor(encoding: string | undefined, first: Uint8Array | undefined): Transform | null {
  const e = (encoding ?? "").trim().toLowerCase();
  if (e === "" || e === "identity") return null;
  if (e === "gzip" || e === "x-gzip") return zlib.createGunzip();
  if (e === "br") return zlib.createBrotliDecompress();
  if (e === "deflate") {
    // RFC deflate is zlib-wrapped, but some servers send raw deflate
    return first !== undefined && (first[0] & 0x0f) === 8 && ((first[0] << 8) | (first[1] ?? 0)) % 31 === 0
      ? zlib.createInflate()
      : zlib.createInflateRaw();
  }
  throw new Error(`Unsupported content encoding "${encoding}".`);
}

class TooLarge extends Error {
  readonly encoded: boolean;
  constructor(encoded: boolean) {
    super(encoded ? "too many received bytes" : "too many decoded bytes");
    this.encoded = encoded;
  }
}

class DecodeFailed extends Error {}

function abortable<T>(p: Promise<T>, signal: AbortSignal): Promise<T> {
  if (signal.aborted) return Promise.reject(signal.reason);
  return new Promise<T>((resolve, reject) => {
    const onAbort = () => reject(signal.reason);
    signal.addEventListener("abort", onAbort, { once: true });
    p.then(resolve, reject).finally(() => signal.removeEventListener("abort", onAbort));
  });
}

/** Reads and decodes the body, failing as soon as the received or the
 * decoded size exceeds its cap; the connection is released at once then, so
 * a server that keeps it open cannot delay the error. An empty body is empty
 * content whatever its encoding. Returns the decoded bytes and the raw byte
 * count. */
async function readBody(res: TransportResponse, signal: AbortSignal): Promise<{ data: Buffer; raw: number }> {
  const iterator = res.body[Symbol.asyncIterator]();
  const firstStep = await abortable(iterator.next(), signal);
  if (firstStep.done) return { data: Buffer.alloc(0), raw: 0 };
  const first = firstStep.value;
  const decomp = decompressor(header(res.headers, "content-encoding"), first);
  const tooLarge = (encoded: boolean) => {
    res.close();
    return new TooLarge(encoded);
  };
  let raw = 0;
  const source = Readable.from(
    (async function* () {
      let chunk = first;
      for (;;) {
        raw += chunk.byteLength;
        if (raw > MAX_RAW_BYTES) throw tooLarge(true);
        yield chunk;
        const step = await iterator.next();
        if (step.done) return;
        chunk = step.value;
      }
    })(),
  );
  const chunks: Buffer[] = [];
  let total = 0;
  const sink = new Writable({
    write(chunk: Buffer, _enc, done) {
      total += chunk.length;
      if (total > MAX_BODY_BYTES) return done(tooLarge(false));
      chunks.push(chunk);
      done();
    },
  });
  if (decomp === null) {
    await pipeline(source, sink, { signal });
    return { data: Buffer.concat(chunks), raw };
  }
  let decodeError: unknown = null;
  decomp.once("error", (e) => {
    decodeError = e;
  });
  try {
    await pipeline(source, decomp, sink, { signal });
  } catch (e) {
    // the decompressor also re-emits the errors pipeline destroys it with
    if (e === decodeError && !(e instanceof TooLarge) && !signal.aborted) throw new DecodeFailed((e as Error).message);
    throw e;
  }
  return { data: Buffer.concat(chunks), raw };
}

function render(kind: Kind, text: string, finalUrl: string): { content: string; title?: string } {
  if (kind === "html") {
    const c = htmlToMarkdown(text, finalUrl);
    return { content: c.markdown, title: c.title };
  }
  if (kind === "json") {
    try {
      return { content: JSON.stringify(JSON.parse(text), null, 2) };
    } catch {
      return { content: text };
    }
  }
  return { content: text };
}

const seconds = (ms: number) => `${ms / 1000} s`;

/** Fetches `rawUrl` and returns its readable content. Throws an Error with
 * the cause on every failure. */
export async function webFetch(rawUrl: string, deps: FetchDeps = {}): Promise<{ text: string; details: FetchDetails }> {
  const transport = deps.transport ?? createNodeTransport();
  const resolver = deps.resolver ?? systemResolver;
  const timeoutMs = deps.timeoutMs ?? FETCH_TIMEOUT_MS;
  const hopTimeoutMs = deps.hopTimeoutMs ?? HOP_TIMEOUT_MS;

  let target: Target = validateTarget(rawUrl);
  const requested = target.url.href;
  const total = new AbortController();
  const timer = setTimeout(() => total.abort(), timeoutMs);
  const callSignal = AbortSignal.any([total.signal, ...(deps.signal ? [deps.signal] : [])]);
  let hop: AbortController | null = null;
  let hopTimer: ReturnType<typeof setTimeout> | undefined;
  const stopped = (): Error | null => {
    if (deps.signal?.aborted) return new Error("web_fetch was aborted.");
    if (total.signal.aborted) return new Error(`web_fetch timed out after ${seconds(timeoutMs)} (limit for the whole call).`);
    if (hop?.signal.aborted) return new Error(`web_fetch timed out after ${seconds(hopTimeoutMs)} waiting for ${target.url.host}.`);
    return null;
  };
  let res: TransportResponse | null = null;
  try {
    if (deps.signal?.aborted) throw stopped();
    for (let redirects = 0; ; redirects++) {
      let addresses: string[];
      if (target.literal !== null) {
        addresses = [target.literal];
      } else {
        try {
          // a stalled resolver must not outlive the abort signal or the timeout
          addresses = await abortable(resolver(target.host), callSignal);
        } catch (e) {
          throw stopped() ?? new Error(`DNS lookup of "${target.host}" failed (${(e as { code?: string }).code ?? (e as Error).message}).`);
        }
        checkResolved(target.host, addresses);
      }
      if (callSignal.aborted) throw stopped();
      hop = new AbortController();
      clearTimeout(hopTimer);
      hopTimer = setTimeout(() => hop?.abort(), hopTimeoutMs);
      const signal = AbortSignal.any([callSignal, hop.signal]);
      try {
        const opened = await transport({
          url: target.url,
          host: target.host,
          addresses,
          headers: { "user-agent": USER_AGENT, accept: ACCEPT, "accept-encoding": "gzip, deflate, br" },
          signal,
        });
        let closed = false;
        res = {
          ...opened,
          close: () => {
            if (closed) return;
            closed = true;
            opened.close();
          },
        };
      } catch (e) {
        throw stopped() ?? new Error(`Request to ${target.url.host} failed (${(e as { code?: string }).code ?? (e as Error).message}).`);
      }
      const status = res.status;
      if (REDIRECTS.has(status)) {
        const location = header(res.headers, "location");
        res.close();
        res = null;
        if (!location) throw new Error(`HTTP ${status} redirect without a Location header.`);
        if (redirects >= MAX_REDIRECTS) throw new Error(`Too many redirects (the limit is ${MAX_REDIRECTS}).`);
        let next: URL;
        try {
          next = new URL(location, target.url);
        } catch {
          throw new Error(`HTTP ${status} redirect to an invalid Location "${location}".`);
        }
        target = validateTarget(next.href);
        continue;
      }
      if (status < 200 || status > 299) {
        throw new Error(`HTTP ${status} ${res.statusText}`.trim() + ` from ${target.url.href}.`);
      }
      const contentType = header(res.headers, "content-type") ?? "";
      const ct = parseContentType(contentType);
      let kind = ct.mediaType ? mediaKind(ct.mediaType) : undefined;
      if (kind === null) {
        throw new Error(`Blocked content type "${ct.mediaType}": web_fetch only reads HTML, text, XML and JSON.`);
      }
      const declared = Number(header(res.headers, "content-length"));
      if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) {
        throw new Error(`Response too large: Content-Length ${declared} exceeds the limit of ${MAX_BODY_BYTES} bytes.`);
      }
      let body: { data: Buffer; raw: number };
      try {
        body = await readBody(res, signal);
      } catch (e) {
        if (e instanceof TooLarge) {
          throw new Error(
            e.encoded
              ? `Response too large: more than ${MAX_RAW_BYTES} bytes received (still content-encoded).`
              : `Response too large: more than ${MAX_BODY_BYTES} bytes after decoding.`,
          );
        }
        const why = stopped();
        if (why) throw why;
        if (e instanceof DecodeFailed) {
          const encoding = (header(res.headers, "content-encoding") ?? "").trim().toLowerCase();
          throw new Error(`Cannot decode the ${encoding}-encoded body from ${target.url.host} (${e.message}).`);
        }
        throw e;
      }
      if (kind === undefined) {
        kind = sniffKind(body.data);
        if (kind === null) throw new Error("Refusing binary content (NUL bytes) without a content type.");
      }
      const finalUrl = target.url.href;
      const page = render(kind, decodeText(body.data, ct.charset, kind), finalUrl);
      const head = [
        ...(page.title ? [`Title: ${page.title}`] : []),
        `URL: ${finalUrl}`,
        ...(finalUrl !== requested ? [`Requested URL: ${requested}`] : []),
      ].join("\n");
      const out = truncateOutput(`${head}\n\n${page.content || "(no readable text)"}`);
      const details: FetchDetails = {
        url: rawUrl,
        finalUrl,
        status,
        contentType,
        bytes: body.raw,
        chars: out.text.length,
        truncated: out.truncated,
      };
      if (page.title) details.title = page.title;
      return { text: out.text, details };
    }
  } finally {
    clearTimeout(timer);
    clearTimeout(hopTimer);
    res?.close();
  }
}
