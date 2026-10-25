# KaPosts app icon

A stack of post cards; the top card is a post whose avatar is the Kaspa mark (the backward K),
with a name, two lines of text and a heart. `python3 make_feed_icon.py` writes
`kaposts-light.svg`, `kaposts-dark.svg` and `kaposts-tinted.svg`. Render each at 1024x1024 and
save it opaque (no alpha) into `KaPosts/Resources/Assets.xcassets/AppIcon.appiconset`
(`white.png`, `dark.png`, `Icon-iOS-TintedDark-1024x1024@1x.png`). On a Mac without other tools:

```bash
python3 make_feed_icon.py && qlmanage -t -s 1024 -o . kaposts-light.svg
sips -s format jpeg kaposts-light.svg.png --out t.jpg && sips -s format png t.jpg --out white.png
```

`KaPostsLogo.imageset` (the setup screen's logo) is the light icon at 512 px.
