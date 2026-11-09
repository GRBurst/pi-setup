// web_search and web_fetch for pi and its child agents.
//
// web_search asks exactly one backend, chosen once at load from the
// environment (PI_SEARX_URL, then TAVILY_API_KEY, then BRAVE_API_KEY): a
// self-hosted SearXNG keeps queries on that instance, Tavily and Brave are
// third parties. Unconfigured, it sends nothing and returns setup
// instructions. There is no fallback from one backend to another.
//
// web_fetch downloads one public page and converts it to markdown locally;
// no reader service sees the URL. It refuses non-http(s) URLs and local,
// private and internal addresses at every redirect hop and pins the
// connection to the checked address.
//
// This file is the only one that imports pi or typebox; the modules next to
// it are plain Node, so the `web-search` check runs them without pi. No UI
// calls and nothing started at load: all I/O happens inside `execute`, so
// the extension works in print, json and rpc modes and in children.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { searchDescription, selectBackend } from "./config.ts";
import { webFetch } from "./fetch.ts";
import { runSearch } from "./search.ts";

const ANNOTATIONS = { readOnlyHint: true, destructiveHint: false, openWorldHint: true };

export default function (pi: ExtensionAPI) {
  const backend = selectBackend(process.env);

  pi.registerTool({
    name: "web_search",
    label: "Web Search",
    description: searchDescription(backend),
    promptSnippet: "Search the web for current or external information (web_search), then read a page with web_fetch",
    promptGuidelines: [
      "Use web_search for current or external facts you do not know; then call web_fetch on a result URL to read the page itself instead of relying on the snippet.",
    ],
    parameters: Type.Object({
      query: Type.String({ description: "Search query" }),
      count: Type.Optional(Type.Integer({ minimum: 1, maximum: 10, description: "Number of results (1-10, default 5)" })),
    }),
    annotations: ANNOTATIONS,
    async execute(_toolCallId, params, signal) {
      const r = await runSearch(backend, params, { signal });
      return { content: [{ type: "text", text: r.text }], details: r.details };
    },
  });

  pi.registerTool({
    name: "web_fetch",
    label: "Web Fetch",
    description:
      "Fetch one web page and return its main content as markdown, converted locally (no third-party reader). " +
      "Only absolute http(s) URLs; local, private and internal addresses are refused. " +
      "Output is limited to 50KB / 2000 lines; HTML, text, XML and JSON only.",
    parameters: Type.Object({
      url: Type.String({ description: "Absolute http:// or https:// URL" }),
    }),
    annotations: ANNOTATIONS,
    async execute(_toolCallId, params, signal) {
      const r = await webFetch(params.url, { signal });
      return { content: [{ type: "text", text: r.text }], details: r.details };
    },
  });
}
