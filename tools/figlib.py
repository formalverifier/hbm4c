"""
figlib -- generate .drawio.svg figures.

A .drawio.svg is a normal SVG (renders in Markdown, GitHub, any browser) that also
carries the editable mxGraph model in its `content` attribute. Opening it with the
draw.io VS Code extension or diagrams.net gives a fully editable diagram; nothing
needs a build step to *view* it.

We emit both representations from one description so they cannot drift apart.
"""

import html
import os

# ---------------------------------------------------------------- palette
# Opaque fills with dark text, plus an explicit page background, so figures stay
# legible on light and dark Markdown themes alike.
PAL = {
    "page":   ("#ffffff", "#ffffff"),
    "group":  ("#f4f6f9", "#9aa5b1"),   # container / hierarchy box
    "core":   ("#dae8fc", "#6c8ebf"),   # controller datapath + control
    "fe":     ("#d5e8d4", "#82b366"),   # front-end / host side
    "ras":    ("#ffe6cc", "#d79b00"),   # RAS / ECC
    "phy":    ("#e1d5e7", "#9673a6"),   # DFI / PHY / DRAM
    "hot":    ("#f8cecc", "#b85450"),   # critical path / caution
    "plain":  ("#ffffff", "#7a869a"),   # neutral
    "dark":   ("#3d4b5c", "#2b3644"),   # header bands (white text)
}
TXT = "#16202c"
TXT_INV = "#ffffff"
FONT = "Helvetica,Arial,sans-serif"


def _esc(s):
    return html.escape(s, quote=True)


