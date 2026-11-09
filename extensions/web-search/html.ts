// Local HTML to markdown conversion for web_fetch: a tolerant tokenizer, a
// small tree builder with the implied end tags real pages rely on, content
// selection (main / article / body) and a markdown renderer. No DOM, no
// dependency; every scan is linear (indexOf or a bounded stack walk), the
// tree depth is capped, nested one-line constructs are collapsed once, and
// rendering stops at an output budget that also pays for URL resolution, so
// adversarial input cannot blow up time, memory or stack.

import { decodeEntities } from "./text.ts";

interface Element {
  tag: string;
  attrs: Record<string, string>;
  children: Node[];
  hasBlock?: boolean;
  hasTable?: boolean;
}
type Node = Element | string;

export interface Converted {
  title?: string;
  markdown: string;
}

const MAX_DEPTH = 256; // open elements; deeper start tags attach flat
const MAX_NEST = 16; // quote/list levels that still indent
const SCOPE_SCAN = 64; // stack entries an implied end tag may look through
const OUTPUT_BUDGET = 256 * 1024; // characters of markdown; web_fetch shows 50 KiB of it
const MAX_COLUMNS = 50; // wider tables are one line per row, without padding
const MAX_BASE = 2048; // a longer <base href> is ignored: Node parses the base again for every link
const MAX_URL = 2048; // a longer link or image URL is dropped, its text stays
const BASE_CHARGE = 32; // base characters re-parsed per resolution that cost one budget unit
const TRUNCATED = "[truncated]";

const set = (s: string) => new Set(s.split(" "));
const VOID = set("area base br col embed hr img input link meta param source track wbr keygen frame basefont bgsound");
const RAW = set("script style xmp iframe noembed noframes noscript plaintext");
const RCDATA = set("textarea title");
const HEAD_OK = set("title meta link base style script noscript template");
const HEADINGS = set("h1 h2 h3 h4 h5 h6");
const CLOSES_P = set(
  "address article aside blockquote center details dialog dir div dl fieldset figcaption figure footer form " +
    "h1 h2 h3 h4 h5 h6 header hgroup hr main menu nav ol p pre section summary table ul li dd dt search listing",
);
const BLOCK = set(
  "#root html body address article aside blockquote center details dialog dir div dl dd dt fieldset figcaption " +
    "figure footer form h1 h2 h3 h4 h5 h6 header hgroup hr li main menu nav ol p pre section summary table " +
    "caption thead tbody tfoot tr td th ul legend search listing optgroup",
);
const DROP = set(
  "head script style noscript template svg math canvas iframe object embed input select button textarea " +
    "nav aside footer title meta link base option datalist frame frameset noembed noframes applet xmp plaintext",
);
const P_SCOPE = set("button table td th caption html template object marquee applet");
const LIST_SCOPE = set("ul ol menu dir table td th");
const DL_SCOPE = set("dl table td th");
const ROW_SCOPE = set("table tbody thead tfoot");
const CELL_SCOPE = set("tr table");
const SECTION_SCOPE = set("table");
const LINK_SCOPE = set("td th table caption");

const isSpace = (c: number) => c === 32 || c === 9 || c === 10 || c === 12 || c === 13;
const isAlpha = (c: number) => (c | 32) >= 97 && (c | 32) <= 122;

// ---- parsing ---------------------------------------------------------------------

interface Doc {
  root: Element;
  title?: string;
  base?: string;
}

interface TagToken {
  name: string;
  attrs: Record<string, string>;
  selfClosing: boolean;
  next: number;
}

