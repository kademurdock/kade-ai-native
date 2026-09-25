#!/usr/bin/env python3
"""Every painted picture must carry its words (Part 292, the art plan's rule 34).

Fails when an Art* image set in the asset catalog has no entry in
Sources/KadeArtWords.swift, when an entry names a picture that isn't there,
or when a description runs past 40 words or starts with "image of". Runs in
the Codemagic gate beside the speech tests, so a picture without words cannot
reach TestFlight. No Swift needed.
"""
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(REPO, "Sources", "Assets.xcassets")
WORDS = os.path.join(REPO, "Sources", "KadeArtWords.swift")

sets = {name[: -len(".imageset")] for name in os.listdir(ASSETS)
        if name.startswith("Art") and name.endswith(".imageset")}
text = open(WORDS, encoding="utf-8").read()
entries = dict(re.findall(r'^\s*"(Art[A-Za-z0-9]+)": "((?:[^"\\]|\\.)*)",\s*$', text, re.M))

problems = []
for name in sorted(sets - entries.keys()):
    problems.append(f"{name}: picture has no words in KadeArtWords.swift")
for name in sorted(entries.keys() - sets):
    problems.append(f"{name}: words for a picture that is not in the asset catalog")
for name, words in sorted(entries.items()):
    if len(words.split()) > 40:
        problems.append(f"{name}: description is {len(words.split())} words (40 at most)")
    if re.match(r"(?i)\s*(an? )?(image|picture|photo) of\b", words):
        problems.append(f"{name}: description starts with 'image of'")
    if not words.strip():
        problems.append(f"{name}: empty description")

if problems:
    print("\n".join(problems))
    sys.exit(1)
print(f"art check: {len(sets)} pictures, every one has its words")
