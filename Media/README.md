# Media

Bugsy's own art. WoW loads TGA (uncompressed, 32-bit, power-of-two), never PNG.

| File | Size | Used for | Made from |
|---|---|---|---|
| `Hat.tga` | 128×128 | the window's header and the empty state | the hat of the owner's "BUGSY liquid glass fedora logo" (generated art, 1254×1254), its navy ground keyed out to transparency (a matte against the ground colour, so the glass stays see-through) |
| `Icon.tga` | 64×64 | the addon list (TOC `IconTexture`) and the minimap button | the same keyed hat on the logo's navy ground, corners rounded, so it reads at 16-20 pixels |

Both come from one command (the master stays out of git):

```
python -I Tools/make_art.py "BUGSY liquid glass fedora logo.png" --out Media [--preview DIR]
```

`--preview` writes each texture over a dark and a light ground, magnified, to look at first.
