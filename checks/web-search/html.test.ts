// Local HTML to markdown conversion: input -> exact expected text.
import assert from "node:assert/strict";
import { test } from "node:test";
import { htmlToMarkdown } from "../../extensions/web-search/html.ts";

const PAGE = "https://example.com/docs/page.html";
const md = (html: string, page = PAGE) => htmlToMarkdown(html, page).markdown;

test("headings and paragraphs", () => {
  assert.equal(
    md("<h1>Title</h1><p>First   para\ngraph.</p><H2>Sub</H2><p>Second</p><h6>Six</h6>"),
    "# Title\n\nFirst para graph.\n\n## Sub\n\nSecond\n\n###### Six",
  );
});

test("unclosed paragraphs, divs, br and hr", () => {
  assert.equal(md("<p>one<p>two<div>three</div>four<br>five<hr>six"), "one\n\ntwo\n\nthree\n\nfour\nfive\n\n---\n\nsix");
});

test("unordered, ordered with start, nested lists", () => {
  assert.equal(md("<ul><li>a<li>b<ul><li>c</li><li>d</li></ul><li>e</ul>"), "- a\n- b\n  - c\n  - d\n- e");
  assert.equal(md('<ol start="3"><li>x</li><li>y</li></ol>'), "3. x\n4. y");
  assert.equal(md("<ol><li>one<ol><li>sub</li></ol></li><li>two</li></ol>"), "1. one\n  1. sub\n2. two");
});

test("links: relative, absolute, base href, javascript:, fragment-only, empty text", () => {
  assert.equal(md('<p><a href="other.html">rel</a> <a href="/abs">root</a> <a href="https://x.example/y">ext</a></p>'),
    "[rel](https://example.com/docs/other.html) [root](https://example.com/abs) [ext](https://x.example/y)");
  assert.equal(md('<head><base href="https://cdn.example/base/"></head><body><a href="z">z</a></body>'), "[z](https://cdn.example/base/z)");
  assert.equal(md('<a href="javascript:alert(1)">js</a> <a href="#top">frag</a> <a href="">empty</a> <a href="data:text/html,x">data</a>'),
    "js frag empty data");
  assert.equal(md('a<a href="/x"> </a>b'), "a b");
});

test("images with and without alt", () => {
  assert.equal(md('<p><img src="pic.png" alt="A cat"> <img src="deco.png"> <img src="x.png" alt=""></p>'),
    "![A cat](https://example.com/docs/pic.png)");
});

test("emphasis, inline code, code with backticks", () => {
  assert.equal(md("<p><strong>bold</strong> <b>b</b> <em>it</em> <i>i</i> <code>x = 1</code></p>"), "**bold** **b** _it_ _i_ `x = 1`");
  assert.equal(md("<p>use <code>a`b</code> here</p>"), "use ``a`b`` here");
  assert.equal(md("<p>x<b> spaced </b>y</p>"), "x **spaced** y");
});

test("pre with language class keeps whitespace", () => {
  assert.equal(
    md('<pre><code class="language-nix">{ a = 1;\n  b = 2; }\n</code></pre>'),
    "```nix\n{ a = 1;\n  b = 2; }\n```",
  );
  assert.equal(md('<pre class="lang-sh">ls  -l</pre>'), "```sh\nls  -l\n```");
  assert.equal(md("<pre>a ``` b</pre>"), "````\na ``` b\n````");
  assert.equal(md("<pre>\n\n\nx\n\n\n\ny</pre>"), "```\n\n\nx\n\n\n\ny\n```");
});

test("blockquote", () => {
  assert.equal(md("<blockquote><p>one</p><p>two</p></blockquote>"), "> one\n>\n> two");
});

test("simple table becomes a pipe table", () => {
  assert.equal(
    md("<table><thead><tr><th>Name</th><th>Value</th></tr></thead><tbody><tr><td>a|b</td><td>1</td></tr><tr><td>c<td>2</table>"),
    "| Name | Value |\n| --- | --- |\n| a\\|b | 1 |\n| c | 2 |",
  );
});

test("table with spans becomes one line per row", () => {
  assert.equal(
    md('<table><tr><th colspan="2">Head</th></tr><tr><td>a</td><td>b</td></tr></table>'),
    "Head\na | b",
  );
});

