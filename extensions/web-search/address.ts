// The SSRF guard of web_fetch: URL validation and the blocked address
// ranges. Ranges are written as octet lists, not dotted literals.

type Range = [bytes: number[], prefix: number];

// IPv4: this network, private (RFC 1918), shared CGNAT, loopback,
// link-local (incl. the cloud metadata address), IETF protocol
// assignments, benchmarking, multicast, reserved and broadcast.
const V4_BLOCKED: Range[] = [
  [[0, 0, 0, 0], 8],
  [[10, 0, 0, 0], 8],
  [[100, 64, 0, 0], 10],
  [[127, 0, 0, 0], 8],
  [[169, 254, 0, 0], 16],
  [[172, 16, 0, 0], 12],
  [[192, 0, 0, 0], 24],
  [[192, 168, 0, 0], 16],
  [[198, 18, 0, 0], 15],
  [[224, 0, 0, 0], 4],
  [[240, 0, 0, 0], 4],
];

// IPv6: link-local, old site-local, unique local (incl. the AWS metadata
// address), multicast; and, as a whole, prefixes that tunnel or translate to
// IPv4 where the IPv4 address cannot be told reliably: NAT64 local-use
// 64:ff9b:1::/48, Teredo 2001::/32, SIIT IPv4-translated ::ffff:0:0:0/96.
// The unspecified and loopback addresses fall under the IPv4-compatible
// prefix handled in blockedV6.
const V6_BLOCKED: Range[] = [
  [[0xfe, 0x80], 10],
  [[0xfe, 0xc0], 10],
  [[0xfc, 0x00], 7],
  [[0xff, 0x00], 8],
  [[0x00, 0x64, 0xff, 0x9b, 0x00, 0x01], 48],
  [[0x20, 0x01, 0x00, 0x00], 32],
  [[0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0, 0], 96],
];

function inRange(bytes: number[], [base, prefix]: Range): boolean {
  for (let bit = 0; bit < prefix; bit += 8) {
    const width = Math.min(8, prefix - bit);
    const mask = (0xff << (8 - width)) & 0xff;
    const i = bit / 8;
    if ((bytes[i] & mask) !== ((base[i] ?? 0) & mask)) return false;
  }
  return true;
}

/** Strict dotted-quad IPv4 (no leading zeros); null if not one. */
export function parseIPv4(s: string): number[] | null {
  const parts = s.split(".");
  if (parts.length !== 4) return null;
  const out: number[] = [];
  for (const p of parts) {
    if (!/^(0|[1-9][0-9]{0,2})$/.test(p)) return null;
    const n = Number(p);
    if (n > 255) return null;
    out.push(n);
  }
  return out;
}

function parseGroups(s: string): number[] | null {
  if (s === "") return [];
  const out: number[] = [];
  for (const g of s.split(":")) {
    if (!/^[0-9a-fA-F]{1,4}$/.test(g)) return null;
    out.push(Number.parseInt(g, 16));
  }
  return out;
}

/** IPv6 (with `::` compression and a trailing dotted IPv4) as 16 bytes;
 * null if not one. Zone ids are rejected. */
export function parseIPv6(s: string): number[] | null {
  if (s.length > 45 || s.includes("%")) return null;
  let text = s;
  const embedded: number[] = [];
  if (text.includes(".")) {
    const at = text.lastIndexOf(":");
    const v4 = at < 0 ? null : parseIPv4(text.slice(at + 1));
    if (!v4) return null;
    embedded.push((v4[0] << 8) | v4[1], (v4[2] << 8) | v4[3]);
    text = text.slice(0, at + 1);
    if (!text.endsWith("::")) text = text.slice(0, -1);
  }
  const halves = text.split("::");
  if (halves.length > 2) return null;
  const head = parseGroups(halves[0]);
  if (!head) return null;
  let groups: number[];
  if (halves.length === 1) {
    groups = [...head, ...embedded];
    if (groups.length !== 8) return null;
  } else {
    const rest = parseGroups(halves[1]);
    if (!rest) return null;
    const given = head.length + rest.length + embedded.length;
    if (given > 7) return null;
    groups = [...head, ...Array<number>(8 - given).fill(0), ...rest, ...embedded];
  }
  return groups.flatMap((g) => [g >> 8, g & 0xff]);
}