class Fig:
    def __init__(self, name, w, h, title=None, subtitle=None):
        self.name, self.w, self.h = name, w, h
        self.title, self.subtitle = title, subtitle
        self.nodes = {}          # id -> dict
        self.order = []          # draw order
        self.edges = []
        self.texts = []          # free-standing labels
        self._uid = 0

    def _nid(self, prefix="n"):
        self._uid += 1
        return "%s%d" % (prefix, self._uid)

    # ------------------------------------------------------------ elements
    def box(self, nid, x, y, w, h, label, kind="core", sub=None,
            rounded=True, dashed=False, fs=12, bold=True, inv=False):
        self.nodes[nid] = dict(id=nid, x=x, y=y, w=w, h=h, label=label, kind=kind,
                               sub=sub, rounded=rounded, dashed=dashed, fs=fs,
                               bold=bold, inv=inv, container=False)
        self.order.append(nid)
        return nid

    def group(self, nid, x, y, w, h, label, kind="group", dashed=False, fs=12):
        """Container box: label sits at the top-left, children drawn over it."""
        self.nodes[nid] = dict(id=nid, x=x, y=y, w=w, h=h, label=label, kind=kind,
                               sub=None, rounded=False, dashed=dashed, fs=fs,
                               bold=True, inv=False, container=True)
        self.order.append(nid)
        return nid

    def text(self, x, y, s, fs=11, anchor="middle", color=None, bold=False, mono=False):
        self.texts.append(dict(x=x, y=y, s=s, fs=fs, anchor=anchor,
                               color=color or TXT, bold=bold, mono=mono))

    def edge(self, src, dst, label=None, style="solid", thick=False,
             both=False, label_dy=-6, kind=None):
        """src/dst are (node_id, side, frac) with side in n/s/e/w, frac in 0..1."""
        self.edges.append(dict(src=src, dst=dst, label=label, style=style,
                               thick=thick, both=both, label_dy=label_dy, kind=kind))

    # ------------------------------------------------------------ geometry
    def _anchor(self, a):
        nid, side, frac = a
        n = self.nodes[nid]
        if side == "n":
            return (n["x"] + n["w"] * frac, n["y"])
        if side == "s":
            return (n["x"] + n["w"] * frac, n["y"] + n["h"])
        if side == "w":
            return (n["x"], n["y"] + n["h"] * frac)
        if side == "e":
            return (n["x"] + n["w"], n["y"] + n["h"] * frac)
        return (n["x"] + n["w"] / 2.0, n["y"] + n["h"] / 2.0)

    def _route(self, e):
        p0 = self._anchor(e["src"])
        p1 = self._anchor(e["dst"])
        s0 = e["src"][1]
        pts = [p0]
        if abs(p0[0] - p1[0]) < 1.5 or abs(p0[1] - p1[1]) < 1.5:
            pass                                    # straight
        elif s0 in ("n", "s"):                      # leave vertically
            my = (p0[1] + p1[1]) / 2.0
            pts += [(p0[0], my), (p1[0], my)]
        else:                                       # leave horizontally
            mx = (p0[0] + p1[0]) / 2.0
            pts += [(mx, p0[1]), (mx, p1[1])]
        pts.append(p1)
        return pts

    # ------------------------------------------------------------ SVG out
    def _svg_body(self):
        o = []
        o.append('<rect x="0" y="0" width="%d" height="%d" fill="%s"/>'
                 % (self.w, self.h, PAL["page"][0]))
        ty = 0
        if self.title:
            o.append('<text x="%d" y="30" font-family="%s" font-size="17" '
                     'font-weight="700" fill="%s">%s</text>'
                     % (24, FONT, TXT, _esc(self.title)))
            ty = 30
        if self.subtitle:
            o.append('<text x="%d" y="%d" font-family="%s" font-size="11.5" '
                     'fill="#5a6a7a">%s</text>' % (24, ty + 18, FONT, _esc(self.subtitle)))

        for nid in self.order:
            n = self.nodes[nid]
            fill, stroke = PAL[n["kind"]]
            rx = 6 if n["rounded"] else 0
            dash = ' stroke-dasharray="6 4"' if n["dashed"] else ""
            o.append('<rect x="%g" y="%g" width="%g" height="%g" rx="%d" fill="%s" '
                     'stroke="%s" stroke-width="1.6"%s/>'
                     % (n["x"], n["y"], n["w"], n["h"], rx, fill, stroke, dash))
            col = TXT_INV if n["inv"] else TXT
            wt = "700" if n["bold"] else "400"
            lines = n["label"].split("\n")
            if n["container"]:
                o.append('<text x="%g" y="%g" font-family="%s" font-size="%g" '
                         'font-weight="%s" fill="%s">%s</text>'
                         % (n["x"] + 10, n["y"] + n["fs"] + 6, FONT, n["fs"], wt,
                            col, _esc(lines[0])))
                for i, ln in enumerate(lines[1:]):
                    o.append('<text x="%g" y="%g" font-family="%s" font-size="10" '
                             'fill="#5a6a7a">%s</text>'
                             % (n["x"] + 10, n["y"] + n["fs"] + 22 + i * 13, FONT, _esc(ln)))
            else:
                sub = n["sub"].split("\n") if n["sub"] else []
                total = len(lines) * (n["fs"] + 3) + len(sub) * 12
                y = n["y"] + n["h"] / 2.0 - total / 2.0 + n["fs"] - 1
                cx = n["x"] + n["w"] / 2.0
                for ln in lines:
                    o.append('<text x="%g" y="%g" font-family="%s" font-size="%g" '
                             'font-weight="%s" fill="%s" text-anchor="middle">%s</text>'
                             % (cx, y, FONT, n["fs"], wt, col, _esc(ln)))
                    y += n["fs"] + 3
                for ln in sub:
                    o.append('<text x="%g" y="%g" font-family="%s" font-size="10" '
                             'fill="%s" text-anchor="middle">%s</text>'
                             % (cx, y + 2, FONT,
                                "#e6ecf2" if n["inv"] else "#4a5a6a", _esc(ln)))
                    y += 12

        for e in self.edges:
            pts = self._route(e)
            d = "M %g %g " % pts[0] + " ".join("L %g %g" % p for p in pts[1:])
            stroke = PAL[e["kind"]][1] if e["kind"] else "#41546b"
            dash = ' stroke-dasharray="5 4"' if e["style"] == "dashed" else ""
            sw = 3.0 if e["thick"] else 1.7
            o.append('<path d="%s" fill="none" stroke="%s" stroke-width="%g"%s '
                     'marker-end="url(#ah)"%s/>'
                     % (d, stroke, sw, dash,
                        ' marker-start="url(#ahs)"' if e["both"] else ""))
            if e["label"]:
                mid = pts[len(pts) // 2] if len(pts) > 2 else \
                    ((pts[0][0] + pts[-1][0]) / 2.0, (pts[0][1] + pts[-1][1]) / 2.0)
                tw = 6.4 * len(e["label"]) + 10
                o.append('<rect x="%g" y="%g" width="%g" height="15" rx="3" '
                         'fill="%s" opacity="0.94"/>'
                         % (mid[0] - tw / 2.0, mid[1] + e["label_dy"] - 11, tw, PAL["page"][0]))
                o.append('<text x="%g" y="%g" font-family="%s" font-size="10.5" '
                         'fill="#41546b" text-anchor="middle">%s</text>'
                         % (mid[0], mid[1] + e["label_dy"], FONT, _esc(e["label"])))

        for t in self.texts:
            fam = "SFMono-Regular,Menlo,monospace" if t["mono"] else FONT
            o.append('<text x="%g" y="%g" font-family="%s" font-size="%g" '
                     'fill="%s" text-anchor="%s"%s>%s</text>'
                     % (t["x"], t["y"], fam, t["fs"], t["color"], t["anchor"],
                        ' font-weight="700"' if t["bold"] else "", _esc(t["s"])))
        return "\n".join(o)

    # ------------------------------------------------------------ mxGraph out
    def _mx(self):
        c = ['<mxGraphModel dx="1200" dy="800" grid="1" gridSize="10" guides="1" '
             'tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" '
             'pageWidth="%d" pageHeight="%d" math="0" shadow="0">' % (self.w, self.h),
             '<root><mxCell id="0"/><mxCell id="1" parent="0"/>']
        for nid in self.order:
            n = self.nodes[nid]
            fill, stroke = PAL[n["kind"]]
            st = ("rounded=%d;whiteSpace=wrap;html=1;fillColor=%s;strokeColor=%s;"
                  "fontSize=%g;fontColor=%s;%s%s%s"
                  % (1 if n["rounded"] else 0, fill, stroke, n["fs"],
                     TXT_INV if n["inv"] else TXT,
                     "fontStyle=1;" if n["bold"] else "",
                     "dashed=1;" if n["dashed"] else "",
                     "verticalAlign=top;align=left;spacingLeft=8;spacingTop=4;"
                     if n["container"] else ""))
            lab = n["label"] + (("\n" + n["sub"]) if n["sub"] else "")
            c.append('<mxCell id="%s" value="%s" style="%s" vertex="1" parent="1">'
                     '<mxGeometry x="%g" y="%g" width="%g" height="%g" as="geometry"/>'
                     '</mxCell>'
                     % (nid, _esc(lab.replace("\n", "&#10;")), st,
                        n["x"], n["y"], n["w"], n["h"]))
        side_xy = {"n": (0.5, 0), "s": (0.5, 1), "w": (0, 0.5), "e": (1, 0.5)}
        for i, e in enumerate(self.edges):
            sn, ss, sf = e["src"]
            dn, ds, df = e["dst"]
            sx, sy = side_xy[ss]
            dx, dy = side_xy[ds]
            sx, sy = (sf, sy) if ss in "ns" else (sx, sf)
            dx, dy = (df, dy) if ds in "ns" else (dx, df)
            st = ("edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;"
                  "exitX=%g;exitY=%g;entryX=%g;entryY=%g;exitDx=0;exitDy=0;"
                  "entryDx=0;entryDy=0;strokeWidth=%g;strokeColor=%s;%s%s"
                  % (sx, sy, dx, dy, 3 if e["thick"] else 1.6,
                     PAL[e["kind"]][1] if e["kind"] else "#41546b",
                     "dashed=1;" if e["style"] == "dashed" else "",
                     "startArrow=classic;startFill=1;" if e["both"] else ""))
            c.append('<mxCell id="e%d" value="%s" style="%s" edge="1" parent="1" '
                     'source="%s" target="%s"><mxGeometry relative="1" as="geometry"/>'
                     '</mxCell>' % (i, _esc(e["label"] or ""), st, sn, dn))
        for i, t in enumerate(self.texts):
            st = ("text;html=1;strokeColor=none;fillColor=none;align=%s;"
                  "verticalAlign=middle;fontSize=%g;fontColor=%s;%s"
                  % ({"middle": "center", "start": "left", "end": "right"}[t["anchor"]],
                     t["fs"], t["color"], "fontStyle=1;" if t["bold"] else ""))
            tw = max(180, 7.0 * len(t["s"]))
            tx = {"middle": t["x"] - tw / 2.0, "start": t["x"], "end": t["x"] - tw}[t["anchor"]]
            c.append('<mxCell id="t%d" value="%s" style="%s" vertex="1" parent="1">'
                     '<mxGeometry x="%g" y="%g" width="%g" height="18" as="geometry"/>'
                     '</mxCell>'
                     % (i, _esc(t["s"]), st, tx, t["y"] - 12, tw))
        if self.title:
            c.append('<mxCell id="ttl" value="%s" style="text;html=1;fontSize=17;'
                     'fontStyle=1;strokeColor=none;fillColor=none;align=left;" '
                     'vertex="1" parent="1"><mxGeometry x="20" y="12" width="%d" '
                     'height="26" as="geometry"/></mxCell>'
                     % (_esc(self.title), self.w - 40))
        c.append("</root></mxGraphModel>")
        return "".join(c)

    # ------------------------------------------------------------ emit
    def save(self, outdir):
        mxfile = ('<mxfile host="app.diagrams.net" modified="2026-01-01T00:00:00.000Z" '
                  'agent="hbm4c-figlib" version="24.0.0" type="device">'
                  '<diagram id="%s" name="%s">%s</diagram></mxfile>'
                  % (self.name, self.name, self._mx()))
        svg = (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<svg xmlns="http://www.w3.org/2000/svg" '
            'xmlns:xlink="http://www.w3.org/1999/xlink" '
            'width="%d" height="%d" viewBox="0 0 %d %d" '
            'content="%s">\n'
            '<defs>\n'
            '<marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" '
            'markerHeight="7" orient="auto-start-reverse">'
            '<path d="M 0 0 L 10 5 L 0 10 z" fill="#41546b"/></marker>\n'
            '<marker id="ahs" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" '
            'markerHeight="7" orient="auto-start-reverse">'
            '<path d="M 0 0 L 10 5 L 0 10 z" fill="#41546b"/></marker>\n'
            '</defs>\n%s\n</svg>\n'
            % (self.w, self.h, self.w, self.h, _esc(mxfile), self._svg_body()))
        path = os.path.join(outdir, self.name + ".drawio.svg")
        with open(path, "w") as f:
            f.write(svg)
        return path
