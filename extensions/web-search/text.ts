// Text helpers shared by the search backends, the fetcher and the HTML
// converter: character references, whitespace, the snippet cap and the
// output cap. Pure functions; no pi imports, so the checks run them with
// plain Node.

const NAMED: Record<string, string> = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
  nbsp: " ",
  ensp: " ",
  emsp: " ",
  thinsp: " ",
  zwnj: "\u200c",
  zwj: "\u200d",
  lrm: "\u200e",
  rlm: "\u200f",
  shy: "\u00ad",
  mdash: "\u2014",
  ndash: "\u2013",
  minus: "\u2212",
  hellip: "\u2026",
  lsquo: "\u2018",
  rsquo: "\u2019",
  sbquo: "\u201a",
  ldquo: "\u201c",
  rdquo: "\u201d",
  bdquo: "\u201e",
  laquo: "\u00ab",
  raquo: "\u00bb",
  lsaquo: "\u2039",
  rsaquo: "\u203a",
  prime: "\u2032",
  Prime: "\u2033",
  bull: "\u2022",
  middot: "\u00b7",
  dagger: "\u2020",
  Dagger: "\u2021",
  permil: "\u2030",
  copy: "\u00a9",
  reg: "\u00ae",
  trade: "\u2122",
  deg: "\u00b0",
  plusmn: "\u00b1",
  times: "\u00d7",
  divide: "\u00f7",
  frac12: "\u00bd",
  frac14: "\u00bc",
  frac34: "\u00be",
  sup2: "\u00b2",
  sup3: "\u00b3",
  micro: "\u00b5",
  para: "\u00b6",
  sect: "\u00a7",
  cent: "\u00a2",
  pound: "\u00a3",
  euro: "\u20ac",
  yen: "\u00a5",
  iexcl: "\u00a1",
  iquest: "\u00bf",
  larr: "\u2190",
  rarr: "\u2192",
  uarr: "\u2191",
  darr: "\u2193",
  harr: "\u2194",
  le: "\u2264",
  ge: "\u2265",
  ne: "\u2260",
  asymp: "\u2248",
  infin: "\u221e",
  auml: "\u00e4",
  ouml: "\u00f6",
  uuml: "\u00fc",
  Auml: "\u00c4",
  Ouml: "\u00d6",
  Uuml: "\u00dc",
  szlig: "\u00df",
  aacute: "\u00e1",
  eacute: "\u00e9",
  iacute: "\u00ed",
  oacute: "\u00f3",
  uacute: "\u00fa",
  agrave: "\u00e0",
  egrave: "\u00e8",
  ecirc: "\u00ea",
  ccedil: "\u00e7",
  ntilde: "\u00f1",
  Eacute: "\u00c9",
};

// HTML maps numeric references in 0x80-0x9F to their windows-1252 meaning.
const C1: Record<number, number> = {
  0x80: 0x20ac,
  0x82: 0x201a,
  0x83: 0x0192,
  0x84: 0x201e,
  0x85: 0x2026,
  0x86: 0x2020,
  0x87: 0x2021,
  0x88: 0x02c6,
  0x89: 0x2030,
  0x8a: 0x0160,
  0x8b: 0x2039,
  0x8c: 0x0152,
  0x8e: 0x017d,
  0x91: 0x2018,
  0x92: 0x2019,
  0x93: 0x201c,
  0x94: 0x201d,
  0x95: 0x2022,
  0x96: 0x2013,
  0x97: 0x2014,
  0x98: 0x02dc,
  0x99: 0x2122,
  0x9a: 0x0161,
  0x9b: 0x203a,
  0x9c: 0x0153,
  0x9e: 0x017e,
  0x9f: 0x0178,
};

function fromCodePoint(n: number): string {
  if (!Number.isFinite(n) || n <= 0 || n > 0x10ffff || (n >= 0xd800 && n <= 0xdfff)) return "\ufffd";
  return String.fromCodePoint(C1[n] ?? n);
}