/** Reads a start tag whose name begins at `p`; null at EOF inside the tag. */
function readTag(html: string, p: number): TagToken | null {
  const n = html.length;
  const nameStart = p;
  while (p < n) {
    const c = html.charCodeAt(p);
    if (isSpace(c) || c === 47 || c === 62) break;
    p++;
  }
  const name = html.slice(nameStart, p).toLowerCase();
  const attrs: Record<string, string> = {};
  let selfClosing = false;
  for (;;) {
    while (p < n && (isSpace(html.charCodeAt(p)) || html.charCodeAt(p) === 47)) {
      selfClosing = html.charCodeAt(p) === 47 && html.charCodeAt(p + 1) === 62;
      p++;
    }
    if (p >= n) return null;
    if (html.charCodeAt(p) === 62) return { name, attrs, selfClosing, next: p + 1 };
    const attrStart = p;
    p++; // the first character always belongs to the name (even "=")
    while (p < n) {
      const c = html.charCodeAt(p);
      if (isSpace(c) || c === 47 || c === 62 || c === 61) break;
      p++;
    }
    const attr = html.slice(attrStart, p).toLowerCase();
    while (p < n && isSpace(html.charCodeAt(p))) p++;
    let value = "";
    if (html.charCodeAt(p) === 61) {
      p++;
      while (p < n && isSpace(html.charCodeAt(p))) p++;
      const q = html.charCodeAt(p);
      if (q === 34 || q === 39) {
        const end = html.indexOf(q === 34 ? '"' : "'", p + 1);
        if (end < 0) return null;
        value = html.slice(p + 1, end);
        p = end + 1;
      } else {
        const vStart = p;
        while (p < n && !isSpace(html.charCodeAt(p)) && html.charCodeAt(p) !== 62) p++;
        value = html.slice(vStart, p);
      }
    }
    if (!Object.hasOwn(attrs, attr)) attrs[attr] = decodeEntities(value);
    selfClosing = false;
  }
}

/** Finds the end of raw text: `</name` (any case) then space, `/` or `>`. */
function rawEnd(html: string, from: number, name: string): { contentEnd: number; next: number } {
  const n = html.length;
  if (name === "plaintext") return { contentEnd: n, next: n };
  let p = from;
  for (;;) {
    const lt = html.indexOf("</", p);
    if (lt < 0) return { contentEnd: n, next: n };
    const after = lt + 2 + name.length;
    if (html.slice(lt + 2, after).toLowerCase() === name) {
      const c = html.charCodeAt(after);
      if (after >= n || isSpace(c) || c === 47 || c === 62) {
        const gt = html.indexOf(">", after);
        return { contentEnd: lt, next: gt < 0 ? n : gt + 1 };
      }
    }
    p = lt + 2;
  }
}

function collapse(s: string): string {
  return s.replace(/\s+/g, " ").trim();
}

