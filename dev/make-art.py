#!/usr/bin/env python3
"""Kade's painted pictures -> the app's asset catalog (Part 292, Sep 25 2026).

The originals live in the project folder (art_ready/, 136 MB of 1536 px PNGs,
each with a blind-checked description in art_ready/manifest.json). The app
ships phone-sized copies instead:

  wide rooms   cropped to a band around the picture's subject, 1290 px wide, JPEG
  squares      cards and sleeves 600 px, the radio 800 px, JPEG
  jackets      400 x 600 JPEG
  cut-outs     transparent PNG, 600 px, 256 colours
  app icons    1024 px RGB PNG (no alpha, as Apple requires) + a 180 px thumbnail

and writes Sources/KadeArtWords.swift, the words VoiceOver says for each one.
Every Art* image set must have words there; dev/art-check.py fails the build
otherwise (the plan's rule 34).

Run on kadepc:  python dev/make-art.py "C:\\Users\\KADE\\Desktop\\Kade ai info\\art_ready"
"""
import hashlib
import json
import os
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
ASSETS = os.path.join(REPO, "Sources", "Assets.xcassets")
WORDS = os.path.join(REPO, "Sources", "KadeArtWords.swift")

# asset name, source file, kind, band aspect (width / height) or None, focus (0 top .. 1 bottom)
PICTURES = [
    # The house on the hill: sign-in (by season) and the What's New card.
    ("ArtHouseAtDusk", "house-at-dusk.png", "wide", 2.0, 0.42),
    ("ArtHouseAutumn", "house-autumn-evening.png", "wide", 2.0, 0.44),
    ("ArtHouseWinter", "house-winter-night.png", "wide", 2.0, 0.44),
    ("ArtHouseSpring", "house-spring-morning.png", "wide", 2.0, 0.44),
    ("ArtHouseSummer", "house-summer-night.png", "wide", 2.0, 0.44),
    # Rooms that head a screen.
    ("ArtDescriberBooth", "room-describer-booth.png", "wide", 2.4, 0.40),
    ("ArtSettingsMudroom", "room-settings-mudroom.png", "wide", 2.4, 0.45),
    ("ArtHelpPorch", "room-help-porch.png", "wide", 2.4, 0.50),
    ("ArtTalkKitchen", "room-talk-kitchen-table.png", "wide", 2.2, 0.50),
    ("ArtClubhousePorch", "clubhouse-porch.png", "wide", 2.4, 0.50),
    ("ArtClubhouseMusicNight", "clubhouse-music-night.png", "wide", 2.4, 0.48),
    ("ArtClubhouseGameNight", "clubhouse-game-night.png", "wide", 2.4, 0.55),
    ("ArtClubhouseHotel", "room-clubhouse-hotel.png", "wide", 2.4, 0.45),
    ("ArtClubhouseLounge", "clubhouse-lounge-lamps.png", "wide", 2.4, 0.52),
    ("ArtCastWindows", "cast-five-windows.png", "wide", 2.4, 0.55),
    # Library shelves.
    ("ArtShelfBooks", "shelf-books.png", "wide", 2.4, 0.50),
    ("ArtShelfAudiobooks", "shelf-audiobooks.png", "wide", 2.4, 0.55),
    ("ArtShelfCassettes", "shelf-cassettes.png", "wide", 2.4, 0.50),
    ("ArtShelfFamily", "shelf-family-recordings.png", "wide", 2.4, 0.55),
    ("ArtShelfMissouri", "shelf-missouri.png", "wide", 2.4, 0.50),
    ("ArtShelfMovies", "shelf-described-movies.png", "wide", 2.4, 0.50),
    ("ArtShelfRadio", "shelf-radio.png", "wide", 2.4, 0.50),
    ("ArtShelfMusic", "shelf-music.png", "wide", 2.4, 0.50),
    # Springfield and the Ozarks.
    ("ArtOzarksNews", "ozarks-local-news.png", "wide", 2.4, 0.55),
    ("ArtOzarksWeather", "ozarks-weather.png", "wide", 2.4, 0.45),
    ("ArtOzarksSports", "ozarks-local-sports.png", "wide", 2.4, 0.50),
    ("ArtOzarksCommercials", "ozarks-local-commercials.png", "wide", 2.4, 0.50),
    ("ArtOzarksStationIDs", "ozarks-station-ids.png", "wide", 2.4, 0.45),
    ("ArtOzarksPromos", "ozarks-show-promos.png", "wide", 2.4, 0.50),
    ("ArtOzarksRiver", "ozarks-around-the-ozarks.png", "wide", 2.4, 0.50),
    ("ArtOzarksRadio", "ozarks-local-radio.png", "wide", 2.4, 0.50),
    # Character rooms.
    ("ArtHomeKiana", "kiana-home-banner.png", "wide", 2.4, 0.50),
    ("ArtHomeHarley", "harley-home-banner.png", "wide", 2.4, 0.50),
    ("ArtHomeDella", "della-home-banner.png", "wide", 2.4, 0.50),
    ("ArtHomeLilly", "lilly-home-banner.png", "wide", 2.4, 0.55),
    ("ArtHomeWitherspoon", "witherspoon-home-banner.png", "wide", 2.4, 0.50),
    # Squares. (The nine Sound Booth sleeves wait until the booth knows a
    # song's style on the phone; they are in art_ready.)
    ("ArtCardTalk", "card-talk-telephone.png", "square600", None, None),
    ("ArtCardLibrary", "card-library-books.png", "square600", None, None),
    ("ArtCardBooth", "card-booth-microphone.png", "square600", None, None),
    ("ArtCardWatch", "card-watch-tv.png", "square600", None, None),
    ("ArtCardClubhouse", "card-clubhouse-record.png", "square600", None, None),
    ("ArtCardReverie", "card-reverie-globe.png", "square600", None, None),
    ("ArtNowPlayingRadio", "nowplaying-radio.png", "square800", None, None),
    # Jackets: an item's kind when it has no picture of its own.
    ("ArtJacketAudiobook", "jacket-audiobook.png", "jacket", None, None),
    ("ArtJacketBook", "jacket-book.png", "jacket", None, None),
    ("ArtJacketMovie", "jacket-movie.png", "jacket", None, None),
    ("ArtJacketTV", "jacket-tv.png", "jacket", None, None),
    ("ArtJacketRadio", "jacket-radio.png", "jacket", None, None),
    ("ArtJacketMusic", "jacket-music.png", "jacket", None, None),
    ("ArtJacketCommercials", "jacket-commercials.png", "jacket", None, None),
    # Cut-outs.
    ("ArtEmptyShelf", "empty-shelf.png", "cutout", None, None),
    ("ArtEmptySearch", "empty-search-catalog.png", "cutout", None, None),
    ("ArtEmptyFireside", "empty-clubhouse-fireside.png", "cutout", None, None),
    ("ArtBookCart", "waiting-book-cart.png", "cutout", None, None),
    ("ArtTapeCassette", "tape-cassette-blank-label.png", "cutout", None, None),
    ("ArtTapeVHS", "tape-vhs-blank-label.png", "cutout", None, None),
    ("ArtTapeReel", "tape-reel-box-blank-label.png", "cutout", None, None),
]

