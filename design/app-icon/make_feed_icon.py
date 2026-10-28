"""KaPosts app icon: a stack of post cards, the top one a post whose avatar is the backward K
(the Kaspa mark). `python3 make_feed_icon.py light|dark|tinted` writes kaposts-<variant>.svg."""
import sys

PALETTES = {
    #          background  card top / bottom      back cards (near, far)  avatar     K          lines (title, body)            heart
    "light":  ("#FFFFFF", ("#8AD6C9", "#5BBDAC"), ("#B5E5DC", "#DDF3EE"), "#FFFFFF", "#5BBDAC", ("rgba(255,255,255,0.92)", "rgba(255,255,255,0.58)"), "#FFFFFF", 0.16),
    "dark":   ("#1B2029", ("#8AD6C9", "#5BBDAC"), ("#3F7F75", "#2A4B47"), "#1B2029", "#8AD6C9", ("rgba(27,32,41,0.85)", "rgba(27,32,41,0.45)"), "#1B2029", 0.45),
    "tinted": ("#000000", ("#EDEDED", "#C4C4C4"), ("#8C8C8C", "#4D4D4D"), "#000000", "#E6E6E6", ("rgba(0,0,0,0.80)", "rgba(0,0,0,0.38)"), "#000000", 0.5),
}

# The backward K exactly as KaChat's app icon draws it, traced from KaChat's 1024 px icon
# (KaChat-iPhone AppIcon.appiconset/white.png): the bent bar and the thick chevron, in that
# icon's pixels. Its bounding box is 360..665 x 254..690, centred on (512.9, 472).
K_BAR = [(556, 268), (632, 254), (665.4, 472), (632, 690), (556, 676), (588.1, 472)]
K_CHEVRON = [(407.9, 293.6), (636.2, 472), (407.9, 650.4), (360.4, 587.9), (508.8, 472), (360.4, 356.1)]
K_CENTRE, K_HEIGHT = (512.9, 472), 436

def k_mark(cx, cy, height, color):
    # the backward K, `height` px tall, its bounding box centred on (cx, cy)
    s = height / K_HEIGHT
    def points(shape):
        return " ".join(f"{cx + s*(x - K_CENTRE[0]):.1f},{cy + s*(y - K_CENTRE[1]):.1f}" for x, y in shape)
    return f'<polygon points="{points(K_BAR)}" fill="{color}"/><polygon points="{points(K_CHEVRON)}" fill="{color}"/>'

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
  {k_mark(316, 462, 132, k)}
  <rect x="440" y="420" width="320" height="36" rx="18" fill="{title}"/>
  <rect x="440" y="482" width="200" height="36" rx="18" fill="{body}"/>
  <rect x="246" y="598" width="532" height="36" rx="18" fill="{body}"/>
  <rect x="246" y="660" width="380" height="36" rx="18" fill="{body}"/>
  <path d="M712 690 c-26 -34 -78 -14 -64 26 c8 24 40 44 64 62 c24 -18 56 -38 64 -62 c14 -40 -38 -60 -64 -26 Z" fill="{heart}"/>
</svg>'''

if __name__ == "__main__":
    for variant in (sys.argv[1:] or PALETTES):
        open(f"kaposts-{variant}.svg", "w").write(svg(variant))
