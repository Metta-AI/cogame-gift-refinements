#!/usr/bin/env python3
"""Derive client/replay_broadcast.html from the coworld-ctf starter page.

Run at fork time and kept in-tree as the record of exactly what was cut, so a
reviewer diffs the DERIVATION rather than a 4 600-line result:

    python3 scripts/derive_broadcast_page.py <coworld-ctf checkout> \
        client/replay_broadcast.html

The page is the starter's, edited only where the design note
(docs/plans/2026-08-25-gift-refinements-design.md, "## Viewer" ->
"Chrome provenance (exact)") says it must be:

  1. REMOVED elements, with their CSS blocks and the JS branches that touch
     them: #viewpanel (+ #minimap, #minimap-canvas, #zoombar, #zoom-out,
     #zoom-slider, #zoom-in, #zoom-read), #fpv (+ every #fpv-* child),
     #povBadge, #mmwarn. The 24x14 board is fixed and always fits the frame, so
     there is nothing to pan to and nothing a minimap could add; the replay
     records STATE, so there is no hash to mismatch; and nothing is fogged, so
     there is no POV lens.
  2. RE-LETTERED literals: the scorebug's `Lives` label -> `Tokens`, the
     momentum strip's `LIVES LEAD` -> `TOKENS IN PLAY`, the page title, and the
     locker-room caption.
  3. #lockerroom gains `pointer-events: none` so its ~1.5 s curtain stops
     swallowing transport clicks (ecos, 2026-08-23).
  4. The appended game block's hook is renamed (PaintballChrome ->
     GiftRefinementsChrome, PB_CTX -> GR_CTX) and the PB_MODE latch is deleted
     together with its plate/endcard content branches: Gift Refinements uses the
     CLASSIC plate and endcard shapes, so the two hooks (frame, event) are
     called unconditionally instead of behind a mode flag.

Everything else -- #stage, #board, #chrome, #scorebug, #plates-l/r, #clock,
#clock-time, #clock-caption, #bannerlane, #killfeed, #transport and all its
buttons plus #btn-spoilers, #scrub, #momentum, #scrub-fill, #lulls, #scrub-win,
#scrub-head, #endcard, #status -- is the starter's, unchanged. The appended
GIFT-REFINEMENTS block (client/game_block.html) is spliced in before </body>.
"""

from __future__ import annotations

import sys