# Alternate app icons: the braille K (dots 1 and 3). Settings shows the thumbnail.
ICONS = [
    ("AppIcon-BrailleK", "ArtIconBrailleK", "icon-brass-dots.png"),
    ("AppIcon-Windows", "ArtIconWindows", "icon-lit-windows.png"),
]


def band(im, aspect, focus):
    """Crop the full-width band of the given aspect whose centre sits at `focus`."""
    w, h = im.size
    bh = min(h, round(w / aspect))
    centre = focus * h
    top = int(round(min(max(centre - bh / 2, 0), h - bh)))
    return im.crop((0, top, w, top + bh))


def fit(im, width):
    if im.width <= width:
        return im
    return im.resize((width, round(im.height * width / im.width)), Image.LANCZOS)


def write_set(name, filename, data):
    folder = os.path.join(ASSETS, name + ".imageset")
    os.makedirs(folder, exist_ok=True)
    for old in os.listdir(folder):
        if old != "Contents.json" and old != filename:
            os.remove(os.path.join(folder, old))
    with open(os.path.join(folder, filename), "wb") as f:
        f.write(data)
    contents = {"images": [{"filename": filename, "idiom": "universal"}],
                "info": {"author": "xcode", "version": 1}}
    with open(os.path.join(folder, "Contents.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(contents, f, separators=(",", ":"))


def encode_jpeg(im, quality=80):
    import io
    out = io.BytesIO()
    im.convert("RGB").save(out, "JPEG", quality=quality, optimize=True, progressive=False)
    return out.getvalue()


def encode_png(im, colours=None):
    import io
    out = io.BytesIO()
    if colours:
        im = im.quantize(colors=colours, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.FLOYDSTEINBERG)
    im.save(out, "PNG", optimize=True)
    return out.getvalue()


def swift_string(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main(source):
    manifest = {m["file"]: m for m in json.load(open(os.path.join(source, "manifest.json"), encoding="utf-8"))}
    words = {}
    total = 0
    for name, file, kind, aspect, focus in PICTURES:
        entry = manifest[file]
        im = Image.open(os.path.join(source, file))
        if kind == "wide":
            data = encode_jpeg(fit(band(im.convert("RGB"), aspect, focus), 1290), 78)
            write_set(name, "image.jpg", data)
        elif kind.startswith("square"):
            data = encode_jpeg(fit(im.convert("RGB"), int(kind[6:])), 80)
            write_set(name, "image.jpg", data)
        elif kind == "jacket":
            data = encode_jpeg(im.convert("RGB").resize((400, 600), Image.LANCZOS), 80)
            write_set(name, "image.jpg", data)
        elif kind == "cutout":
            data = encode_png(fit(im.convert("RGBA"), 600), 256)
            write_set(name, "image.png", data)
        else:
            sys.exit("unknown kind " + kind)
        total += len(data)
        text = " ".join(entry["description"].split())
        if len(text.split()) > 40:
            sys.exit(f"{file}: description over 40 words")
        words[name] = text
        print(f"{name:26s} {kind:9s} {len(data) // 1024:5d} KB")
    for icon_set, thumb, file in ICONS:
        entry = manifest[file]
        im = Image.open(os.path.join(source, file)).convert("RGB").resize((1024, 1024), Image.LANCZOS)
        folder = os.path.join(ASSETS, icon_set + ".appiconset")
        os.makedirs(folder, exist_ok=True)
        data = encode_png(im)
        with open(os.path.join(folder, "AppIcon1024.png"), "wb") as f:
            f.write(data)
        contents = {"images": [{"filename": "AppIcon1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
                    "info": {"author": "xcode", "version": 1}}
        with open(os.path.join(folder, "Contents.json"), "w", encoding="utf-8", newline="\n") as f:
            json.dump(contents, f, indent=2)
            f.write("\n")
        small = encode_png(im.resize((180, 180), Image.LANCZOS))
        write_set(thumb, "image.png", small)
        words[thumb] = " ".join(entry["description"].split())
        total += len(data) + len(small)
        print(f"{icon_set:26s} icon      {(len(data) + len(small)) // 1024:5d} KB")
    lines = [
        "// Generated by dev/make-art.py from Kade's art manifest. Do not edit by hand:",
        "// change the description in art_ready/manifest.json and run the script again.",
        "//",
        "// The words VoiceOver says for each painted picture. Each was written by a",
        "// helper who described the finished picture without knowing what it was",
        "// meant to show, then checked against it (Sep 25 2026).",
        "",
        "enum KadeArtWords {",
        "    static let all: [String: String] = [",
    ]
    for name in sorted(words):
        lines.append(f"        {swift_string(name)}: {swift_string(words[name])},")
    lines += ["    ]", "}", ""]
    with open(WORDS, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))
    print(f"{len(words)} pictures, {total / 1e6:.1f} MB added")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else r"C:\Users\KADE\Desktop\Kade ai info\art_ready")
