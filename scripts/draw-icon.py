#!/usr/bin/env python3
"""Generate Foldertone's Icon Composer layers from closed vector shapes."""

import json
import logging
from pathlib import Path

log = logging.getLogger(__name__)
ROOT = Path(__file__).resolve().parent.parent
ICON = ROOT / "Foldertone" / "AppIcon.icon"
WHITE = "srgb:1.00000,1.00000,1.00000,1.00000"
PURPLE = "srgb:0.34510,0.19608,0.73725,1.00000"


def svg(path: str) -> str:
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
        'viewBox="0 0 1024 1024" fill="none">\n'
        f'  <path d="{path}" fill="white"/>\n</svg>\n'
    )


def layer(name: str, color: str, glass: bool = True) -> dict:
    return {
        "image-name": f"{name}.svg",
        "name": name,
        "glass": glass,
        "fill-specializations": [{"value": {"solid": color}}],
    }


def group(*layers: dict) -> dict:
    return {
        "layers": list(layers),
        "lighting": "individual",
        "shadow": {"kind": "neutral", "opacity": 0.5},
        "specular": True,
        "translucency": {"enabled": False, "value": 0.5},
    }


def main() -> None:
    # The folder spans 64% of the canvas, matching the other apps' visual weight.
    paths = {
        "back": "M184 340 V300 Q184 252 232 252 H388 Q412 252 428 272 "
        "L474 324 H792 Q840 324 840 372 V680 Q840 728 792 728 H232 "
        "Q184 728 184 680 Z",
        "front": "M184 408 Q184 360 232 360 H792 Q840 360 840 408 "
        "V724 Q840 772 792 772 H232 Q184 772 184 724 Z",
        "play": "M458 468 Q458 448 476 459 L632 550 Q651 561 632 572 "
        "L476 663 Q458 674 458 654 Z",
    }
    assets = ICON / "Assets"
    assets.mkdir(parents=True, exist_ok=True)
    for name, path in paths.items():
        (assets / f"{name}.svg").write_text(svg(path))
    document = {
        "fill-specializations": [
            {"value": {"linear-gradient": [
                "extended-srgb:0.69020,0.52157,1.00000,1.00000",
                "extended-srgb:0.34510,0.19608,0.73725,1.00000",
            ]}},
            {"appearance": "dark", "value": {"linear-gradient": [
                "extended-srgb:0.25882,0.18039,0.43922,1.00000",
                "extended-srgb:0.10980,0.07451,0.20392,1.00000",
            ]}},
        ],
        # Topmost first. Play is printed on the glass front, like Rota's dial.
        "groups": [
            group(layer("play", PURPLE, glass=False), layer("front", WHITE)),
            group(layer("back", "srgb:0.83529,0.76471,1.00000,1.00000")),
        ],
        "supported-platforms": {"squares": "shared"},
    }
    (ICON / "icon.json").write_text(json.dumps(document, indent=2) + "\n")
    log.info("Generated %s", ICON.relative_to(ROOT))


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    main()
