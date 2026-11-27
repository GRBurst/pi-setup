// Two roles in one file, both for the pi-request-abort check.
//
// As a pi extension (`pi -e probe.mjs`): a provider hook that holds the request. Unless
// PROBE_MODE=control, it stops the turn with `ctx.abort()` while it holds the request, waits up to
// 2 s for `ctx.signal` to abort, records what it saw in $PROBE_OUT and returns the payload unchanged.
// PROBE_PLANT=1 skips the `ctx.abort()` (the planted violation the abort run must catch).
//
// As a program (`node probe.mjs serve <port file>`): a fake provider on localhost that answers
// openai-completions and anthropic-messages with one streamed "ok" and records every request it
// receives in $SERVER_OUT.
import { appendFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";

const record = (file, line) => appendFileSync(file, `${JSON.stringify(line)}\n`);

const abortedWithin = (signal, ms) =>
  new Promise((resolve) => {
    if (!signal) return resolve(false);
    if (signal.aborted) return resolve(true);
    const timer = setTimeout(() => resolve(false), ms);
    signal.addEventListener(
      "abort",
      () => {
        clearTimeout(timer);
        resolve(true);
      },
      { once: true },
    );
  });

export default function probe(pi) {
  pi.on("before_provider_request", async (event, ctx) => {
    const out = process.env.PROBE_OUT;
    record(out, { started: true });
    if (process.env.PROBE_MODE === "control") return event.payload;
    if (process.env.PROBE_PLANT !== "1") ctx.abort();
    await abortedWithin(ctx.signal, 2000);
    record(out, { aborted: ctx.signal?.aborted === true });
    return event.payload;
  });
}

const sse = (res, events) => {
  res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache" });
  for (const [name, data] of events) {
    if (name) res.write(`event: ${name}\n`);
    res.write(`data: ${typeof data === "string" ? data : JSON.stringify(data)}\n\n`);
  }
  res.end();
};

const openaiStream = [
  [null, { id: "c", object: "chat.completion.chunk", created: 0, model: "m", choices: [{ index: 0, delta: { role: "assistant", content: "ok" }, finish_reason: null }] }],
  [null, { id: "c", object: "chat.completion.chunk", created: 0, model: "m", choices: [{ index: 0, delta: {}, finish_reason: "stop" }], usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } }],
  [null, "[DONE]"],
];

const anthropicStream = [
  ["message_start", { type: "message_start", message: { id: "m", type: "message", role: "assistant", model: "m", content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 1, output_tokens: 0 } } }],
  ["content_block_start", { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }],
  ["content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "ok" } }],
  ["content_block_stop", { type: "content_block_stop", index: 0 }],
  ["message_delta", { type: "message_delta", delta: { stop_reason: "end_turn", stop_sequence: null }, usage: { output_tokens: 1 } }],
  ["message_stop", { type: "message_stop" }],
];

const serve = (portFile) => {
  const server = createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => {
      body += chunk;
    });
    req.on("end", () => {
      record(process.env.SERVER_OUT, { method: req.method, url: req.url, bytes: body.length });
      sse(res, req.url.includes("/messages") ? anthropicStream : openaiStream);
    });
  });
  server.listen(0, "localhost", () => writeFileSync(portFile, String(server.address().port)));
};

if (process.argv[2] === "serve") serve(process.argv[3]);
