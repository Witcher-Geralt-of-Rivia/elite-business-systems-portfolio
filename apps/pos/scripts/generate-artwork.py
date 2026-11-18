"""Generates the Harbor & Pine Market catalog artwork (original, simple vector illustrations).

Output: modules/HarborPine/Public/images/{categories,products}/*.svg, served by NexoPOS as
/modules/harborpine/images/... . Product files are keyed by category, shape and shade:
  shape  = SHAPE_BY_FORM[form] or the category's default shape
  shade  = crc32(base product name) % 3   (PHP's crc32() gives the same value; see Artwork.php)
Run: python apps/pos/scripts/generate-artwork.py
"""
import json
import pathlib
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[1] / "modules" / "HarborPine"
OUT = ROOT / "Public" / "images"

COLORS = {
    "coffee": "#6f4e37", "bakery": "#b9822f", "cheese": "#c99a1e", "pantry": "#6f8133",
    "sauces": "#a23b3e", "snacks": "#8a4b76", "drinks": "#2c7a89", "kitchen": "#475a70",
    "table": "#56789f", "candles": "#ad6a42", "gifts": "#75559e", "body": "#468a68",
}
CATEGORY_SHAPE = {
    "coffee": "mug", "bakery": "loaf", "cheese": "wedge", "pantry": "jar", "sauces": "jar",
    "snacks": "bar", "drinks": "bottle", "kitchen": "pan", "table": "plate", "candles": "candle",
    "gifts": "gift", "body": "soap",
}
SHAPE_BY_FORM = {
    "Jar": "jar", "Bag": "bag", "Whole bean": "bag", "Ground": "bag", "Loose leaf": "leaf", "Kraft": "card",
    "Bottle": "bottle", "Box": "box", "Set of 2": "box", "Set of 3": "box", "Set of 4": "box", "Set of 6": "box",
    "Kit": "box", "Curated": "gift", "Carton": "box", "Loaf": "loaf", "Pastry": "pastry",
    "Soy wax": "candle", "Beeswax": "candle", "Diffuser": "diffuser", "Tin": "can", "Can": "can", "Bar": "bar",
    "Aged 12 months": "wedge", "Soft-ripened": "round", "Wedge": "wedge", "Fresh": "round", "Cured": "salami",
    "Cold-smoked": "fish", "Tea bags": "mug", "Letterpress": "card", "8x10": "frame", "Cold process": "soap",
}

W = 'fill="none" stroke="#fff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"'
SHAPES = {
    "jar": f'<rect x="72" y="52" width="56" height="16" rx="4" {W}/><path d="M68 68h64v58a10 10 0 0 1-10 10H78a10 10 0 0 1-10-10z" {W}/><path d="M80 92h40v22H80z" {W} opacity=".7"/>',
    "bag": f'<path d="M74 48h52l8 88H66z" {W}/><path d="M74 48l6 12h40l6-12" {W}/><circle cx="100" cy="98" r="12" {W} opacity=".7"/>',
    "bottle": f'<path d="M92 40h16v20l10 14v58a6 6 0 0 1-6 6H88a6 6 0 0 1-6-6V74l10-14z" {W}/><path d="M84 94h32v24H84z" {W} opacity=".7"/>',
    "box": f'<path d="M100 46l40 18v46l-40 18-40-18V64z" {W}/><path d="M60 64l40 18 40-18M100 82v46" {W}/>',
    "loaf": f'<path d="M58 120V92c0-24 18-36 42-36s42 12 42 36v28z" {W}/><path d="M82 72l-6 14M102 70l-6 14M122 74l-6 14" {W} opacity=".7"/>',
    "pastry": f'<path d="M52 110c10-34 30-52 48-52s38 18 48 52c-14-8-24-10-30-6-6-12-30-12-36 0-6-4-16-2-30 6z" {W}/><path d="M86 70l6 30M114 70l-6 30" {W} opacity=".7"/>',
    "candle": f'<path d="M100 40c8 10 8 18 0 24-8-6-8-14 0-24z" {W}/><rect x="74" y="72" width="52" height="62" rx="6" {W}/><path d="M74 86h52" {W} opacity=".7"/>',
    "diffuser": f'<path d="M80 92h40v36a8 8 0 0 1-8 8H88a8 8 0 0 1-8-8z" {W}/><path d="M94 92l-12-50M100 92V40M106 92l12-50" {W}/>',
    "can": f'<ellipse cx="100" cy="56" rx="28" ry="8" {W}/><path d="M72 56v68c0 5 13 9 28 9s28-4 28-9V56" {W}/><path d="M72 80c0 5 13 9 28 9s28-4 28-9" {W} opacity=".7"/>',
    "bar": f'<rect x="62" y="56" width="76" height="76" rx="6" {W}/><path d="M62 81h76M62 106h76M87 56v76M112 56v76" {W} opacity=".7"/>',
    "wedge": f'<path d="M54 120l92-56v56z" {W}/><path d="M54 120h92" {W}/><circle cx="118" cy="104" r="6" {W} opacity=".7"/><circle cx="100" cy="112" r="3" {W} opacity=".7"/>',
    "round": f'<ellipse cx="100" cy="110" rx="46" ry="16" {W}/><path d="M54 110V84c0-9 21-16 46-16s46 7 46 16v26" {W}/><ellipse cx="100" cy="84" rx="46" ry="16" {W} opacity=".7"/>',
    "salami": f'<path d="M58 112c0-30 26-56 60-56 12 0 22 10 22 22 0 34-26 60-60 60-12 0-22-12-22-26z" {W}/><circle cx="96" cy="96" r="4" {W} opacity=".7"/><circle cx="116" cy="82" r="3" {W} opacity=".7"/>',
    "fish": f'<path d="M50 96c18-24 52-30 78-10l20-14v48l-20-14c-26 20-60 14-78-10z" {W}/><circle cx="76" cy="92" r="3" {W}/>',
    "mug": f'<path d="M66 70h56v46a16 16 0 0 1-16 16H82a16 16 0 0 1-16-16z" {W}/><path d="M122 80h8a12 12 0 0 1 0 24h-8" {W}/><path d="M84 44c-6 8 6 12 0 20M102 44c-6 8 6 12 0 20" {W} opacity=".7"/>',
    "leaf": f'<path d="M60 130c0-50 30-80 82-82 0 52-30 82-82 82z" {W}/><path d="M60 130l56-56" {W} opacity=".7"/>',
    "pan": f'<circle cx="88" cy="96" r="34" {W}/><path d="M122 96h34" {W}/><circle cx="88" cy="96" r="20" {W} opacity=".7"/>',
    "plate": f'<circle cx="104" cy="96" r="38" {W}/><circle cx="104" cy="96" r="24" {W} opacity=".7"/><path d="M52 60v24a6 6 0 0 0 12 0V60M58 84v50" {W}/>',
    "gift": f'<rect x="62" y="74" width="76" height="60" rx="4" {W}/><path d="M56 62h88v12H56zM100 62v72" {W}/><path d="M100 62c-8-16-30-16-26-2M100 62c8-16 30-16 26-2" {W}/>',
    "soap": f'<rect x="58" y="78" width="84" height="48" rx="18" {W}/><circle cx="84" cy="62" r="7" {W} opacity=".7"/><circle cx="106" cy="54" r="5" {W} opacity=".7"/><circle cx="122" cy="66" r="4" {W} opacity=".7"/>',
    "card": f'<rect x="64" y="52" width="72" height="82" rx="4" {W}/><path d="M78 74h44M78 90h44M78 106h28" {W} opacity=".7"/>',
    "frame": f'<rect x="60" y="50" width="80" height="86" rx="4" {W}/><rect x="72" y="62" width="56" height="62" {W} opacity=".7"/><path d="M76 116l16-20 12 12 8-8 12 16" {W} opacity=".7"/>',
}


