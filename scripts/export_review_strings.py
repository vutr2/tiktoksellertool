#!/usr/bin/env python3
"""Collect every Vietnamese string a seller can read into one reviewable list.

The human wording review blocks submission, and it needs all three sources in
one place: the app's String Catalog, the server's message table, and the rule /
convert message builders. The builders are functions, so this renders them into
real sentences with example figures — a reviewer cannot judge `titleTooLong`,
only "Amazon chỉ cho phép 200 ký tự trong tiêu đề."

Writes a `data.js` that assigns `window.LF_STRINGS`, which the review page
loads. Run it again whenever the wording changes so the page stops being a
snapshot that quietly goes stale.

    python3 scripts/export_review_strings.py --out /tmp/data.js
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "ios/ListingForge/Resources/Localizable.xcstrings"
SERVER = ROOT / "api/src/lib/i18n/vi.ts"

# Which screen a string belongs to, for grouping. A file with no entry here
# groups under its own name rather than disappearing.
SCREENS = {
    "AuthView": "Đăng nhập", "SettingsView": "Cài đặt", "CaptureView": "Chụp ảnh",
    "ProductDetailsView": "Thông tin sản phẩm", "MarketplacesView": "Chọn sàn",
    "ReviewView": "Kiểm tra listing", "ProductsView": "Thư viện sản phẩm",
    "ConvertView": "Chuyển sàn", "PaywallView": "Gói & credit",
    "ScriptsView": "Kịch bản video", "ScriptPlayerView": "Trình phát kịch bản",
    "StudioView": "Studio", "CutoutRefinementView": "Chỉnh ảnh tách nền",
    "AIConsent": "Đồng ý dùng AI", "RootView": "Màn gốc", "MainTabView": "Thanh tab",
    "DemoMode": "Demo (chỉ DEBUG)", "VideoScriptTimeline": "Dòng thời gian kịch bản",
}
# Wording where a mistranslation costs the seller money, data or their account:
# credits and charges, subscriptions, deletion, AI consent, and how to retry.
# Reviewed first, so the riskiest sentences stop blocking submission soonest.
HIGH_RISK_GROUPS = {"Đồng ý dùng AI", "Credit & thanh toán", "Tài khoản", "Gói & credit"}
HIGH_RISK_WORDS = re.compile(
    r"\b(consent|permission|delete|deletion|deleted|refund|purchase|purchases|"
    r"subscription|subscribe|renew|credit|credits|charge|charged|billed|billing|"
    r"cancel|canceled|restore|trial|retry|retried|privacy|terms|report)\b", re.I)


def high_risk(row: dict) -> bool:
    return row["group"] in HIGH_RISK_GROUPS or bool(HIGH_RISK_WORDS.search(row["en"]))


SERVER_SECTIONS = {
    "Authentication and session": "Đăng nhập & phiên", "Account": "Tài khoản",
    "Products": "Sản phẩm", "Capture and upload": "Chụp & tải ảnh",
    "Generation": "Tạo nội dung", "Scripts and Studio": "Kịch bản & Studio",
    "Credits, billing and purchases": "Credit & thanh toán",
    "Reports and conversion": "Báo cáo & chuyển sàn", "Requests": "Yêu cầu",
}


def sid(*parts: str) -> str:
    return hashlib.sha256("\0".join(parts).encode()).hexdigest()[:12]


def interface_strings(objects_dir: pathlib.Path | None) -> list[dict]:
    """Translated catalog entries, grouped by the screen the compiler saw them in."""
    catalog = json.loads(CATALOG.read_text())["strings"]
    where: dict[str, str] = {}
    for path in sorted((objects_dir or pathlib.Path()).glob("*.stringsdata")):
        try:
            data = json.loads(path.read_text())
        except (ValueError, OSError):
            continue
        stem = pathlib.Path(data.get("source", path.name)).stem
        for entries in data.get("tables", {}).values():
            for entry in entries:
                where.setdefault(entry["key"], stem)

    rows = []
    for key, entry in catalog.items():
        unit = entry.get("localizations", {}).get("vi", {}).get("stringUnit", {})
        if unit.get("state") != "translated" or not unit.get("value"):
            continue  # An exemption, recorded on purpose; nothing to review.
        stem = where.get(key, "")
        rows.append({
            "id": sid("ui", key), "surface": "app",
            "group": SCREENS.get(stem, stem or "Khác"),
            "src": f"{stem}.swift" if stem else "Localizable.xcstrings",
            "en": key, "vi": unit["value"],
        })
    return rows


def server_strings() -> list[dict]:
    """The message table, grouped by its own section comments."""
    section, rows = "Khác", []
    for line in SERVER.read_text().splitlines():
        heading = re.match(r"\s*// ──\s*(.+?)\s*─", line)
        if heading:
            section = heading.group(1)
            continue
        pair = re.match(r'^\s*"((?:[^"\\]|\\.)*)":\s*"((?:[^"\\]|\\.)*)",\s*$', line)
        if not pair:
            continue
        en, vi = (p.replace('\\"', '"') for p in pair.groups())
        rows.append({
            "id": sid("srv", en), "surface": "server",
            "group": SERVER_SECTIONS.get(section, section),
            "src": "i18n/vi.ts", "en": en, "vi": vi,
        })
    return rows


def builder_strings() -> list[dict]:
    """Rule and convert messages, rendered with example figures."""
    script = (pathlib.Path(__file__).resolve().parent / "render_rule_messages.mjs")
    out = subprocess.run(
        ["node", "--experimental-strip-types", str(script)],
        cwd=ROOT, capture_output=True, text=True, check=True,
    ).stdout
    rendered = json.loads(out)
    label = {"rules": "Lỗi vi phạm quy tắc", "convert": "Mô tả khi Convert"}
    return [{
        "id": sid("b", r["group"], r["key"]), "surface": "rules",
        "group": label[r["group"]], "src": f"rules/messages.ts · {r['key']}",
        "en": r["en"], "vi": r["vi"],
    } for r in rendered]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=pathlib.Path)
    parser.add_argument("--objects", type=pathlib.Path,
                        help="Build directory holding .stringsdata, for screen grouping.")
    args = parser.parse_args()

    rows = interface_strings(args.objects) + server_strings() + builder_strings()
    for row in rows:
        row["pri"] = 1 if high_risk(row) else 0
    ids = {r["id"] for r in rows}
    if len(ids) != len(rows):
        print("id collision: two strings would share a review slot", file=sys.stderr)
        return 1

    args.out.write_text(
        "window.LF_STRINGS=" + json.dumps(rows, ensure_ascii=False, separators=(",", ":")) + ";\n")
    counts: dict[str, int] = {}
    for row in rows:
        counts[row["surface"]] = counts.get(row["surface"], 0) + 1
    print(f"{len(rows)} strings → {args.out}")
    for surface, n in sorted(counts.items()):
        print(f"  {surface}: {n}")
    print(f"  high risk: {sum(r['pri'] for r in rows)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
