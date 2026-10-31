import math, cairosvg

def circle_path(cx, cy, r):
    return f"M{cx-r},{cy} a{r},{r} 0 1,0 {2*r},0 a{r},{r} 0 1,0 {-2*r},0 Z "

def reel_svg(cx, cy, r, holes=6, rot=0, uid=""):
    """A film reel seen face-on: dark flange with cut-out holes, light rim, hub ring."""
    d = circle_path(cx, cy, r)
    for i in range(holes):
        a = math.radians(i*360/holes + rot)
        d += circle_path(cx + 0.60*r*math.cos(a), cy + 0.60*r*math.sin(a), 0.21*r)
    d += circle_path(cx, cy, 0.115*r)
    return (f'<path d="{d}" fill="url(#reelg)" fill-rule="evenodd"/>'
            f'<circle cx="{cx}" cy="{cy}" r="{r-0.03*r}" fill="none" stroke="#dfe2ea" stroke-width="{max(5,0.075*r)}"/>'
            f'<circle cx="{cx}" cy="{cy}" r="{0.29*r}" fill="none" stroke="#dfe2ea" stroke-width="{max(3,0.045*r)}"/>')


import bisect

def bez(p0, p1, p2, p3, n=70):
    out = []
    for i in range(n + 1):
        t = i / n
        a, b, c, d = (1-t)**3, 3*t*(1-t)**2, 3*t*t*(1-t), t**3
        out.append((a*p0[0]+b*p1[0]+c*p2[0]+d*p3[0], a*p0[1]+b*p1[1]+c*p2[1]+d*p3[1]))
    return out

def film_ribbon(segs, half=28):
    """Film strip (with frames + sprocket holes) following a chain of cubic Beziers."""
    pts = []
    for sg in segs:
        pts += bez(*sg)[1:] if pts else bez(*sg)
    cum = [0.0]
    for i in range(1, len(pts)):
        cum.append(cum[-1] + math.hypot(pts[i][0]-pts[i-1][0], pts[i][1]-pts[i-1][1]))
    total = cum[-1]
    T = []
    for i in range(len(pts)):
        a, b = pts[max(i-1, 0)], pts[min(i+1, len(pts)-1)]
        L = math.hypot(b[0]-a[0], b[1]-a[1]) or 1
        T.append(((b[0]-a[0])/L, (b[1]-a[1])/L))
    def at(sv):
        j = min(max(bisect.bisect_left(cum, sv), 1), len(pts)-1)
        f = (sv - cum[j-1]) / ((cum[j]-cum[j-1]) or 1)
        x = pts[j-1][0] + f*(pts[j][0]-pts[j-1][0]); y = pts[j-1][1] + f*(pts[j][1]-pts[j-1][1])
        tx, ty = T[j-1][0] + f*(T[j][0]-T[j-1][0]), T[j-1][1] + f*(T[j][1]-T[j-1][1])
        L = math.hypot(tx, ty) or 1
        return x, y, tx/L, ty/L
    def band(s0, s1, off, step=6):
        left, right = [], []
        sv = s0
        while sv <= s1 + 1e-6:
            x, y, tx, ty = at(sv); nx, ny = -ty, tx
            left.append((x+nx*off, y+ny*off)); right.append((x-nx*off, y-ny*off)); sv += step
        poly = left + right[::-1]
        return " ".join(f"{px:.1f},{py:.1f}" for px, py in poly)
    svg = f'<polygon points="{band(0, total, half)}" fill="#17171b"/>'
    sv = 26
    while sv + 46 < total:
        svg += f'<polygon points="{band(sv, sv+46, half-15, 4)}" fill="#3b3b44"/>'
        sv += 62
    sv = 12
    while sv < total - 6:
        x, y, tx, ty = at(sv); nx, ny = -ty, tx
        deg = math.degrees(math.atan2(ty, tx))
        for side in (1, -1):
            cx, cy = x + side*nx*(half-8.5), y + side*ny*(half-8.5)
            svg += (f'<rect x="{cx-6:.1f}" y="{cy-6.5:.1f}" width="12" height="13" rx="2.5" fill="#f3f1ea" '
                    f'transform="rotate({deg:.1f} {cx:.1f} {cy:.1f})"/>')
        sv += 29
    return svg

# ---- input reel (upper left) and its strip ----
IN = (250, 250, 105)
dx, dy = 434-IN[0], 448-IN[1]
ang = math.degrees(math.atan2(dy, dx))
dist = math.hypot(dx, dy)
start = 92
sx, sy = IN[0] + start*math.cos(math.radians(ang)), IN[1] + start*math.sin(math.radians(ang))
length = dist - start + 30