function blockedV4(b: number[]): boolean {
  return V4_BLOCKED.some((r) => inRange(b, r));
}

function blockedV6(b: number[]): boolean {
  const zero = (from: number, to: number) => b.slice(from, to).every((x) => x === 0);
  // IPv4-mapped ::ffff:0:0/96 and IPv4-compatible ::/96 (incl. :: and ::1)
  if (zero(0, 10) && ((b[10] === 0xff && b[11] === 0xff) || (b[10] === 0 && b[11] === 0))) {
    return zero(0, 16) || (zero(0, 15) && b[15] === 1) || blockedV4(b.slice(12));
  }
  // NAT64 64:ff9b::/96
  if (b[0] === 0 && b[1] === 0x64 && b[2] === 0xff && b[3] === 0x9b && zero(4, 12)) return blockedV4(b.slice(12));
  // 6to4 2002::/16
  if (b[0] === 0x20 && b[1] === 0x02) return blockedV4(b.slice(2, 6));
  return V6_BLOCKED.some((r) => inRange(b, r));
}

/** True for addresses web_fetch must not reach; anything that is not a
 * well-formed IPv4/IPv6 address counts as blocked (fail closed). */
export function isBlockedAddress(addr: string): boolean {
  const a4 = parseIPv4(addr);
  if (a4) return blockedV4(a4);
  const a6 = parseIPv6(addr);
  return a6 ? blockedV6(a6) : true;
}

/** The bytes of an address (IPv4-mapped IPv6 as its IPv4 address); null if malformed. */
function addressBytes(a: string): number[] | null {
  const b4 = parseIPv4(a);
  if (b4) return b4;
  const b6 = parseIPv6(a);
  if (!b6) return null;
  return b6.slice(0, 10).every((x) => x === 0) && b6[10] === 0xff && b6[11] === 0xff ? b6.slice(12) : b6;
}

/** True when `a` and `b` are the same IP address, however each is written;
 * false if either is malformed. */
export function sameAddress(a: string, b: string): boolean {
  const x = addressBytes(a);
  const y = addressBytes(b);
  return x !== null && y !== null && x.length === y.length && x.every((v, i) => v === y[i]);
}

/** localhost, *.localhost and the well-known metadata names. */
export function isBlockedHostName(host: string): boolean {
  let h = host.toLowerCase();
  if (h.endsWith(".")) h = h.slice(0, -1);
  return h === "localhost" || h.endsWith(".localhost") || h === "metadata" || h === "metadata.google.internal";
}

const NOT_PERMITTED = "local, private and internal targets are not permitted";

export interface Target {
  /** The URL to request, fragment removed. */
  url: URL;
  /** The host name, or the IP literal without brackets. */
  host: string;
  /** The IP literal when the host is one, else null. */
  literal: string | null;
}

/** Validates a web_fetch target before any network I/O (scheme,
 * credentials, host name, IP literal). Throws with the specific cause. */
export function validateTarget(raw: string): Target {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new Error(`"${raw}" is not a valid absolute URL.`);
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new Error(`The scheme "${url.protocol}" is not allowed; only http and https URLs are allowed.`);
  }
  if (url.username !== "" || url.password !== "") {
    throw new Error("URLs with credentials (user:password@) are refused.");
  }
  url.hash = "";
  let host = url.hostname;
  let literal: string | null = null;
  if (host.startsWith("[") && host.endsWith("]")) {
    host = host.slice(1, -1);
    literal = host;
  } else if (parseIPv4(host)) {
    literal = host;
  }
  if (literal === null && isBlockedHostName(host)) {
    throw new Error(`Blocked host "${host}": ${NOT_PERMITTED}.`);
  }
  if (literal !== null && isBlockedAddress(literal)) {
    throw new Error(`Blocked address ${literal}: ${NOT_PERMITTED}.`);
  }
  return { url, host, literal };
}

/** Checks every resolved address of `host`; throws naming the host and the
 * first blocked address, or the host when there is none. */
export function checkResolved(host: string, addresses: string[]): void {
  if (addresses.length === 0) throw new Error(`DNS lookup of "${host}" returned no addresses.`);
  const bad = addresses.find(isBlockedAddress);
  if (bad !== undefined) {
    throw new Error(`Blocked host "${host}": it resolves to ${bad}; ${NOT_PERMITTED}.`);
  }
}