function parse(html: string): Doc {
  const root: Element = { tag: "#root", attrs: {}, children: [] };
  const doc: Doc = { root };
  const stack: Element[] = [root];
  const open = new Map<string, number>();
  const count = (t: string) => open.get(t) ?? 0;
  const top = () => stack[stack.length - 1];
  const pop = () => {
    const e = stack.pop() as Element;
    open.set(e.tag, count(e.tag) - 1);
  };
  const popTo = (index: number) => {
    while (stack.length > index) pop();
  };
  // Closes the nearest open element named in `tags` unless a scope boundary
  // comes first; looks at most SCOPE_SCAN entries down.
  const closeOpen = (tags: string[], scope: Set<string>) => {
    if (!tags.some((t) => count(t) > 0)) return;
    for (let i = stack.length - 1, seen = 0; i > 0 && seen < SCOPE_SCAN; i--, seen++) {
      const t = stack[i].tag;
      if (tags.includes(t)) return popTo(i);
      if (scope.has(t)) return;
    }
  };
  const append = (node: Node) => {
    const kids = top().children;
    if (typeof node === "string" && typeof kids[kids.length - 1] === "string") kids[kids.length - 1] += node;
    else kids.push(node);
  };
  const text = (s: string) => {
    if (top().tag === "head" && /\S/.test(s)) pop();
    append(s);
  };
  const start = (name: string, attrs: Record<string, string>, selfClosing: boolean): Element => {
    if (top().tag === "head" && !HEAD_OK.has(name)) pop();
    if (name === "body" && count("head") > 0) closeOpen(["head"], new Set());
    if (CLOSES_P.has(name)) closeOpen(["p"], P_SCOPE);
    if (name === "li") closeOpen(["li"], LIST_SCOPE);
    else if (name === "dt" || name === "dd") closeOpen(["dt", "dd"], DL_SCOPE);
    else if (name === "tr") closeOpen(["tr"], ROW_SCOPE);
    else if (name === "td" || name === "th") closeOpen(["td", "th"], CELL_SCOPE);
    else if (name === "tbody" || name === "thead" || name === "tfoot") closeOpen(["tbody", "thead", "tfoot"], SECTION_SCOPE);
    else if (name === "a") closeOpen(["a"], LINK_SCOPE);
    else if (name === "option" && top().tag === "option") pop();
    if (HEADINGS.has(name) && HEADINGS.has(top().tag)) pop();
    const el: Element = { tag: name, attrs, children: [] };
    if (name === "base" && doc.base === undefined && attrs.href) doc.base = attrs.href;
    append(el);
    const foreign = count("svg") > 0 || count("math") > 0;
    if (!VOID.has(name) && !(selfClosing && foreign) && stack.length < MAX_DEPTH) {
      stack.push(el);
      open.set(name, count(name) + 1);
    }
    return el;
  };
  const end = (name: string) => {
    if (name === "br") return void start("br", {}, false);
    if (name === "html" || name === "body" || count(name) === 0) return;
    for (let i = stack.length - 1; i > 0; i--) if (stack[i].tag === name) return popTo(i);
  };

  const n = html.length;
  let i = 0;
  while (i < n) {
    const lt = html.indexOf("<", i);
    if (lt < 0) {
      text(decodeEntities(html.slice(i)));
      break;
    }
    if (lt > i) text(decodeEntities(html.slice(i, lt)));
    i = lt;
    const c = html.charCodeAt(i + 1);
    if (html.startsWith("<!--", i)) {
      const e = html.indexOf("-->", i + 4);
      i = e < 0 ? n : e + 3;
    } else if (c === 33 || c === 63) {
      // doctype, CDATA, processing instruction: skipped like comments
      const e = html.indexOf(">", i + 2);
      i = e < 0 ? n : e + 1;
    } else if (c === 47) {
      let p = i + 2;
      if (isAlpha(html.charCodeAt(p))) {
        while (p < n && !isSpace(html.charCodeAt(p)) && html.charCodeAt(p) !== 47 && html.charCodeAt(p) !== 62) p++;
        end(html.slice(i + 2, p).toLowerCase());
      }
      const e = html.indexOf(">", p);
      i = e < 0 ? n : e + 1;
    } else if (isAlpha(c)) {
      const tag = readTag(html, i + 1);
      if (tag === null) break; // EOF inside a tag: the rest is dropped
      const el = start(tag.name, tag.attrs, tag.selfClosing);
      i = tag.next;
      if (RAW.has(tag.name) || RCDATA.has(tag.name)) {
        const r = rawEnd(html, i, tag.name);
        const content = html.slice(i, r.contentEnd);
        const value = RCDATA.has(tag.name) ? decodeEntities(content) : content;
        if (value) el.children.push(value);
        if (top() === el) pop();
        if (tag.name === "title" && doc.title === undefined && count("svg") === 0 && count("math") === 0) {
          doc.title = collapse(value);
        }
        i = r.next;
      }
    } else {
      text("<");
      i++;
    }
  }
  return doc;
}

// ---- rendering ---------------------------------------------------------------------

interface Ctx {
  base: string | null;
  nest: number;
  /** inside a construct rendered on one line, which collapses its content once */
  flat: boolean;
  /** characters of output left, shared by the whole conversion */
  budget: { left: number };
}

const spent = (ctx: Ctx) => ctx.budget.left <= 0;
const spend = (ctx: Ctx, n: number) => {
  ctx.budget.left -= n;
};
/** What a line break costs: the newline and up to two prefix characters per
 * level of indentation or quoting. */
const lineCost = (ctx: Ctx) => 1 + 2 * Math.min(ctx.nest, MAX_NEST);

/** The longest start of `s` whose output, line prefixes included, fits in
 * `share` of the budget left; the budget is charged for it. */
function take(ctx: Ctx, s: string, share = 1): string {
  const limit = Math.floor(Math.max(0, ctx.budget.left) * share);
  const per = lineCost(ctx);
  let end = s.length;
  let cost = 0;
  for (let i = 0; i < s.length; i++) {
    cost += s.charCodeAt(i) === 10 ? per : 1;
    if (cost > limit) {
      end = i > 0 && (s.charCodeAt(i - 1) & 0xfc00) === 0xd800 ? i - 1 : i; // keep surrogate pairs whole
      cost = limit + 1; // the budget is used up
      break;
    }
  }
  spend(ctx, cost);
  return end === s.length ? s : s.slice(0, end);
}

