#!/usr/bin/env python3
"""Builds app/Council/Icons.xcassets from the SVG packs and the avatar PNGs in app/Icons.

Each SVG becomes a template image set (tinted by SwiftUI, vector data preserved). Names are the file name
without the numeric id; when a pack has several icons with the same base name they are numbered in id order:
chat, chat-2, chat-3, ... Run again after adding icons. Prints the name → source mapping.
"""
import json, pathlib, re, shutil, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "Icons"
DST = ROOT / "Council" / "Icons.xcassets"

def main() -> int:
    files = sorted(SRC.rglob("*.svg"), key=lambda p: (re.sub(r"-\d+$", "", p.stem), int(re.search(r"(\d+)$", p.stem).group(1)) if re.search(r"(\d+)$", p.stem) else 0))
    if not files:
        sys.exit(f"no SVGs under {SRC}")
    if DST.exists():
        shutil.rmtree(DST)
    DST.mkdir(parents=True)
    (DST / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2))
    seen: dict[str, int] = {}
    mapping = []
    for f in files:
        base = re.sub(r"-\d+$", "", f.stem)
        seen[base] = seen.get(base, 0) + 1
        name = base if seen[base] == 1 else f"{base}-{seen[base]}"
        iset = DST / f"{name}.imageset"
        iset.mkdir()
        shutil.copy(f, iset / f"{name}.svg")
        (iset / "Contents.json").write_text(json.dumps({
            "images": [{"filename": f"{name}.svg", "idiom": "universal"}],
            "info": {"author": "xcode", "version": 1},
            "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"},
        }, indent=2))
        mapping.append((name, str(f.relative_to(SRC))))
    # Avatars: 64 px PNGs in Icons/avatars, one per member name (claude, codex, deepseek, gemini) plus user.
    # Full-colour, so no template intent; declared 2x so they render at 32 pt without upscaling.
    for f in sorted((SRC / "avatars").glob("*.png")):
        name = f"avatar-{f.stem}"
        iset = DST / f"{name}.imageset"
        iset.mkdir()
        shutil.copy(f, iset / f"{name}@2x.png")
        (iset / "Contents.json").write_text(json.dumps({
            "images": [{"filename": f"{name}@2x.png", "idiom": "universal", "scale": "2x"}],
            "info": {"author": "xcode", "version": 1},
        }, indent=2))
        mapping.append((name, str(f.relative_to(SRC))))
    # The wordmark: a 2x PNG in Icons/, white on transparency. The dark-appearance slot keeps it white; the
    # light one is generated with the letterforms recoloured to the canvas so the orange bars survive.
    logo = SRC / "opencouncil-logo.png"
    if logo.exists():
        iset = DST / "opencouncil-logo.imageset"
        iset.mkdir()
        shutil.copy(logo, iset / "opencouncil-logo-dark@2x.png")
        try:
            from PIL import Image
            im = Image.open(logo).convert("RGBA")
            px = im.load()
            for y in range(im.height):
                for x in range(im.width):
                    r, g, b, a = px[x, y]
                    if a and r > 200 and g > 200 and b > 200:
                        px[x, y] = (11, 11, 15, a)
            im.save(iset / "opencouncil-logo-light@2x.png")
            light = [{"filename": "opencouncil-logo-light@2x.png", "idiom": "universal", "scale": "2x"}]
        except ImportError:
            light = [{"filename": "opencouncil-logo-dark@2x.png", "idiom": "universal", "scale": "2x"}]
        dark = [{"appearances": [{"appearance": "luminosity", "value": "dark"}],
                 "filename": "opencouncil-logo-dark@2x.png", "idiom": "universal", "scale": "2x"}]
        (iset / "Contents.json").write_text(json.dumps({
            "images": light + dark,
            "info": {"author": "xcode", "version": 1},
        }, indent=2))
        mapping.append(("opencouncil-logo", logo.name))

    # Brand colours. AccentColor is what AppKit tints system controls with, so it has to live in the catalog
    # (project.yml points ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME at it); the rest of the palette lives
    # in Palette.swift. Periwinkle #7678ED on light, lifted a little on the near-black canvas.
    def color_set(name: str, light: str, dark: str) -> None:
        def components(hex_value: str) -> dict:
            return {"alpha": "1.000", "blue": f"0x{hex_value[4:6]}", "green": f"0x{hex_value[2:4]}", "red": f"0x{hex_value[0:2]}"}
        cset = DST / f"{name}.colorset"
        cset.mkdir()
        (cset / "Contents.json").write_text(json.dumps({
            "colors": [
                {"color": {"color-space": "srgb", "components": components(light)}, "idiom": "universal"},
                {"appearances": [{"appearance": "luminosity", "value": "dark"}],
                 "color": {"color-space": "srgb", "components": components(dark)}, "idiom": "universal"},
            ],
            "info": {"author": "xcode", "version": 1},
        }, indent=2))
        mapping.append((name, f"#{light} / #{dark}"))

    color_set("AccentColor", "6062D8", "7678ED")

    for name, src in mapping:
        print(f"{name:40s} {src}")
    print(f"\n{len(mapping)} asset entries in {DST.relative_to(ROOT)}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