test("definition list", () => {
  assert.equal(md("<dl><dt>Term</dt><dd>Definition</dd><dt>T2<dd>D2</dl>"), "Term\n  Definition\nT2\n  D2");
});

test("entities: named, decimal, hex, unknown", () => {
  assert.equal(md("<p>a &amp; b &lt;c&gt; &#169; &#x2014; &nbsp;x &unknown; &mdash;</p>"), "a & b <c> \u00a9 \u2014 x &unknown; \u2014");
});

test("dropped elements", () => {
  const html =
    "<body><nav>menu</nav><script>var x = '<p>no</p>';</script><style>p{}</style><p>keep</p>" +
    "<aside>side</aside><div hidden>h</div><span aria-hidden=\"true\">ah</span><span aria-hidden=\"false\">shown</span>" +
    "<noscript>ns</noscript><template><p>t</p></template><svg><title>s</title><text>svg</text></svg>" +
    "<form><input value=v><button>btn</button><select><option>o</option></select><textarea>ta</textarea>label</form>" +
    "<iframe src=x>if</iframe><footer>foot</footer></body>";
  assert.equal(md(html), "keep\n\nshown\n\nlabel");
});

test("root: a single main wins, then a single article, else body", () => {
  assert.equal(md("<body><p>outside</p><main><p>inside</p></main></body>"), "inside");
  assert.equal(md("<body><p>outside</p><article>art</article></body>"), "art");
  assert.equal(md("<body><p>outside</p><article>a1</article><article>a2</article></body>"), "outside\n\na1\n\na2");
  assert.equal(md("<main>m1</main><main>m2</main><article>only</article>"), "only");
});

test("title from <title>, else the first h1", () => {
  assert.equal(htmlToMarkdown("<html><head><title> My &amp; Page </title></head><body><h1>H</h1></body></html>", PAGE).title, "My & Page");
  assert.equal(htmlToMarkdown("<body><h1>The <em>Head</em></h1><h1>Second</h1></body>", PAGE).title, "The Head");
  assert.equal(htmlToMarkdown("<p>none</p>", PAGE).title, undefined);
  assert.equal(md("<title>T</title><p>body</p>"), "body");
});

test("head without end tag does not swallow the body", () => {
  assert.equal(md("<html><head><title>t</title><meta charset=utf-8><body><p>text</p>"), "text");
  assert.equal(md("<head><title>t</title><p>text"), "text");
});

test("tolerant parsing: uppercase, unquoted and valueless attributes, comments, doctype, CDATA, PI, stray end tags", () => {
  const html =
    "<!DOCTYPE html><?xml version='1.0'?><HTML><BODY><!-- c <p>no</p> --><P CLASS=x DATA-y>one</P></span></div>" +
    "<![CDATA[ cdata ]]><A HREF=/q?a=1&amp;b=2 download>two</A><input disabled></BODY></HTML>";
  assert.equal(md(html), "one\n\n[two](https://example.com/q?a=1&b=2)");
});

test("whitespace: at most one blank line, lines right-trimmed, output trimmed", () => {
  assert.equal(md("  <p>a  </p>\n\n\n<p></p><div> </div><p>  b</p>  "), "a\n\nb");
});

test("inline element wrapping blocks does not merge them", () => {
  assert.equal(md('<a href="/c"><div><h3>Card</h3><p>Text</p></div></a>'), "### Card\n\nText");
});

// ---- robustness ------------------------------------------------------------------

const CORPUS = [
  "<html><head><title>x</title></head><body><main><h1>A</h1><p>b <a href='/c'>c</a></p><ul><li>d<li>e</ul></main></body></html>",
  "<table><tr><td>1<td>2<tr><td>3</table><pre class=language-js>x</pre><dl><dt>t<dd>d</dl>",
  "<blockquote><ol start=5><li><code>a`b</code></ol></blockquote><img alt=i src=/i.png><br><hr>",
  "<script>if (a < b) {}</script><style>a>b{}</style><!-- x --><![CDATA[y]]><?pi?>&amp;&#65;&#x42;&bogus;",
];

function rng(seed: number) {
  let s = seed >>> 0;
  return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 2 ** 32);
}

