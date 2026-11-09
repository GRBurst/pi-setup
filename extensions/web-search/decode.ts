// Content type and charset handling for web_fetch.

import { TextDecoder } from "node:util";

export type Kind = "html" | "text" | "json" | "xml";

export interface ContentType {
  /** media type, lower-case, without parameters ("" if missing) */
  mediaType: string;
  charset?: string;
}

export function parseContentType(header: string | undefined): ContentType {
  if (!header) return { mediaType: "" };
  const [type, ...params] = header.split(";");
  const out: ContentType = { mediaType: type.trim().toLowerCase() };
  for (const p of params) {
    const eq = p.indexOf("=");
    if (eq < 0) continue;
    if (p.slice(0, eq).trim().toLowerCase() === "charset") {
      const v = p.slice(eq + 1).trim().replace(/^"|"$/g, "");
      if (v) out.charset = v;
    }
  }
  return out;
}

/** How an allowed media type is returned; null if it is not allowed. */
export function mediaKind(mediaType: string): Kind | null {
  const t = mediaType.toLowerCase();
  if (t === "text/html" || t === "application/xhtml+xml") return "html";
  if (t === "application/json" || t.endsWith("+json")) return "json";
  if (t === "application/xml" || t === "text/xml" || t.endsWith("+xml")) return "xml";
  if (t.startsWith("text/")) return "text";
  return null;
}

/** Kind of a body without a content type: null for binary (NUL bytes). */
export function sniffKind(bytes: Uint8Array): Kind | null {
  const head = bytes.subarray(0, 1024);
  if (head.includes(0)) return null;
  const text = Buffer.from(head).toString("latin1").replace(/^(\xef\xbb\xbf)?\s*/, "").toLowerCase();
  return text.startsWith("<!doctype html") || text.startsWith("<html") ? "html" : "text";
}

function metaCharset(bytes: Uint8Array): string | undefined {
  const head = Buffer.from(bytes.subarray(0, 1024)).toString("latin1");
  const m = /<meta\b[^>]*?charset\s*=\s*["']?\s*([A-Za-z0-9_:.+-]+)/i.exec(head);
  return m?.[1];
}

function bomCharset(bytes: Uint8Array): string | undefined {
  if (bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) return "utf-8";
  if (bytes[0] === 0xfe && bytes[1] === 0xff) return "utf-16be";
  if (bytes[0] === 0xff && bytes[1] === 0xfe) return "utf-16le";
  return undefined;
}

function decoder(label: string | undefined): TextDecoder | undefined {
  if (!label) return undefined;
  try {
    return new TextDecoder(label.trim().toLowerCase());
  } catch {
    return undefined;
  }
}

/** Decodes a body: charset from the content type, else (HTML) a meta
 * declaration in the first 1024 bytes, else a BOM, else UTF-8. Unknown
 * labels fall back; invalid sequences become U+FFFD. */
export function decodeText(bytes: Uint8Array, headerCharset: string | undefined, kind: Kind): string {
  const d =
    decoder(headerCharset) ??
    (kind === "html" ? decoder(metaCharset(bytes)) : undefined) ??
    decoder(bomCharset(bytes)) ??
    new TextDecoder("utf-8");
  return d.decode(bytes);
}