function skip(el: Element): boolean {
  return DROP.has(el.tag) || Object.hasOwn(el.attrs, "hidden") || el.attrs["aria-hidden"]?.trim().toLowerCase() === "true";
}

function hasBlock(el: Element): boolean {
  if (el.hasBlock === undefined) {
    el.hasBlock = el.children.some((c) => typeof c !== "string" && !skip(c) && (BLOCK.has(c.tag) || hasBlock(c)));
  }
  return el.hasBlock;
}

function textContent(el: Element): string {
  let s = "";
  for (const c of el.children) {
    if (typeof c === "string") s += c;
    else if (c.tag === "br") s += "\n";
    else if (!skip(c)) s += textContent(c);
  }
  return s;
}

/** The absolute URL of a link that is about to be emitted, or null. Each
 * resolution parses the base again (on Node), so it is charged in proportion
 * to the base's length; a resolved URL over MAX_URL is dropped. */
function resolveUrl(raw: string | undefined, ctx: Ctx): string | null {
  const href = raw?.trim();
  if (!href || href.startsWith("#") || spent(ctx)) return null;
  const scheme = href.replace(/[\u0000-\u0020]/g, "").toLowerCase();
  if (scheme.startsWith("javascript:") || scheme.startsWith("data:") || scheme.startsWith("vbscript:")) return null;
  if (ctx.base !== null) spend(ctx, Math.ceil(ctx.base.length / BASE_CHARGE));
  let url: string;
  try {
    url = ctx.base === null ? new URL(href).href : new URL(href, ctx.base).href;
  } catch {
    return null;
  }
  return url.length > MAX_URL ? null : url;
}

function longestRun(s: string, ch: string): number {
  let best = 0;
  let run = 0;
  for (let i = 0; i < s.length; i++) {
    run = s[i] === ch ? run + 1 : 0;
    if (run > best) best = run;
  }
  return best;
}

/** Moves surrounding whitespace outside of `open`/`close` markers. */
function wrap(inner: string, open: string, close = open): string {
  const core = inner.trim();
  if (!core) return inner;
  const lead = inner.length - inner.trimStart().length;
  const trail = inner.length - inner.trimEnd().length;
  return inner.slice(0, lead) + open + core + close + inner.slice(inner.length - trail);
}

function codeSpan(text: string, ctx: Ctx): string {
  const t = take(ctx, collapse(text), 1 / 3); // each fence can be as long as the text
  if (!t) return "";
  const fence = "`".repeat(longestRun(t, "`") + 1);
  const pad = t.startsWith("`") || t.endsWith("`") ? " " : "";
  spend(ctx, 2 * (fence.length + pad.length));
  return fence + pad + t + pad + fence;
}

const oneLine = (s: string) => collapse(s.replace(/\n/g, " "));

/** `nodes` rendered on one line. Inside another one-line construct they are
 * rendered inline and left to the outer one to collapse, so nesting such
 * constructs stays linear. */
function oneLineOf(nodes: Node[], ctx: Ctx, render: (nodes: Node[], ctx: Ctx) => string): string {
  return ctx.flat ? inlineOf(nodes, ctx) : oneLine(render(nodes, { ...ctx, flat: true }));
}

function inlineOf(nodes: Node[], ctx: Ctx): string {
  let s = "";
  for (const node of nodes) {
    if (spent(ctx)) break;
    if (typeof node === "string") s += take(ctx, node.replace(/\s+/g, " "));
    else if (skip(node)) continue;
    else if (BLOCK.has(node.tag)) {
      s += ` ${ctx.flat ? inlineOf(node.children, ctx) : oneLine(renderBlock(node, { ...ctx, flat: true }))} `;
    } else s += renderInline(node, ctx);
  }
  return s;
}

