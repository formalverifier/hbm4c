"""
wavelib -- render a WaveDrom-subset timing diagram to SVG, and emit the WaveDrom
JSON source next to it.

The JSON is the canonical, editable source: paste it into wavedrom.com, the
WaveDrom VS Code extension, or run it through wavedrom-cli. The SVG is committed
so the documentation reads with no toolchain installed at all.

Supported subset (everything the HBM4 controller docs need):
  wave chars   p n  clock
               0 1  levels          x  unknown/hatched      z  high-Z
               =    data (neutral)  2..5 data (coloured)
               .    extend previous cycle
               |    gap / time break
  per-signal   name, wave, data[], node
  structure    nested groups  ["label", {...}, {...}]
  top level    head/foot {text, tick}, config {hscale}
  edges        ["a<->b label", ...] using node markers
"""

import json
import os

PERIOD = 44          # px per cycle at hscale = 1
LBL_W = 178          # left label column
ROW_H = 26           # signal amplitude
ROW_GAP = 16
HEAD_H = 46
FOOT_H = 34
GRP_INDENT = 12

# Data-segment colours, deliberately the same palette as the block diagrams.
DCOL = {"=": ("#ffffff", "#7a869a"),
        "2": ("#dae8fc", "#6c8ebf"),
        "3": ("#d5e8d4", "#82b366"),
        "4": ("#ffe6cc", "#d79b00"),
        "5": ("#e1d5e7", "#9673a6"),
        "6": ("#f8cecc", "#b85450")}
SIG = "#2b3a4a"
GRID = "#e3e8ee"
TXT = "#16202c"
DIM = "#6b7a8a"
FONT = "Helvetica,Arial,sans-serif"
MONO = "SFMono-Regular,Menlo,Consolas,monospace"