const REFERENCE = /&(?:#([0-9]+);?|#[xX]([0-9a-fA-F]+);?|([A-Za-z][A-Za-z0-9]{0,31});)/g;

/** Decodes numeric and the common named character references. */
export function decodeEntities(s: string): string {
  if (!s.includes("&")) return s;
  return s.replace(REFERENCE, (whole, dec?: string, hex?: string, name?: string) => {
    if (dec !== undefined) return fromCodePoint(Number.parseInt(dec, 10));
    if (hex !== undefined) return fromCodePoint(Number.parseInt(hex, 16));
    return name !== undefined && Object.hasOwn(NAMED, name) ? NAMED[name] : whole;
  });
}

export function collapseWhitespace(s: string): string {
  return s.replace(/\s+/g, " ").trim();
}

/** Removes tag-looking `<...>` runs in linear time. */
function stripTags(s: string): string {
  let out = "";
  let i = 0;
  while (i < s.length) {
    const lt = s.indexOf("<", i);
    if (lt < 0) break;
    const next = s.charCodeAt(lt + 1);
    const tagStart = next === 47 || next === 33 || (next | 32) >= 97 && (next | 32) <= 122;
    if (!tagStart) {
      out += s.slice(i, lt + 1);
      i = lt + 1;
      continue;
    }
    const gt = s.indexOf(">", lt);
    if (gt < 0) break;
    out += s.slice(i, lt) + " ";
    i = gt + 1;
  }
  return out + s.slice(i);
}

// C0 and C1 controls other than whitespace, DEL, and the bidirectional formatting marks
const CONTROLS = /[\u0000-\u0008\u000e-\u001f\u007f-\u0084\u0086-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]/g;

/** One line of plain text: line breaks (also NEL, LS, PS) and other
 * whitespace collapsed to single spaces, control characters removed. */
export function safeText(s: string): string {
  return s.replace(CONTROLS, "").replace(/[\s\u0085]+/g, " ").trim();
}

/** A backend field as plain one-line text; non-strings become "". */
export function cleanInline(v: unknown): string {
  return typeof v === "string" ? safeText(decodeEntities(stripTags(v))) : "";
}

/** Caps a snippet at `max` characters, cut at a word boundary where possible. */
export function capSnippet(s: string, max = 500): string {
  if (s.length <= max) return s;
  let cut = s.slice(0, max - 1);
  if (/[\ud800-\udbff]$/.test(cut)) cut = cut.slice(0, -1);
  const space = cut.lastIndexOf(" ");
  if (space >= max / 2) cut = cut.slice(0, space);
  return cut.trimEnd() + "\u2026";
}

export const MAX_OUTPUT_BYTES = 50 * 1024;
export const MAX_OUTPUT_LINES = 2000;

export function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes}B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)}KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)}MB`;
}

export interface Truncation {
  text: string;
  truncated: boolean;
}

/** Keeps the head of `text` within the byte and line caps, cut at a line
 * boundary (a single over-long first line is cut at a character boundary),
 * and appends a note when anything was dropped. */
export function truncateOutput(
  text: string,
  maxBytes = MAX_OUTPUT_BYTES,
  maxLines = MAX_OUTPUT_LINES,
): Truncation {
  const totalBytes = Buffer.byteLength(text, "utf8");
  const lines = text.split("\n");
  if (totalBytes <= maxBytes && lines.length <= maxLines) return { text, truncated: false };
  const kept: string[] = [];
  let bytes = 0;
  for (const line of lines.slice(0, maxLines)) {
    const size = Buffer.byteLength(line, "utf8") + (kept.length > 0 ? 1 : 0);
    if (bytes + size > maxBytes) break;
    kept.push(line);
    bytes += size;
  }
  if (kept.length === 0) {
    const buf = Buffer.from(lines[0], "utf8");
    let end = maxBytes;
    while (end > 0 && (buf[end] & 0xc0) === 0x80) end--;
    kept.push(buf.subarray(0, end).toString("utf8"));
    bytes = end;
  }
  const note =
    `[Output truncated: showing ${kept.length} of ${lines.length} lines ` +
    `(${formatSize(bytes)} of ${formatSize(totalBytes)}); the rest was omitted.]`;
  return { text: `${kept.join("\n")}\n\n${note}`, truncated: true };
}
