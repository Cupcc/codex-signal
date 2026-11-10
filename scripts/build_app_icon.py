#!/usr/bin/env python3
"""Build the macOS app icon from the original blue companion artwork."""
from pathlib import Path
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "design/assets"))
from build_toys import build, eyes

SVG = "{http://www.w3.org/2000/svg}"
ET.register_namespace("", "http://www.w3.org/2000/svg")


def artwork():
    source = ET.fromstring(build("idle"))
    character = source.find(f"{SVG}g[@class='m-character']")
    expression = character.find(f".//{SVG}g[@class='m-eyes']")
    expression.clear()
    expression.extend(ET.fromstring(f'<svg xmlns="http://www.w3.org/2000/svg">{eyes("attention")}</svg>'))
    character.set("transform", "translate(76 76) scale(6.8)")
    defs = source.find(SVG + "defs")
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" role="img" aria-label="Codex Signal 应用图标">
<title>Codex Signal</title>
{ET.tostring(defs, encoding="unicode")}
<defs>
  <linearGradient id="tile" x1="0" y1="0" x2=".75" y2="1"><stop stop-color="#F7FCFF"/><stop offset="1" stop-color="#D2E7FF"/></linearGradient>
  <radialGradient id="shadow"><stop stop-color="#1C4C94" stop-opacity=".22"/><stop offset="1" stop-color="#1C4C94" stop-opacity="0"/></radialGradient>
</defs>
<rect x="100" y="110" width="824" height="824" rx="184" fill="#102C57" opacity=".12"/>
<rect x="100" y="100" width="824" height="824" rx="184" fill="url(#tile)"/>
<rect x="102" y="102" width="820" height="820" rx="182" fill="none" stroke="#FFFFFF" stroke-opacity=".7" stroke-width="4"/>
<ellipse cx="512" cy="792" rx="306" ry="58" fill="url(#shadow)"/>
{ET.tostring(character, encoding="unicode")}
</svg>
'''


def export():
    assets = ROOT / "design/assets"
    svg = assets / "app-icon.svg"
    preview = assets / "app-icon.png"
    output = ROOT / "Sources/SignalApp/Resources/AppIcon.icns"
    svg.write_text(artwork(), encoding="utf-8")
    subprocess.run(["/usr/bin/sips", "-s", "format", "png", str(svg), "--out", str(preview)],
                   check=True, stdout=subprocess.DEVNULL)
    with tempfile.TemporaryDirectory(prefix="codex-signal-icon-") as temporary:
        iconset = Path(temporary) / "AppIcon.iconset"
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                pixels = str(size * scale)
                suffix = "@2x" if scale == 2 else ""
                subprocess.run(["/usr/bin/sips", "-z", pixels, pixels, str(preview),
                                "--out", str(iconset / f"icon_{size}x{size}{suffix}.png")],
                               check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["/usr/bin/iconutil", "-c", "icns", str(iconset), "-o", str(output)], check=True)
    print(f"Built {output.relative_to(ROOT)} (16–1024 px)")


if __name__ == "__main__":
    export()