def _esc(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;").replace('"', "&quot;"))


def _segments(wave, data):
    """-> (segments, gaps).  segment = [start, end, char, datastring]"""
    segs, gaps, cur, di = [], [], None, 0
    for i, ch in enumerate(wave):
        if ch == ".":
            if cur:
                cur[1] = i + 1
            continue
        if ch == "|":
            gaps.append(i)
            if cur:
                cur[1] = i + 1
            continue
        d = None
        if ch in "=23456789":
            d = data[di] if di < len(data) else ""
            di += 1
        cur = [i, i + 1, ch, d]
        segs.append(cur)
    return segs, gaps


class Wave:
    def __init__(self, name, title=None, subtitle=None, hscale=1.0, tick=0):
        self.name, self.title, self.subtitle = name, title, subtitle
        self.hscale, self.tick = hscale, tick
        self.rows = []      # (depth, kind, payload)  kind in sig/group/spacer
        self.edges = []
        self.notes = []

    def sig(self, name, wave, data=None, node=None, depth=0, mono=True):
        self.rows.append((depth, "sig",
                          dict(name=name, wave=wave, data=data or [],
                               node=node, mono=mono)))

    def group(self, label, depth=0):
        self.rows.append((depth, "group", dict(name=label)))

    def spacer(self, depth=0):
        self.rows.append((depth, "spacer", dict()))

    def edge(self, spec):
        """WaveDrom-style: 'a<->b  label'"""
        self.edges.append(spec)

    def note(self, cycle, text, color=None):
        self.notes.append((cycle, text, color or DIM))

    # ------------------------------------------------------------------ render
    def _ncycles(self):
        return max((len(r[2]["wave"]) for r in self.rows if r[1] == "sig"),
                   default=1)

    def _geom(self):
        p = PERIOD * self.hscale
        n = self._ncycles()
        w = LBL_W + n * p + 30
        y, ys = HEAD_H, {}
        for idx, (depth, kind, pl) in enumerate(self.rows):
            if kind == "spacer":
                y += 12
                continue
            if kind == "group":
                y += 8
                ys[idx] = y
                y += 20
                continue
            ys[idx] = y
            y += ROW_H + ROW_GAP
        return p, n, w, y + FOOT_H, ys

    def to_json(self):
        sigs = []
        stack = [(0, sigs)]
        for depth, kind, pl in self.rows:
            while stack and stack[-1][0] > depth:
                stack.pop()
            tgt = stack[-1][1]
            if kind == "group":
                g = [pl["name"]]
                tgt.append(g)
                stack.append((depth + 1, g))
            elif kind == "spacer":
                tgt.append({})
            else:
                d = {"name": pl["name"], "wave": pl["wave"]}
                if pl["data"]:
                    d["data"] = pl["data"]
                if pl["node"]:
                    d["node"] = pl["node"]
                tgt.append(d)
        out = {"signal": sigs, "config": {"hscale": self.hscale}}
        if self.edges:
            out["edge"] = self.edges
        if self.title:
            out["head"] = {"text": self.title, "tick": self.tick}
        if self.subtitle:
            out["foot"] = {"text": self.subtitle}
        return out

    def _draw_sig(self, o, pl, y, p, n):
        top, bot, mid = y, y + ROW_H, y + ROW_H / 2.0
        segs, gaps = _segments(pl["wave"], pl["data"])
        lvl = {}
        for si, (a, b, ch, d) in enumerate(segs):
            x0, x1 = LBL_W + a * p, LBL_W + b * p
            if ch in "pnPN":
                for c in range(a, b):
                    cx = LBL_W + c * p
                    if ch in "pP":
                        o.append('<path d="M %g %g L %g %g L %g %g L %g %g L %g %g" '
                                 'fill="none" stroke="%s" stroke-width="1.6"/>'
                                 % (cx, bot, cx, top, cx + p / 2, top,
                                    cx + p / 2, bot, cx + p, bot, SIG))
                    else:
                        o.append('<path d="M %g %g L %g %g L %g %g L %g %g L %g %g" '
                                 'fill="none" stroke="%s" stroke-width="1.6"/>'
                                 % (cx, top, cx, bot, cx + p / 2, bot,
                                    cx + p / 2, top, cx + p, top, SIG))
                lvl[si] = None
            elif ch in "01":
                yy = top if ch == "1" else bot
                o.append('<path d="M %g %g L %g %g" fill="none" stroke="%s" '
                         'stroke-width="1.8"/>' % (x0, yy, x1, yy, SIG))
                lvl[si] = yy
            elif ch == "z":
                o.append('<path d="M %g %g L %g %g" fill="none" stroke="%s" '
                         'stroke-width="1.8"/>' % (x0, mid, x1, mid, SIG))
                lvl[si] = mid
            elif ch == "x":
                o.append('<rect x="%g" y="%g" width="%g" height="%g" fill="url(#hatch)" '
                         'stroke="%s" stroke-width="1.4"/>'
                         % (x0, top, x1 - x0, ROW_H, SIG))
                lvl[si] = None
            else:  # data
                fill, stroke = DCOL.get(ch, DCOL["="])
                s = 5.0
                o.append('<path d="M %g %g L %g %g L %g %g L %g %g L %g %g L %g %g Z" '
                         'fill="%s" stroke="%s" stroke-width="1.5"/>'
                         % (x0 + s, top, x1 - s, top, x1, mid, x1 - s, bot,
                            x0 + s, bot, x0, mid, fill, stroke))
                if d:
                    o.append('<text x="%g" y="%g" font-family="%s" font-size="11" '
                             'fill="%s" text-anchor="middle">%s</text>'
                             % ((x0 + x1) / 2.0, mid + 4, MONO, TXT, _esc(d)))
                lvl[si] = None
        # transitions between adjacent binary levels
        for si in range(1, len(segs)):
            a, b = lvl.get(si - 1), lvl.get(si)
            if a is not None and b is not None and abs(a - b) > 1:
                xb = LBL_W + segs[si][0] * p
                o.append('<path d="M %g %g L %g %g" fill="none" stroke="%s" '
                         'stroke-width="1.8"/>' % (xb - 3, a, xb + 3, b, SIG))
        for g in gaps:
            gx = LBL_W + (g + 0.5) * p
            o.append('<path d="M %g %g q 7 %g 0 %g q -7 %g 0 %g" fill="none" '
                     'stroke="#b85450" stroke-width="1.8"/>'
                     % (gx - 4, bot + 3, -(ROW_H + 6) / 2.0, -(ROW_H + 6) / 2.0,
                        -(ROW_H + 6) / 2.0, -(ROW_H + 6) / 2.0))
            o.append('<path d="M %g %g q 7 %g 0 %g q -7 %g 0 %g" fill="none" '
                     'stroke="#b85450" stroke-width="1.8"/>'
                     % (gx + 4, bot + 3, -(ROW_H + 6) / 2.0, -(ROW_H + 6) / 2.0,
                        -(ROW_H + 6) / 2.0, -(ROW_H + 6) / 2.0))

    def render_svg(self):
        p, n, W, H, ys = self._geom()
        o = ['<rect x="0" y="0" width="%g" height="%g" fill="#ffffff"/>' % (W, H)]
        if self.title:
            o.append('<text x="14" y="24" font-family="%s" font-size="15" '
                     'font-weight="700" fill="%s">%s</text>'
                     % (FONT, TXT, _esc(self.title)))
        # cycle grid + tick numbers
        for c in range(n + 1):
            x = LBL_W + c * p
            o.append('<path d="M %g %g L %g %g" stroke="%s" stroke-width="1" '
                     'fill="none"/>' % (x, HEAD_H - 12, x, H - FOOT_H + 4, GRID))
            if c < n:
                o.append('<text x="%g" y="%g" font-family="%s" font-size="10" '
                         'fill="#98a6b5" text-anchor="middle">%d</text>'
                         % (x + p / 2.0, HEAD_H - 18, FONT, c + self.tick))
        # rows
        node_xy = {}
        for idx, (depth, kind, pl) in enumerate(self.rows):
            if kind == "spacer":
                continue
            y = ys[idx]
            if kind == "group":
                o.append('<text x="%g" y="%g" font-family="%s" font-size="11.5" '
                         'font-weight="700" fill="%s">%s</text>'
                         % (8 + depth * GRP_INDENT, y + 13, FONT, "#41546b",
                            _esc(pl["name"])))
                o.append('<path d="M %g %g L %g %g" stroke="%s" stroke-width="1" '
                         'fill="none"/>' % (8, y + 19, W - 20, y + 19, GRID))
                continue
            fam = MONO if pl["mono"] else FONT
            o.append('<text x="%g" y="%g" font-family="%s" font-size="11.5" '
                     'fill="%s" text-anchor="end">%s</text>'
                     % (LBL_W - 12, y + ROW_H / 2.0 + 4, fam, TXT, _esc(pl["name"])))
            self._draw_sig(o, pl, y, p, n)
            if pl["node"]:
                for ci, ch in enumerate(pl["node"]):
                    if ch not in ".|":
                        node_xy[ch] = (LBL_W + ci * p, y + ROW_H / 2.0)
        # edges
        for spec in self.edges:
            body = spec.split(None, 1)
            arrow, label = body[0], (body[1] if len(body) > 1 else "")
            for op in ("<->", "->", "<-", "~>", "-"):
                if op in arrow:
                    a, b = arrow.split(op, 1)
                    break
            else:
                continue
            if a not in node_xy or b not in node_xy:
                continue
            (x0, y0), (x1, y1) = node_xy[a], node_xy[b]
            yy = max(y0, y1) + ROW_H / 2.0 + 5
            se = ' marker-start="url(#wl)"' if op.startswith("<") else ""
            ee = ' marker-end="url(#wr)"' if op.endswith(">") else ""
            o.append('<path d="M %g %g L %g %g L %g %g L %g %g" fill="none" '
                     'stroke="#b85450" stroke-width="1.5" stroke-dasharray="4 3"%s%s/>'
                     % (x0, y0, x0, yy, x1, yy, x1, y1, se, ee))
            if label:
                tw = 6.6 * len(label) + 10
                o.append('<rect x="%g" y="%g" width="%g" height="15" rx="3" '
                         'fill="#ffffff"/>' % ((x0 + x1) / 2.0 - tw / 2, yy - 8, tw))
                o.append('<text x="%g" y="%g" font-family="%s" font-size="10.5" '
                         'font-weight="700" fill="#b85450" text-anchor="middle">%s</text>'
                         % ((x0 + x1) / 2.0, yy + 3.5, FONT, _esc(label)))
        for cyc, text, col in self.notes:
            o.append('<text x="%g" y="%g" font-family="%s" font-size="10.5" '
                     'fill="%s" text-anchor="middle">%s</text>'
                     % (LBL_W + cyc * p, H - FOOT_H + 20, FONT, col, _esc(text)))
        if self.subtitle:
            o.append('<text x="14" y="%g" font-family="%s" font-size="11.5" '
                     'fill="#5a6a7a">%s</text>' % (H - 10, FONT, _esc(self.subtitle)))
        return ('<?xml version="1.0" encoding="UTF-8"?>\n'
                '<svg xmlns="http://www.w3.org/2000/svg" width="%g" height="%g" '
                'viewBox="0 0 %g %g">\n<defs>\n'
                '<pattern id="hatch" width="6" height="6" patternUnits="userSpaceOnUse" '
                'patternTransform="rotate(45)">'
                '<rect width="6" height="6" fill="#eef1f5"/>'
                '<line x1="0" y1="0" x2="0" y2="6" stroke="#aab6c3" stroke-width="2"/>'
                '</pattern>\n'
                '<marker id="wr" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" '
                'markerHeight="6" orient="auto-start-reverse">'
                '<path d="M 0 0 L 10 5 L 0 10 z" fill="#b85450"/></marker>\n'
                '<marker id="wl" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" '
                'markerHeight="6" orient="auto-start-reverse">'
                '<path d="M 0 0 L 10 5 L 0 10 z" fill="#b85450"/></marker>\n'
                '</defs>\n%s\n</svg>\n' % (W, H, W, H, "\n".join(o)))

    def save(self, outdir):
        with open(os.path.join(outdir, self.name + ".json"), "w") as f:
            json.dump(self.to_json(), f, indent=2)
            f.write("\n")
        with open(os.path.join(outdir, self.name + ".svg"), "w") as f:
            f.write(self.render_svg())
        return self.name