# (first, last) INCLUSIVE 1-based line ranges in the starter page. Both ends are
# re-verified against their expected text before anything is cut, so an upstream
# edit fails loudly instead of silently removing the wrong lines.
CUTS = [
    # ---- CSS ------------------------------------------------------------
    (528, 833,
     "/* POV eye badge shown when a slot is inspected (fog-honesty lens) */", ""),
    (1017, 1034,
     "/* hash-mismatch warning (top center) \u2014 honest fidelity flag */", ""),
    # ---- CSS: the ?viewpanel=0 opt-out for a panel that no longer exists --
    (1452, 1459,
     "/* Opt-OUT of the #viewpanel overlay (zoom bar + minimap) by param only:",
     "body[data-noviewpanel] #viewpanel { display: none !important; }"),
    # ---- markup: #viewpanel, #mmwarn, #povBadge, #fpv --------------------
    (1506, 1549,
     "    <!-- View controls: zoom the board with buttons/slider/keys/pinch (never a",
     "    </div>"),
    # ---- JS: the eye-level cog art the PiP billboards blitted -----------
    (1641, 1658, "  // ---- eye-level cog art for the EYES PiP billboards ----", "  //"),
    (1676, 1701, "  var COG_ART = {}, COG_ART_GUN = {};",
     "  var cogScratch = document.createElement('canvas'), cogScratchCtx = null;"),
    # ---- JS: the ?viewpanel=0 opt-out ------------------------------------
    (1876, 1884,
     "  // ?viewpanel=0 hides the #viewpanel overlay (zoom bar + minimap). This is an",
     "  } catch (e) {}"),
    # ---- JS: the first-person tactical minimap ingest --------------------
    (2083, 2116,
     "  // The server ships the static minimap wall silhouette ONCE (RLE of a coarse",
     ""),
    # ---- JS: ensureScorebug's paintball plate contents -------------------
    (2213, 2234, "      if (PB_MODE) {", "      }"),
    # ---- JS: renderScorebug's paintball plate numerals -------------------
    (2263, 2294, "      if (PB_MODE) {", "      }"),
    # ---- JS: the POV badge, the whole first-person PiP, the mismatch flag -
    (2347, 3470, "  // ---------- pov + mismatch ----------", ""),
    # ---- JS: renderEndcardRows' paintball stat row -----------------------
    (3726, 3741, "      if (PB_MODE) {", "      }"),
    # ---- JS: ensureEndcardTeams' paintball stat header (the `?` arm) ------
    (3783, 3789, None,
     "          '<div id=\"ec-rows-' + team + '\"></div>'"),
    # ---- JS: renderEndcard's paintball verdict ---------------------------
    (3841, 3879, "    if (PB_MODE) {", ""),
    # ---- JS: the POV-clear click target ----------------------------------
    (3954, 3956,
     "  // pov clear (togglePov lives in the shared chrome, driven via ctx.sendPov)",
     ""),
    # ---- JS: the z/x/0 + arrow view keys ---------------------------------
    (3971, 3989,
     "    // Board zoom rides z/x/0: +/- and 1..9 are already the server's speed",
     "    }"),
    # ---- JS: click-to-select, pinch/drag zoom, the slider and the minimap -
    (3996, 4269,
     "  // Click a soldier on the board to select it (mirrors the squad-pip lens, but",
     ""),
    # ---- the starter's OWN appended game block (replaced by ours) --------
    (4343, 4658, "<!-- ============================================================", ""),
]

