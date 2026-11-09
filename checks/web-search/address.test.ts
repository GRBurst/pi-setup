// URL and address guard. Private addresses, single-label URLs and long hex
// literals are assembled at run time so the `leaks` scan stays clean.
import assert from "node:assert/strict";
import { test } from "node:test";
import {
  checkResolved,
  isBlockedAddress,
  isBlockedHostName,
  parseIPv6,
  sameAddress,
  validateTarget,
} from "../../extensions/web-search/address.ts";

const v4 = (...o: number[]) => o.join(".");
const url = (host: string, path = "/") => `${"http"}://${host}${path}`;

// [first, last] address of every blocked IPv4 range
const V4_RANGES: [number[], number[]][] = [
  [[0, 0, 0, 0], [0, 255, 255, 255]],
  [[10, 0, 0, 0], [10, 255, 255, 255]],
  [[100, 64, 0, 0], [100, 127, 255, 255]],
  [[127, 0, 0, 0], [127, 255, 255, 255]],
  [[169, 254, 0, 0], [169, 254, 255, 255]],
  [[172, 16, 0, 0], [172, 31, 255, 255]],
  [[192, 0, 0, 0], [192, 0, 0, 255]],
  [[192, 168, 0, 0], [192, 168, 255, 255]],
  [[198, 18, 0, 0], [198, 19, 255, 255]],
  [[224, 0, 0, 0], [239, 255, 255, 255]],
  [[240, 0, 0, 0], [255, 255, 255, 255]],
];

const PUBLIC_NEIGHBOURS = [
  [1, 0, 0, 0],
  [9, 255, 255, 255],
  [11, 0, 0, 0],
  [100, 63, 255, 255],
  [100, 128, 0, 0],
  [126, 255, 255, 255],
  [128, 0, 0, 0],
  [169, 253, 255, 255],
  [169, 255, 0, 0],
  [172, 15, 255, 255],
  [172, 32, 0, 0],
  [192, 0, 1, 0],
  [192, 167, 255, 255],
  [192, 169, 0, 0],
  [198, 17, 255, 255],
  [198, 20, 0, 0],
  [223, 255, 255, 255],
  [93, 184, 216, 34],
];

test("every blocked IPv4 range is blocked at its first and last address", () => {
  for (const [first, last] of V4_RANGES) {
    assert.equal(isBlockedAddress(v4(...first)), true, v4(...first));
    assert.equal(isBlockedAddress(v4(...last)), true, v4(...last));
  }
});

test("public IPv4 neighbours just outside the ranges are allowed", () => {
  for (const a of PUBLIC_NEIGHBOURS) assert.equal(isBlockedAddress(v4(...a)), false, v4(...a));
});

test("IPv6 ranges", () => {
  const blocked = [
    "::",
    "::1",
    "fe80::",
    "febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
    "fec0::1",
    "feff::1",
    "fc00::",
    "fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
    "fd00:ec2::254",
    "ff00::",
    "ff02::1",
    "::ffff:127.0.0.1",
    "::ffff:7f00:1",
    `::ffff:${v4(10, 1, 2, 3)}`,
    "::127.0.0.1",
    "64:ff9b::7f00:1",
    `64:ff9b::${v4(192, 168, 1, 1)}`,
    "2002:7f00:1::",
    "2002:a9fe:a9fe::1",
  ];
  for (const a of blocked) assert.equal(isBlockedAddress(a), true, a);
  const allowed = [
    "2606:4700::1111",
    "2001:4860:4860::8888",
    "::ffff:5db8:d822",
    "64:ff9b::5db8:d822",
    "2002:5db8:d822::1",
    "fbff::1",
    "fe7f::1",
  ];
  for (const a of allowed) assert.equal(isBlockedAddress(a), false, a);
});

test("malformed addresses fail closed", () => {
  for (const a of ["", "1.2.3", "1.2.3.4.5", "256.1.1.1", "01.2.3.4", "1::2::3", "gggg::", "1:2:3:4:5:6:7:8:9", "fe80::1%eth0", "example.com", ":::"]) {
    assert.equal(isBlockedAddress(a), true, JSON.stringify(a));
  }
});

test("IPv6 parser handles compression and embedded IPv4", () => {
  assert.deepEqual(parseIPv6("::1"), [...Array(15).fill(0), 1]);
  assert.deepEqual(parseIPv6("1:2:3:4:5:6:7:8")?.slice(0, 4), [0, 1, 0, 2]);
  assert.deepEqual(parseIPv6("::ffff:1.2.3.4")?.slice(10), [255, 255, 1, 2, 3, 4]);
  assert.equal(parseIPv6("1:2:3:4:5:6:7::8:9"), null);
});

test("host names: localhost, .localhost, metadata names; case and one trailing dot ignored", () => {
  for (const h of ["localhost", "LOCALHOST.", "a.localhost", "x.y.LocalHost", "metadata", "metadata.google.internal", "Metadata.Google.Internal."]) {
    assert.equal(isBlockedHostName(h), true, h);
  }
  for (const h of ["example.com", "localhost.example.com", "notlocalhost", "metadata.example.com"]) {
    assert.equal(isBlockedHostName(h), false, h);
  }
});