def strip(length, w, nframes_step=60, sp=30, sw=14, sh=15, half=38):
    out = f'<rect x="0" y="{-half}" width="{length}" height="{2*half}" fill="#17171b"/>'
    k = 0
    while 10 + k*nframes_step + 50 <= length:
        out += f'<rect x="{10+k*nframes_step}" y="-13" width="50" height="26" rx="3" fill="#3b3b44"/>'
        k += 1
    x = 12
    while x + sw <= length:
        out += f'<rect x="{x}" y="{-half+5}" width="{sw}" height="{sh}" rx="3" fill="#f3f1ea"/>'
        out += f'<rect x="{x}" y="{half-5-sh}" width="{sw}" height="{sh}" rx="3" fill="#f3f1ea"/>'
        x += sp
    return out

# ---- output: two strips of film unspooling out of the right-hand end ----
stripA = film_ribbon([((690,574),(800,552),(884,616),(852,700)),
                      ((852,700),(824,772),(776,790),(796,866))], half=28)
stripB = film_ribbon([((690,632),(766,640),(800,690),(768,742)),
                      ((768,742),(738,790),(690,790),(676,860))], half=28)
out_strip = stripA + stripB
out_reels = ""

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#f06a4d"/><stop offset="1" stop-color="#a02a20"/>
  </linearGradient>
  <linearGradient id="steel" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#eef1f6"/><stop offset="0.45" stop-color="#b5bcc8"/><stop offset="1" stop-color="#6f7684"/>
  </linearGradient>
  <linearGradient id="steelDark" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#9aa2b0"/><stop offset="1" stop-color="#555b68"/>
  </linearGradient>
  <radialGradient id="knob" cx="0.35" cy="0.3" r="0.8">
    <stop offset="0" stop-color="#e8a06a"/><stop offset="1" stop-color="#7a3b1c"/>
  </radialGradient>
  <linearGradient id="reelg" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#4a4a55"/><stop offset="1" stop-color="#1e1e24"/>
  </linearGradient>
  <filter id="sh" x="-20%" y="-20%" width="140%" height="140%">
    <feDropShadow dx="0" dy="8" stdDeviation="8" flood-color="#000" flood-opacity="0.35"/>
  </filter>
  <clipPath id="clipbg"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath>
</defs>

<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#bg)"/>
<g clip-path="url(#clipbg)">
  <ellipse cx="512" cy="930" rx="420" ry="90" fill="#000" opacity="0.18"/>

  <!-- grinder, back parts (mirrored left-right) -->
  <g transform="translate(1024,0) scale(-1,1)">
    <rect x="470" y="660" width="170" height="52" rx="10" fill="url(#steelDark)"/>
    <rect x="430" y="706" width="250" height="26" rx="12" fill="#444a55"/>
    <ellipse cx="590" cy="432" rx="112" ry="24" fill="url(#steel)"/>
    <ellipse cx="590" cy="434" rx="96" ry="18" fill="#1b1b20"/>
  </g>

  <!-- film strip feeding the hopper from the upper left -->
  <g transform="translate({sx:.1f},{sy:.1f}) rotate({ang:.1f})" filter="url(#sh)">{strip(length, 0)}</g>

  <!-- output: film + reels tumbling out of the right-hand end -->
  <g filter="url(#sh)">{out_strip}{out_reels}</g>

  <!-- grinder, front parts (mirrored left-right) -->
  <g transform="translate(1024,0) scale(-1,1)">
    <path d="M478,436 A112,24 0 0 0 702,436 L664,545 L516,545 Z" fill="url(#steel)"/>
    <path d="M478,436 A112,24 0 0 0 702,436" fill="none" stroke="#f7f9fc" stroke-width="5" opacity="0.7"/>

    <g filter="url(#sh)">
      <rect x="335" y="520" width="440" height="160" rx="62" fill="url(#steel)"/>
      <rect x="360" y="532" width="390" height="26" rx="13" fill="#fff" opacity="0.35"/>
      <rect x="296" y="540" width="62" height="120" rx="18" fill="url(#steelDark)"/>
      <rect x="296" y="540" width="14" height="120" rx="7" fill="#2f333b"/>
    </g>

    <circle cx="776" cy="600" r="36" fill="url(#steelDark)"/>
    <circle cx="776" cy="600" r="14" fill="#2f333b"/>
    <line x1="776" y1="600" x2="842" y2="770" stroke="#4a505c" stroke-width="30" stroke-linecap="round"/>
    <line x1="776" y1="600" x2="842" y2="770" stroke="#8b93a1" stroke-width="10" stroke-linecap="round"/>
    <circle cx="848" cy="780" r="38" fill="url(#knob)" filter="url(#sh)"/>
  </g>

  <!-- input reel -->
  <g filter="url(#sh)">{reel_svg(*IN, 6, 0)}</g>
</g>
</svg>'''
open('icon.svg','w').write(svg)
cairosvg.svg2png(bytestring=svg.encode(), write_to='icon_1024.png', output_width=1024, output_height=1024)
print("ok")
