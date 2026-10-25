"""KaPosts app icon: a stack of post cards, the top one a post whose avatar is the backward K
(the Kaspa mark). `python3 make_feed_icon.py light|dark|tinted` writes kaposts-<variant>.svg."""
import sys

PALETTES = {
    #          background  card top / bottom      back cards (near, far)  avatar     K          lines (title, body)            heart
    "light":  ("#FFFFFF", ("#8AD6C9", "#5BBDAC"), ("#B5E5DC", "#DDF3EE"), "#FFFFFF", "#5BBDAC", ("rgba(255,255,255,0.92)", "rgba(255,255,255,0.58)"), "#FFFFFF", 0.16),
    "dark":   ("#1B2029", ("#8AD6C9", "#5BBDAC"), ("#3F7F75", "#2A4B47"), "#1B2029", "#8AD6C9", ("rgba(27,32,41,0.85)", "rgba(27,32,41,0.45)"), "#1B2029", 0.45),
    "tinted": ("#000000", ("#EDEDED", "#C4C4C4"), ("#8C8C8C", "#4D4D4D"), "#000000", "#E6E6E6", ("rgba(0,0,0,0.80)", "rgba(0,0,0,0.38)"), "#000000", 0.5),
}

def k_mark(cx, cy, s, color):
    # the backward K in a 0..90 x -5..105 box, centred on (cx, cy)
    return (f'<g transform="translate({cx - 45*s:.1f} {cy - 50*s:.1f}) scale({s})">'
            f'<polyline points="8,15 61,50 8,85" fill="none" stroke="{color}" stroke-width="17" stroke-miterlimit="4"/>'
            f'<polygon points="60,-3 77,-5 80,50 74,105 56,103 58,50" fill="{color}"/></g>')

def svg(variant):
    bg, (top, bottom), (near, far), avatar, k, (title, body), heart, shadow = PALETTES[variant]
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="card" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{top}"/><stop offset="1" stop-color="{bottom}"/></linearGradient>
    <filter id="soft" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="12" stdDeviation="16" flood-color="#000" flood-opacity="{shadow}"/></filter>
  </defs>
  <rect width="1024" height="1024" fill="{bg}"/>
  <rect x="304" y="168" width="416" height="220" rx="64" fill="{far}"/>
  <rect x="244" y="238" width="536" height="220" rx="72" fill="{near}"/>
  <g filter="url(#soft)"><rect x="172" y="318" width="680" height="500" rx="88" fill="url(#card)"/></g>
  <circle cx="316" cy="462" r="86" fill="{avatar}"/>
  {k_mark(316, 462, 1.25, k)}
  <rect x="440" y="420" width="320" height="36" rx="18" fill="{title}"/>
  <rect x="440" y="482" width="200" height="36" rx="18" fill="{body}"/>
  <rect x="246" y="598" width="532" height="36" rx="18" fill="{body}"/>
  <rect x="246" y="660" width="380" height="36" rx="18" fill="{body}"/>
  <path d="M712 690 c-26 -34 -78 -14 -64 26 c8 24 40 44 64 62 c24 -18 56 -38 64 -62 c14 -40 -38 -60 -64 -26 Z" fill="{heart}"/>
</svg>'''

if __name__ == "__main__":
    for variant in (sys.argv[1:] or PALETTES):
        open(f"kaposts-{variant}.svg", "w").write(svg(variant))