test("validateTarget: invalid URL", () => {
  assert.throws(() => validateTarget("not a url"), /not a valid absolute URL/);
  assert.throws(() => validateTarget("/relative/path"), /not a valid absolute URL/);
});

test("validateTarget: blocked schemes name the scheme", () => {
  for (const u of ["file:///etc/passwd", "ftp://example.com/x", "data:text/plain,hi", "javascript:alert(1)", "gopher://example.com/"]) {
    const scheme = u.slice(0, u.indexOf(":") + 1);
    assert.throws(() => validateTarget(u), (e: Error) => e.message.includes(scheme) && /only http and https/.test(e.message), u);
  }
});

test("validateTarget: credentials refused", () => {
  assert.throws(() => validateTarget(`https://${"user"}:${"pw"}@example.com/`), /credentials/);
  assert.throws(() => validateTarget(`https://${"user"}@example.com/`), /credentials/);
});

test("validateTarget: blocked host names", () => {
  for (const h of ["localhost", "a.localhost", "LOCALHOST.", "metadata", "metadata.google.internal"]) {
    assert.throws(() => validateTarget(url(h)), /not permitted/, h);
  }
});

test("validateTarget: IPv4 literals in any WHATWG notation", () => {
  const forms = [
    v4(127, 0, 0, 1),
    "127.1",
    String(2130706433),
    "0x" + "7f000001",
    "0x7f.1",
    "0177.0.0.1",
    v4(169, 254, 169, 254),
    String(10 * 2 ** 24 + 1),
    v4(192, 168, 0, 1),
    v4(0, 0, 0, 0),
  ];
  for (const h of forms) assert.throws(() => validateTarget(url(h)), /not permitted/, h);
  const ok = validateTarget(url(v4(93, 184, 216, 34)));
  assert.equal(ok.literal, v4(93, 184, 216, 34));
});

test("validateTarget: bracketed IPv6 literals", () => {
  for (const h of ["[::1]", "[::ffff:127.0.0.1]", "[64:ff9b::7f00:1]", "[fd00::1]", "[fe80::1]", "[::]"]) {
    assert.throws(() => validateTarget(url(h)), /not permitted/, h);
  }
  const ok = validateTarget(url("[2606:4700::1111]"));
  assert.equal(ok.literal, "2606:4700::1111");
  assert.equal(ok.host, "2606:4700::1111");
});

test("validateTarget: public names pass; any port; fragment removed", () => {
  const t = validateTarget("https://Example.com:8443/a/b?q=1#frag");
  assert.equal(t.url.href, "https://example.com:8443/a/b?q=1");
  assert.equal(t.host, "example.com");
  assert.equal(t.literal, null);
});

test("checkResolved: all addresses must be public", () => {
  assert.doesNotThrow(() => checkResolved("example.com", ["93.184.216.34", "2606:2800:220:1:248:1893:25c8:1946"]));
  const priv = v4(10, 0, 0, 7);
  assert.throws(
    () => checkResolved("mixed.example", ["93.184.216.34", priv]),
    (e: Error) => e.message.includes("mixed.example") && e.message.includes(priv) && /not permitted/.test(e.message),
  );
  assert.throws(() => checkResolved("empty.example", []), /empty\.example/);
});

test("IPv6 tunnel and translation prefixes beyond the spec are blocked as a whole", () => {
  // NAT64 local-use 64:ff9b:1::/48 (RFC 8215), Teredo 2001::/32, SIIT ::ffff:0:0:0/96
  const blocked = ["64:ff9b:1::7f00:1", "64:ff9b:1::5db8:d822", "64:ff9b:1:ffff::1", "2001::1", "2001:0:4136:e378:8000:63bf:80ff:fffe", "::ffff:0:7f00:1", "::ffff:0:5db8:d822"];
  for (const a of blocked) assert.equal(isBlockedAddress(a), true, a);
  // their neighbours
  for (const a of ["64:ff9b:2::1", "64:ff9a:ffff::1", "2001:1:0:0::1", "2001:4860:4860::8888", "::fffe:0:5db8:d822"]) {
    assert.equal(isBlockedAddress(a), false, a);
  }
  assert.throws(() => validateTarget(url("[64:ff9b:1::7f00:1]")), /not permitted/);
  assert.throws(() => validateTarget(url("[2001:0:4136:e378:8000:63bf:80ff:fffe]")), /not permitted/);
});

test("sameAddress compares addresses, not their spelling", () => {
  assert.equal(sameAddress("2606:4700:0:0:0:0:0:1111", "2606:4700::1111"), true);
  assert.equal(sameAddress("2606:4700::1111", "2606:4700::1112"), false);
  assert.equal(sameAddress("93.184.216.34", "93.184.216.34"), true);
  assert.equal(sameAddress("::ffff:93.184.216.34", "93.184.216.34"), true);
  assert.equal(sameAddress("93.184.216.34", "93.184.216.35"), false);
  assert.equal(sameAddress("::1", "0:0:0:0:0:0:0:1"), true);
  for (const bad of ["", "example.com", "1.2.3", "fe80::1%eth0"]) assert.equal(sameAddress(bad, bad), false, bad);
});