# Whole-line replacements keyed on the starter's exact line text. An empty
# replacement deletes the line.
LINES = {
    "<title>Ctf \u2014 Broadcast Replay</title>":
        "<title>Gift Refinements \u2014 Broadcast Replay</title>",
    '    <div class="lk-cap" id="lk-cap" aria-hidden="true">Filling hoppers with fresh paint&hellip;</div>':
        '    <div class="lk-cap" id="lk-cap" aria-hidden="true">Warming the seep pads&hellip;</div>',
    '        <span class="momentum-label">LIVES LEAD</span>':
        '        <span class="momentum-label">TOKENS IN PLAY</span>',
    "        '<span class=\"lives-label\">Lives</span>' +":
        "        '<span class=\"lives-label\">Tokens</span>' +",
    "#lockerroom {": "#lockerroom {\n  pointer-events: none;",
    "  // PAINTBALL mode: latched on the first frame that carries a squad-game":
        "  // The appended GIFT-REFINEMENTS block reads the classic chrome through",
    "  // field (`regime` only rides squad frames). Classic frames never set it.":
        "  // GR_CTX. There is only one plate/endcard shape here, so no mode flag.",
    "  var PB_MODE = false;": "",
    "    if (!PB_MODE && s.regime !== undefined) PB_MODE = true;": "",
    "  var PB_CTX = null;             // filled at the end of this IIFE (hoisted)":
        "  var GR_CTX = null;             // filled at the end of this IIFE (hoisted)",
    "    // PAINTBALL additions run last, over the classic chrome's own render.":
        "    // GIFT-REFINEMENTS additions run last, over the classic chrome's render.",
    "    if (PB_MODE && window.PaintballChrome) window.PaintballChrome.frame(s, PB_CTX, jumped);":
        "    if (window.GiftRefinementsChrome)\n"
        "      window.GiftRefinementsChrome.frame(s, GR_CTX, jumped);",
    "    // PAINTBALL: every beat goes through the appended game block, which draws":
        "    // Every beat goes through the appended game block, which draws",
    "    if (PB_MODE && window.PaintballChrome &&":
        "    if (window.GiftRefinementsChrome &&",
    "        window.PaintballChrome.event(e, s, PB_CTX)) {":
        "        window.GiftRefinementsChrome.event(e, s, GR_CTX)) {",
    "    var key = teams.join(',') + (PB_MODE ? '|pb' : '');":
        "    var key = teams.join(',');",
    "  PB_CTX = {": "  GR_CTX = {",
    "  if (window.PaintballChrome) window.PaintballChrome.install(PB_CTX);":
        "  if (window.GiftRefinementsChrome) window.GiftRefinementsChrome.install(GR_CTX);",
    "      $('ec-' + team).textContent = PB_MODE":
        "      $('ec-' + team).textContent =",
    "        ? fmt(team === 'red' ? (o.hillRed || 0) : (o.hillBlue || 0))": "",
    "        : overLives(o, team);": "        overLives(o, team);",
    "      el.innerHTML = PB_MODE": "      el.innerHTML =",
    "        : '<div class=\"ec-tname ' + team + '\" id=\"ec-tname-' + team + '\">' + team.toUpperCase() + '</div>' +":
        "        '<div class=\"ec-tname ' + team + '\" id=\"ec-tname-' + team + '\">' + team.toUpperCase() + '</div>' +",
    # onFrame call sites for the removed surfaces.
    "    renderPov(s);": "",
    "    renderMismatch(s);": "",
    "    ingestFpMap(s);": "",
    # The core's view callbacks drove the (now removed) zoom slider + minimap.
    "    onFirstFrame: function () { core.setViewportFit(); syncViewUi(); },":
        "    onFirstFrame: function () { core.setViewportFit(); },",
    "    onTransform: function (t) { syncViewUi(t); }":
        "    onTransform: function () {}",
    # (…and the comment above them, which described the slider.)
    "    // The core owns the view, so it tells the controls where it ended up \u2014":
        "    // The board is fixed and always fitted, so there is no view to sync:",
    "    // never the other way round. That keeps the slider honest when the zoom":
        "    // the callback stays wired (broadcast_core calls it) and does nothing.",
    "    // moved for some other reason (a pinch, an arrow key, a refit, a new board).":
        "",
}


def main() -> None:
    starter, out_path = sys.argv[1], sys.argv[2]
    lines = open(f"{starter}/client/replay_broadcast.html",
                 encoding="utf-8").read().split("\n")

    def check(index: int, expect: str | None) -> None:
        if expect and lines[index - 1] != expect:
            raise SystemExit(
                f"line {index} is not what the derivation expects:\n"
                f"  want: {expect!r}\n  have: {lines[index - 1]!r}")

    drop: set[int] = set()
    for first, last, head, tail in CUTS:
        check(first, head)
        check(last, tail)
        drop.update(range(first, last + 1))

    replaced = {key: 0 for key in LINES}
    out: list[str] = []
    for number, line in enumerate(lines, 1):
        if number in drop:
            continue
        if line in LINES:
            replaced[line] += 1
            if LINES[line]:
                out.append(LINES[line])
            continue
        out.append(line)

    page = "\n".join(out)
    block = open("client/game_block.html", encoding="utf-8").read().rstrip("\n")
    marker = "\n</body>\n</html>"
    if marker not in page:
        raise SystemExit("the derived page has no </body> to splice the game block into")
    page = page.replace(marker, "\n" + block + marker)
    open(out_path, "w", encoding="utf-8").write(page)

    print(f"wrote {out_path}: {len(page.splitlines())} lines "
          f"(cut {len(drop)} from the starter's {len(lines)})")
    for key, count in replaced.items():
        if count == 0:
            print(f"  ERROR: replacement never matched: {key[:78]!r}")
            raise SystemExit(1)


if __name__ == "__main__":
    main()