function renderInline(el: Element, ctx: Ctx): string {
  switch (el.tag) {
    case "br":
      spend(ctx, lineCost(ctx));
      return "\n";
    case "img": {
      const alt = take(ctx, collapse(el.attrs.alt ?? ""));
      if (!alt) return "";
      const src = resolveUrl(el.attrs.src, ctx);
      if (src) spend(ctx, src.length + 5);
      return src ? `![${alt}](${src})` : alt;
    }
    case "a": {
      const inner = inlineOf(el.children, ctx);
      if (!inner.trim()) return inner;
      const href = resolveUrl(el.attrs.href, ctx);
      if (!href) return inner;
      spend(ctx, href.length + 4);
      return wrap(inner.replace(/\n/g, " "), "[", `](${href})`);
    }
    case "strong":
    case "b":
      spend(ctx, 4);
      return wrap(inlineOf(el.children, ctx), "**");
    case "em":
    case "i":
      spend(ctx, 2);
      return wrap(inlineOf(el.children, ctx), "_");
    case "code":
      return codeSpan(textContent(el), ctx);
    default:
      return inlineOf(el.children, ctx);
  }
}

/** Inline text of a paragraph: single spaces, line breaks only from <br>,
 * at most one blank line, trimmed. */
function cleanParagraph(s: string): string {
  if (!s.includes("\n") && !s.includes("  ")) return s.trim();
  return s
    .replace(/ {2,}/g, " ")
    .replace(/ ?\n ?/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

// Blocks are appended with `+` (V8 keeps the result as a rope), so deep
// nesting does not copy the whole content once per level.
interface Flow {
  out: string;
  sep: string;
  inline: string;
}

function emit(f: Flow, block: string, ctx: Ctx): void {
  if (!block) return;
  if (f.out) spend(ctx, f.sep.length * lineCost(ctx));
  f.out = f.out ? f.out + f.sep + block : block;
}

function flush(f: Flow, ctx: Ctx): void {
  if (f.inline) emit(f, cleanParagraph(f.inline), ctx);
  f.inline = "";
}

function flow(nodes: Node[], ctx: Ctx, f: Flow): void {
  for (const node of nodes) {
    if (spent(ctx)) break;
    if (typeof node === "string") {
      f.inline += take(ctx, node.replace(/\s+/g, " "));
    } else if (skip(node)) {
      continue;
    } else if (BLOCK.has(node.tag)) {
      flush(f, ctx);
      emit(f, renderBlock(node, ctx), ctx);
    } else if (hasBlock(node)) {
      flow(node.children, ctx, f); // an inline wrapper around blocks: keep the blocks
    } else {
      f.inline += renderInline(node, ctx);
    }
  }
}

function renderContainer(nodes: Node[], ctx: Ctx, sep = "\n\n"): string {
  const f: Flow = { out: "", sep, inline: "" };
  flow(nodes, ctx, f);
  flush(f, ctx);
  return f.out;
}

const deeper = (ctx: Ctx): Ctx => ({ ...ctx, nest: ctx.nest + 1 });
const indent = (body: string, by: string) =>
  by
    ? body
        .split("\n")
        .map((l) => (l ? by + l : l))
        .join("\n")
    : body;

function renderPre(el: Element, ctx: Ctx): string {
  let text = textContent(el);
  if (text.startsWith("\r\n")) text = text.slice(2);
  else if (text.startsWith("\n")) text = text.slice(1);
  text = text
    .replace(/\r\n?/g, "\n")
    .split("\n")
    .map((l) => l.trimEnd())
    .join("\n");
  let end = text.length;
  while (end > 0 && text.charCodeAt(end - 1) === 10) end--;
  text = text.slice(0, end);
  if (!text.trim()) return "";
  text = take(ctx, text, 1 / 3); // the fences can be as long as the text
  const code = el.children.find((c): c is Element => typeof c !== "string" && c.tag === "code");
  const classes = `${el.attrs.class ?? ""} ${code?.attrs.class ?? ""}`;
  const lang = /(?:^|\s)(?:language|lang)-([A-Za-z0-9_+#.-]+)/.exec(classes)?.[1] ?? "";
  const fence = "`".repeat(Math.max(3, longestRun(text, "`") + 1));
  spend(ctx, 2 * fence.length + lang.length + 2 * lineCost(ctx));
  return `${fence}${lang}\n${text}\n${fence}`;
}

function renderList(el: Element, ctx: Ctx): string {
  const ordered = el.tag === "ol";
  const start = Number.parseInt(el.attrs.start ?? "", 10);
  let n = Number.isFinite(start) ? start : 1;
  const by = ctx.nest < MAX_NEST ? "  " : "";
  const lines: string[] = [];
  for (const child of el.children) {
    if (spent(ctx)) break;
    if (typeof child === "string") {
      if (child.trim()) lines.push(take(ctx, collapse(child)));
      continue;
    }
    if (skip(child)) continue;
    spend(ctx, lineCost(ctx));
    if (child.tag !== "li") {
      const other = BLOCK.has(child.tag) ? renderBlock(child, deeper(ctx)) : cleanParagraph(renderInline(child, ctx));
      if (other) lines.push(indent(other, by));
      continue;
    }
    const marker = ordered ? `${n}. ` : "- ";
    n++;
    spend(ctx, marker.length);
    const body = renderContainer(child.children, deeper(ctx), "\n");
    if (!body) continue;
    lines.push(by ? marker + indent(body, by).slice(by.length) : marker + body);
  }
  return lines.join("\n");
}

function rowsOf(table: Element): Element[] {
  const rows: Element[] = [];
  for (const c of table.children) {
    if (typeof c === "string" || skip(c)) continue;
    if (c.tag === "tr") rows.push(c);
    else if (c.tag === "thead" || c.tag === "tbody" || c.tag === "tfoot") {
      for (const r of c.children) if (typeof r !== "string" && r.tag === "tr" && !skip(r)) rows.push(r);
    }
  }
  return rows;
}

const cellsOf = (row: Element) =>
  row.children.filter((c): c is Element => typeof c !== "string" && (c.tag === "td" || c.tag === "th") && !skip(c));

function containsTable(el: Element): boolean {
  if (el.hasTable === undefined) {
    el.hasTable = el.children.some((c) => typeof c !== "string" && (c.tag === "table" || containsTable(c)));
  }
  return el.hasTable;
}

function renderTable(el: Element, ctx: Ctx): string {
  const rows = rowsOf(el);
  const caption = el.children.find((c): c is Element => typeof c !== "string" && c.tag === "caption");
  const head = caption ? oneLineOf(caption.children, ctx, renderContainer) : "";
  if (head) spend(ctx, 2 * lineCost(ctx));
  const cells = rows.map(cellsOf);
  if (cells.some((r) => r.some(containsTable))) {
    // a layout table: its cells are page sections, not data
    const parts = [head];
    for (const r of cells) {
      for (const c of r) {
        if (spent(ctx)) break;
        const part = renderContainer(c.children, ctx);
        if (part) spend(ctx, 2 * lineCost(ctx));
        parts.push(part);
      }
    }
    return parts.filter(Boolean).join("\n\n");
  }
  const width = cells.reduce((w, r) => Math.max(w, r.length), 0);
  if (width === 0) return head;
  const cellText = (c: Element) =>
    oneLineOf(c.children, ctx, (nodes, x) => renderContainer(nodes, x, " ")).replace(/\|/g, "\\|");
  const rowText = (r: Element[]) => {
    const out: string[] = [];
    for (const c of r) {
      if (spent(ctx)) break;
      out.push(cellText(c));
    }
    return out;
  };
  const span = (c: Element, a: string) => (Number.parseInt(c.attrs[a] ?? "1", 10) || 1) > 1;
  const body: string[] = [];
  const line = (l: string) => {
    spend(ctx, l.length + lineCost(ctx));
    body.push(l);
  };
  if (width > MAX_COLUMNS || cells.some((r) => r.some((c) => span(c, "rowspan") || span(c, "colspan")))) {
    for (const r of cells) {
      if (spent(ctx)) break;
      const l = rowText(r).join(" | ").trim();
      if (l.replace(/[|\s]/g, "")) line(l);
    }
  } else {
    const pipe = (r: string[]) => `| ${[...r, ...Array<string>(width - r.length).fill("")].join(" | ")} |`;
    line(pipe(rowText(cells[0])));
    line(`| ${Array<string>(width).fill("---").join(" | ")} |`);
    for (let i = 1; i < cells.length && !spent(ctx); i++) line(pipe(rowText(cells[i])));
  }
  return [head, body.join("\n")].filter(Boolean).join("\n\n");
}

function renderDl(el: Element, ctx: Ctx): string {
  const by = ctx.nest < MAX_NEST ? "  " : "";
  const lines: string[] = [];
  const walk = (nodes: Node[]) => {
    for (const c of nodes) {
      if (spent(ctx)) return;
      if (typeof c === "string" || skip(c)) continue;
      if (c.tag === "dt") {
        spend(ctx, lineCost(ctx));
        const t = oneLineOf(c.children, ctx, renderContainer);
        if (t) lines.push(t);
      } else if (c.tag === "dd") {
        spend(ctx, lineCost(ctx));
        const d = renderContainer(c.children, deeper(ctx), "\n");
        if (d) lines.push(indent(d, by));
      } else if (c.tag === "div") {
        walk(c.children);
      }
    }
  };
  walk(el.children);
  return lines.join("\n");
}

function renderBlock(el: Element, ctx: Ctx): string {
  const tag = el.tag;
  if (HEADINGS.has(tag)) {
    const t = oneLineOf(el.children, ctx, inlineOf);
    if (!t.trim()) return "";
    spend(ctx, Number(tag[1]) + 1);
    return `${"#".repeat(Number(tag[1]))} ${t}`;
  }
  switch (tag) {
    case "hr":
      spend(ctx, 3);
      return "---";
    case "pre":
    case "listing":
      return renderPre(el, ctx);
    case "blockquote": {
      if (ctx.nest >= MAX_NEST) return renderContainer(el.children, ctx); // too deep to prefix
      const inner = renderContainer(el.children, deeper(ctx));
      return inner
        ? inner
            .split("\n")
            .map((l) => (l ? `> ${l}` : ">"))
            .join("\n")
        : "";
    }
    case "ul":
    case "ol":
    case "menu":
    case "dir":
      return renderList(el, ctx);
    case "table":
      return renderTable(el, ctx);
    case "dl":
      return renderDl(el, ctx);
    default:
      return renderContainer(el.children, ctx);
  }
}

// ---- content selection ------------------------------------------------------------

function collect(root: Element): { main: Element[]; article: Element[]; body: Element[]; h1: Element[] } {
  const found = { main: [] as Element[], article: [] as Element[], body: [] as Element[], h1: [] as Element[] };
  const todo: Element[] = [root];
  while (todo.length > 0) {
    const el = todo.pop() as Element;
    if (el.tag === "main" || el.tag === "article" || el.tag === "body" || el.tag === "h1") found[el.tag].push(el);
    for (let i = el.children.length - 1; i >= 0; i--) {
      const c = el.children[i];
      if (typeof c !== "string" && !skip(c)) todo.push(c);
    }
  }
  return found;
}

function baseOf(doc: Doc, pageUrl: string): string | null {
  let page: string | null = null;
  try {
    page = new URL(pageUrl).href;
  } catch {
    page = null;
  }
  if (doc.base !== undefined && doc.base.length <= MAX_BASE) {
    try {
      return page === null ? new URL(doc.base).href : new URL(doc.base, page).href;
    } catch {
      // fall back to the page URL
    }
  }
  return page;
}

/** Converts an HTML document to markdown. `pageUrl` (the final URL) resolves
 * relative links unless the document has a `<base href>` (of at most 2 KiB).
 * Output cut by the budget ends with a "[truncated]" line. Never throws. */
export function htmlToMarkdown(html: string, pageUrl: string): Converted {
  const doc = parse(html);
  const found = collect(doc.root);
  const root =
    found.main.length === 1 ? found.main[0] : found.article.length === 1 ? found.article[0] : (found.body[0] ?? doc.root);
  const ctx: Ctx = { base: baseOf(doc, pageUrl), nest: 0, flat: false, budget: { left: OUTPUT_BUDGET } };
  let markdown = renderContainer(root.children, ctx)
    .split("\n")
    .map((l) => l.trimEnd())
    .join("\n")
    .trim();
  if (spent(ctx)) markdown += `\n\n${TRUNCATED}`;
  const title = doc.title || (found.h1.length > 0 ? collapse(textContent(found.h1[0])) : "") || undefined;
  return { title, markdown };
}
