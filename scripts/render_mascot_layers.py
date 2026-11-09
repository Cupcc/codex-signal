#!/usr/bin/env python3
"""Export native animation layers from the same artwork as the HTML preview."""
from copy import deepcopy
from pathlib import Path
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "design/assets"))
from build_toys import STATES, build

ET.register_namespace("", "http://www.w3.org/2000/svg")
SVG = "{http://www.w3.org/2000/svg}"
OUTPUT = ROOT / "Sources/SignalApp/Resources/MascotLayers"


def retain(node, target, inside=False):
    """Preserve ancestor transforms, excluding siblings and body eye artwork."""
    inside = inside or node.get("class") == target
    for child in list(node):
        if target == "m-body" and child.get("class") == "m-eyes":
            node.remove(child)
        elif not retain(child, target, inside):
            node.remove(child)
    return inside or len(node) > 0


def export():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as temporary:
        for mini in (False, True):
            for state in STATES:
                source = ET.fromstring(build(state, mini))
                if mini:
                    for parent in source.iter():
                        for child in list(parent):
                            if child.get("class") == "detail":
                                parent.remove(child)
                for part in ("ground", "body", "eyes", "left", "right", "badge", "open"):
                    drawing = ET.Element(SVG + "svg", width="256", height="256", viewBox="0 0 128 128")
                    drawing.append(deepcopy(source.find(SVG + "defs")))
                    if part == "ground":
                        for node in source.findall(SVG + "ellipse"):
                            drawing.append(deepcopy(node))
                    elif part == "open":
                        if state != "idle":
                            continue
                        eyes = ET.SubElement(drawing, SVG + "g")
                        if mini:
                            eyes.set("transform", "translate(-7 -7) scale(1.11)")
                        for x in (45, 72):
                            ET.SubElement(eyes, SVG + "rect", x=str(x), y="57", width="8", height="10", rx="4", fill="#15345F")
                    else:
                        for node in source.findall(SVG + "g"):
                            copy = deepcopy(node)
                            if retain(copy, "m-" + part):
                                drawing.append(copy)
                    name = f"{'mini-' if mini else ''}{state}-{part}"
                    svg = Path(temporary) / (name + ".svg")
                    ET.ElementTree(drawing).write(svg, encoding="unicode")
                    subprocess.run(["/usr/bin/sips", "-s", "format", "png", str(svg),
                                    "--out", str(OUTPUT / (name + ".png"))], check=True, stdout=subprocess.DEVNULL)
    print("Exported 62 mascot layers at 2× design resolution.")


if __name__ == "__main__":
    export()
