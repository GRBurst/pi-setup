// Text helpers: character references, whitespace, snippet cap, output cap.
import assert from "node:assert/strict";
import { test } from "node:test";
import {
  capSnippet,
  cleanInline,
  collapseWhitespace,
  decodeEntities,
  truncateOutput,
} from "../../extensions/web-search/text.ts";

test("named references: the basic and typographic set", () => {
  assert.equal(decodeEntities("&amp;&lt;&gt;&quot;&apos;"), "&<>\"'");
  assert.equal(decodeEntities("a&nbsp;b"), "a b");
  assert.equal(
    decodeEntities("&mdash;&ndash;&hellip;&lsquo;&rsquo;&ldquo;&rdquo;&copy;&reg;&trade;"),
    "\u2014\u2013\u2026\u2018\u2019\u201c\u201d\u00a9\u00ae\u2122",
  );
});

test("numeric references: decimal, hex, invalid, windows-1252 range", () => {
  assert.equal(decodeEntities("&#65;&#x42;&#X43;"), "ABC");
  assert.equal(decodeEntities("&#128512;"), "\u{1f600}");
  assert.equal(decodeEntities("&#0;&#xD800;&#x110000;"), "\ufffd\ufffd\ufffd");
  assert.equal(decodeEntities("&#150;"), "\u2013");
  assert.equal(decodeEntities("&#99999999999999999999;"), "\ufffd");
});

test("unknown or unterminated named references stay as written", () => {
  assert.equal(decodeEntities("&bogus; &amp &"), "&bogus; &amp &");
  assert.equal(decodeEntities("a & b"), "a & b");
});

test("whitespace collapse", () => {
  assert.equal(collapseWhitespace("  a \n\t b  "), "a b");
});

test("cleanInline strips tags, decodes, collapses, tolerates non-strings", () => {
  assert.equal(cleanInline("<strong>Nix</strong>  &amp;\n pi"), "Nix & pi");
  assert.equal(cleanInline("&lt;b&gt;"), "<b>");
  assert.equal(cleanInline(undefined), "");
  assert.equal(cleanInline(42), "");
  assert.equal(cleanInline({ a: 1 }), "");
});

test("capSnippet: short unchanged, long cut at a word boundary with an ellipsis", () => {
  assert.equal(capSnippet("short"), "short");
  const long = "word ".repeat(200).trim();
  const capped = capSnippet(long);
  assert.ok(capped.length <= 500, `length ${capped.length}`);
  assert.ok(capped.endsWith("\u2026"));
  assert.ok(capped.slice(0, -1).endsWith("word"));
  const noSpaces = "x".repeat(800);
  assert.equal(capSnippet(noSpaces).length, 500);
});

test("capSnippet never splits a surrogate pair", () => {
  const s = "\u{1f600}".repeat(400);
  const capped = capSnippet(s);
  assert.ok(capped.length <= 500);
  assert.ok(!/[\ud800-\udbff]\u2026$/.test(capped));
});

test("truncateOutput: within limits unchanged", () => {
  const r = truncateOutput("a\nb\n");
  assert.equal(r.text, "a\nb\n");
  assert.equal(r.truncated, false);
});

test("truncateOutput: line limit keeps the head with a note", () => {
  const text = Array.from({ length: 2500 }, (_, i) => `line ${i}`).join("\n");
  const r = truncateOutput(text);
  assert.equal(r.truncated, true);
  const lines = r.text.split("\n");
  assert.equal(lines[0], "line 0");
  assert.equal(lines[1999], "line 1999");
  assert.match(lines[lines.length - 1], /truncated/i);
  assert.match(lines[lines.length - 1], /2000 of 2500 lines/);
  assert.match(lines[lines.length - 1], /omitted/);
});

test("truncateOutput: byte limit cuts at a line boundary", () => {
  const line = "y".repeat(99);
  const text = Array.from({ length: 1000 }, () => line).join("\n"); // 100 000 bytes
  const r = truncateOutput(text);
  assert.equal(r.truncated, true);
  const body = r.text.slice(0, r.text.lastIndexOf("\n\n"));
  assert.ok(Buffer.byteLength(body) <= 50 * 1024);
  for (const l of body.split("\n")) assert.equal(l, line);
  assert.match(r.text, /50\.0 ?KB of 97\.7 ?KB/);
});

test("truncateOutput: a single huge line is cut at a character boundary", () => {
  const text = "\u00e9".repeat(60 * 1024); // 2 bytes each
  const r = truncateOutput(text);
  assert.equal(r.truncated, true);
  const body = r.text.slice(0, r.text.lastIndexOf("\n\n"));
  assert.ok(body.length > 0);
  assert.ok(Buffer.byteLength(body) <= 50 * 1024);
  assert.ok(!body.includes("\ufffd"));
});