def shade(hex_color: str, factor: float) -> str:
    r, g, b = (int(hex_color[i:i + 2], 16) for i in (1, 3, 5))
    if factor >= 0:
        r, g, b = (round(c + (255 - c) * factor) for c in (r, g, b))
    else:
        r, g, b = (round(c * (1 + factor)) for c in (r, g, b))
    return f"#{r:02x}{g:02x}{b:02x}"


def svg(color: str, shape: str, variant: int) -> str:
    top = shade(color, [0.18, 0.08, 0.28][variant])
    bottom = shade(color, [-0.18, -0.28, -0.10][variant])
    gid = f"hp-{color[1:]}-{shape}-{variant}"
    # The lower third stays calm: NexoPOS overlays the product name there.
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200" width="400" height="400">'
        f'<defs><linearGradient id="{gid}" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{top}"/>'
        f'<stop offset="1" stop-color="{bottom}"/></linearGradient></defs>'
        f'<rect width="200" height="200" fill="url(#{gid})"/>'
        '<circle cx="168" cy="26" r="60" fill="#fff" opacity=".06"/><circle cx="24" cy="180" r="70" fill="#000" opacity=".05"/>'
        f'<g transform="translate(0,-10)">{SHAPES[shape]}</g></svg>\n'
    )


def main() -> None:
    catalog = json.loads((ROOT / "Data" / "catalog.json").read_text(encoding="utf8"))
    (OUT / "categories").mkdir(parents=True, exist_ok=True)
    (OUT / "products").mkdir(parents=True, exist_ok=True)
    for f in (OUT / "products").glob("*.svg"):
        f.unlink()
    for cat in catalog["categories"]:
        key = cat["key"]
        (OUT / "categories" / f"{key}.svg").write_text(svg(COLORS[key], CATEGORY_SHAPE[key], 0), encoding="utf8")
    made = set()
    for key, products in catalog["products"].items():
        for base, form, *_ in products:
            shape = SHAPE_BY_FORM.get(form, CATEGORY_SHAPE[key])
            variant = zlib.crc32(base.encode("utf8")) % 3
            name = f"{key}-{shape}-{variant}.svg"
            if name not in made:
                (OUT / "products" / name).write_text(svg(COLORS[key], shape, variant), encoding="utf8")
                made.add(name)
    print(f"categories: {len(catalog['categories'])}, product artwork files: {len(made)}")
    (ROOT / "Data" / "artwork-shapes.json").write_text(
        json.dumps({"categoryShape": CATEGORY_SHAPE, "shapeByForm": SHAPE_BY_FORM}, indent=1) + "\n", encoding="utf8")


if __name__ == "__main__":
    main()