test("property: truncated and shuffled fixtures never throw", () => {
  const rand = rng(7);
  for (const doc of CORPUS) {
    for (let cut = 0; cut <= doc.length; cut++) htmlToMarkdown(doc.slice(0, cut), PAGE);
    for (let n = 0; n < 200; n++) {
      const pieces = doc.split(/(?=<)|(?<=>)/);
      for (let i = pieces.length - 1; i > 0; i--) {
        const j = Math.floor(rand() * (i + 1));
        [pieces[i], pieces[j]] = [pieces[j], pieces[i]];
      }
      const r = htmlToMarkdown(pieces.join(""), rand() < 0.5 ? PAGE : "not a url");
      assert.equal(typeof r.markdown, "string");
    }
  }
});

test("2 MiB adversarial inputs convert in under 2 s each", () => {
  const size = 2 * 1024 * 1024;
  const fill = (unit: string) => unit.repeat(Math.floor(size / unit.length));
  const inputs = [
    fill("<div>"),
    fill("<a href='x'>"),
    "<!--" + fill("-"),
    fill("&amp;"),
    fill("<p>x"),
    fill("<ul><li>"),
    fill("<table><tr><td>"),
    fill("<blockquote>") + fill("text\n"),
    "<a " + fill("b=c "),
    fill("<a<"),
    "<pre>" + fill("x\n\n\n"),
    fill("<b><i>x</i></b>"),
    fill("</p>"),
    "<p a='" + fill("x"),
    fill("<span>").slice(0, size / 2) + fill("</span>").slice(0, size / 2),
    fill("<ol><li><blockquote>a"),
  ];
  for (const input of inputs) {
    const t0 = performance.now();
    htmlToMarkdown(input, PAGE);
    const ms = performance.now() - t0;
    assert.ok(ms < 2000, `${input.slice(0, 30)}...: ${ms.toFixed(0)} ms`);
  }
});

// ---- output budget, column cap and nesting caps -------------------------------------

// The renderer stops at an output budget of 256 KiB (web_fetch shows 50 KiB);
// one more block may finish, so the bound here leaves room for it.
const BOUND = 320 * 1024;
const MIB2 = 2 * 1024 * 1024;
const fillTo = (unit: string, total = MIB2) => unit.repeat(Math.floor(total / unit.length));

function bounded(name: string, html: string, page = PAGE): string {
  const t0 = performance.now();
  const out = htmlToMarkdown(html, page).markdown;
  const ms = performance.now() - t0;
  assert.ok(ms < 2000, `${name}: ${ms.toFixed(0)} ms`);
  assert.ok(out.length <= BOUND, `${name}: ${out.length} characters of markdown`);
  return out;
}

test("table: one wide row and many one-cell rows stay small and fast (W x R)", () => {
  bounded("12000 x 12000", "<table><tr>" + "<td>".repeat(12000) + "<tr><td>x".repeat(12000) + "</table>");
});

test("table: 2 MiB of one-cell rows neither throws nor grows", () => {
  const out = bounded("one-cell rows", "<table>" + fillTo("<tr><td>x"));
  assert.ok(out.startsWith("| x |\n| --- |\n| x |"), out.slice(0, 40));
});

test("table: more than 50 columns render one line per row, without padding", () => {
  const cells = (n: number, p: string) => Array.from({ length: n }, (_, i) => `${p}${i}`);
  const html = `<table><tr>${cells(51, "h").map((c) => `<th>${c}`).join("")}<tr><td>a<td>b</table>`;
  assert.equal(md(html), `${cells(51, "h").join(" | ")}\na | b`);
  const fifty = `<table><tr>${cells(50, "h").map((c) => `<th>${c}`).join("")}<tr><td>a</table>`;
  assert.equal(md(fifty).split("\n")[2], `| a |${"  |".repeat(49)}`);
});

test("output budget: a long page is cut, keeping its beginning", () => {
  const out = bounded("paragraphs", "<p>first</p>" + fillTo("<p>some paragraph text</p>"));
  assert.ok(out.startsWith("first\n\nsome paragraph text"));
  assert.ok(out.length > 200 * 1024, `${out.length}`); // still more than web_fetch shows
});

test("output budget: a cut is marked with a last [truncated] line", () => {
  const out = bounded("paragraphs", fillTo("<p>some paragraph text</p>"));
  assert.ok(out.endsWith("\n\n[truncated]"), out.slice(-60));
  assert.ok(!md("<p>short</p>").includes("[truncated]"));
});

