// Replaces pi's animated working indicator with a single static glyph.
//
// Why: in fullscreen mode pi's renderer walks the whole component tree and
// diffs the whole viewport on every frame, so an 80 ms spinner repaints the
// entire transcript ~12 times a second while nothing else changes. Cost grows
// with transcript length -- upstream measured ~1.5% of a core at 500 lines and
// ~7.6% at 20 000 (https://github.com/earendil-works/pi/issues/3881, still open
// as of pi 0.87.1); measured here, 10% of a core on a *short* session that was
// merely waiting for a bash command. The message text ("Working...") already
// states progress, so the animation buys nothing.
//
// Mechanism: pi-tui's Loader only arms its setInterval when it has more than
// one frame (`restartAnimation`: `if (this.frames.length <= 1) return;`), so a
// one-frame indicator removes the timer entirely rather than slowing it down.
// `setWorkingIndicator` is the supported extension API for that
// (ExtensionUIContext.setWorkingIndicator), which is why this is an extension
// and not a patch against pi's shipped JS.
//
// Colour: custom frames are rendered verbatim, so the default colouring is
// lost and has to be reproduced. pi colours the border-embedded working
// indicator with the thinking-level border colour
// (interactive-mode.js `showWorkingStatusIndicator`), so mirror that. Applying
// on every agent_start re-resolves both the thinking level and the active
// theme, which matters here because darkman flips light/dark at runtime.
//
// Scope: only the *working* indicator. The retry and compaction indicators
// keep animating; they are rare and short-lived, and no public API configures
// them.
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const GLYPH = "●";

function applyStaticIndicator(ctx: ExtensionContext): void {
  // Non-TUI runs (rpc/json/print) have no indicator; the call is a no-op there,
  // but skipping it keeps headless children free of pointless UI calls.
  if (ctx.mode !== "tui") return;

  const colorize = ctx.ui.theme.getThinkingBorderColor(ctx.thinkingLevel ?? "off");
  ctx.ui.setWorkingIndicator({ frames: [colorize(GLYPH)] });
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", async (_event, ctx) => {
    applyStaticIndicator(ctx);
  });

  pi.on("agent_start", async (_event, ctx) => {
    applyStaticIndicator(ctx);
  });
}
