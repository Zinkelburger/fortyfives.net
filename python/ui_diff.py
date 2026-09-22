"""Compare two ui_check.py screenshot folders and report what changed.

    python python/ui_diff.py artifacts/ui/base artifacts/ui/new artifacts/ui/diff

For every page whose pixels differ beyond a small tolerance it writes
<page>.png to the diff folder: before | after | changed pixels in magenta.
A table goes to stdout and, in GitHub Actions, the job summary, and each
changed page becomes a warning annotation. Visual changes are often
intentional, so this never fails the build; the invariants in ui_check.py
do that.
"""

import os
import sys
from pathlib import Path

from PIL import Image, ImageChops

# A channel must move by more than this to count as a changed pixel, which
# absorbs anti-aliasing noise between two renders of the same page.
CHANNEL_TOLERANCE = 24
# Pages with less than this fraction of changed pixels are reported as same.
CHANGED_FRACTION = 0.001
GAP = 12


def changed_mask(before: Image.Image, after: Image.Image) -> tuple[Image.Image, float]:
    width = max(before.width, after.width)
    height = max(before.height, after.height)
    canvas_a = Image.new("RGB", (width, height), "black")
    canvas_b = Image.new("RGB", (width, height), "black")
    canvas_a.paste(before, (0, 0))
    canvas_b.paste(after, (0, 0))
    diff = ImageChops.difference(canvas_a, canvas_b).convert("L")
    mask = diff.point(lambda v: 255 if v > CHANNEL_TOLERANCE else 0)
    changed = mask.histogram()[255]
    return mask, changed / (width * height)


def side_by_side(before: Image.Image, after: Image.Image, mask: Image.Image) -> Image.Image:
    highlight = after.copy().convert("RGB")
    overlay = Image.new("RGB", highlight.size, (255, 0, 255))
    highlight.paste(overlay, (0, 0), mask.crop((0, 0, *highlight.size)))
    width = before.width + after.width + highlight.width + 2 * GAP
    height = max(before.height, after.height)
    out = Image.new("RGB", (width, height), (40, 40, 40))
    out.paste(before, (0, 0))
    out.paste(after, (before.width + GAP, 0))
    out.paste(highlight, (before.width + after.width + 2 * GAP, 0))
    return out


def main() -> None:
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    base_dir, new_dir, diff_dir = (Path(arg) for arg in sys.argv[1:])
    diff_dir.mkdir(parents=True, exist_ok=True)

    rows = []
    for new_path in sorted(new_dir.glob("*.png")):
        base_path = base_dir / new_path.name
        page = new_path.stem
        if not base_path.exists():
            rows.append((page, "new page", None))
            continue
        before = Image.open(base_path).convert("RGB")
        after = Image.open(new_path).convert("RGB")
        mask, fraction = changed_mask(before, after)
        if fraction < CHANGED_FRACTION and before.size == after.size:
            rows.append((page, "same", fraction))
            continue
        side_by_side(before, after, mask).save(diff_dir / f"{page}.png")
        rows.append((page, "changed", fraction))

    changed = [row for row in rows if row[1] != "same"]
    lines = ["### UI screenshot diff", ""]
    if changed:
        lines.append(
            f"{len(changed)} of {len(rows)} screenshots changed. Before / after / "
            "changed pixels are in the `ui-screenshots` artifact under `diff/`."
        )
    else:
        lines.append(f"No visual changes across {len(rows)} screenshots.")
    lines += ["", "| Page | Result | Pixels changed |", "|---|---|---|"]
    for page, result, fraction in rows:
        pct = "" if fraction is None else f"{fraction:.2%}"
        lines.append(f"| {page} | {result} | {pct} |")
    report = "\n".join(lines)
    print(report)

    summary = os.getenv("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write(report + "\n")
    if os.getenv("GITHUB_ACTIONS"):
        for page, result, fraction in changed:
            detail = "no baseline" if fraction is None else f"{fraction:.2%} of pixels"
            print(f"::warning title=UI changed: {page}::{result} ({detail}); see the ui-screenshots artifact")


if __name__ == "__main__":
    main()