// Resolving a link parses its base again on Node (about 1.5 ms per MiB), so a long
// base must not be resolved once per link for free.
test("links: a <base href> over 2 KiB is ignored, the page URL resolves instead", () => {
  const long = `https://cdn.example/${"A".repeat(2100)}/`;
  assert.equal(md(`<base href="${long}"><a href="z">z</a>`), "[z](https://example.com/docs/z)");
  const ok = `https://cdn.example/${"A".repeat(1900)}/`;
  assert.equal(md(`<base href="${ok}"><a href="z">z</a>`), `[z](${ok}z)`);
});

test("links: a resolved URL over 2 KiB is dropped, the text stays", () => {
  const long = `https://e.example/${"B".repeat(2100)}`;
  assert.equal(md(`<p><a href="${long}">text</a> <img alt="pic" src="${long}"></p>`), "text pic");
});

test("links: control characters in a URL are percent-encoded", () => {
  assert.equal(md('<a href="/a&#10;b">x</a>'), "[x](https://example.com/ab)");
});

const BASE_1M = `<base href="http://x.test/${"A".repeat(1024 * 1024)}">`;
const LONG_PAGE = `https://example.com/${"A".repeat(16 * 1024)}`;
const LINK_CASES: [string, string, string?][] = [
  ["1 MiB base + empty links", BASE_1M + fillTo("<a href=y></a>", MIB2 - BASE_1M.length)],
  ["1 MiB base + blank links", BASE_1M + fillTo("<a href=y> </a>", MIB2 - BASE_1M.length)],
  ["1 MiB base + links with text", BASE_1M + fillTo("<a href=y>t</a>", MIB2 - BASE_1M.length)],
  ["1 MiB base + images", BASE_1M + fillTo("<img src=y alt=t>", MIB2 - BASE_1M.length)],
  ["16 KiB page URL + empty links", fillTo("<a href=y></a>"), LONG_PAGE],
  ["16 KiB page URL + links with text", fillTo("<a href=y>t</a>"), LONG_PAGE],
  ["16 KiB page URL + root-relative links", fillTo("<a href=/y>t</a>"), LONG_PAGE],
];
for (const [name, html, page] of LINK_CASES) {
  test(`2 MiB of links against a long base stays under 2 s and the output budget: ${name}`, () => {
    bounded(name, html, page);
  });
}

test("definition lists indent at most 16 levels", () => {
  assert.equal(md(`<p>top</p>${"<dl><dd>".repeat(20)}x`), `top\n\n${" ".repeat(32)}x`);
});

const PATHOLOGICAL: [string, string][] = [
  ["nested dl/dd x120 + br lines", "<dl><dd>".repeat(120) + fillTo("x<br>", MIB2 - 1000)],
  ["nested dl/dt/dd x85 + br lines", "<dl><dt>t<dd>".repeat(85) + fillTo("x<br>", MIB2 - 1200)],
  ["h1/div alternation + text", "<h1><div>".repeat(127) + fillTo("word ", MIB2 - 1300)],
  ["nested ul/li + br lines", "<ul><li>".repeat(255) + fillTo("x<br>", MIB2 - 2100)],
  ["nested blockquote + br lines", "<blockquote>".repeat(255) + fillTo("x<br>", MIB2 - 3100)],
  ["nested ol/li/blockquote + br lines", "<ol><li><blockquote>".repeat(85) + fillTo("x<br>", MIB2 - 1800)],
  ["nested b/i + text", "<b><i>".repeat(127) + fillTo("word ", MIB2 - 900)],
  ["links and divs in a heading + text", "<h2>" + "<a href='/x'><div>".repeat(120) + fillTo("y ", MIB2 - 3000)],
  ["nested tables", fillTo("<table><tr><td>x")],
  ["backticks in pre", "<pre>" + fillTo("`")],
  ["backticks in code", "<code>" + fillTo("`")],
  ["horizontal rules", fillTo("<hr>")],
];
for (const [name, html] of PATHOLOGICAL) {
  test(`2 MiB pathological input stays under 2 s and the output budget: ${name}`, () => {
    bounded(name, html);
  });
}
