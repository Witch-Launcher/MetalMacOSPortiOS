#!/usr/bin/env python3
"""Generate a public Metal SDK availability inventory for macOS and iOS."""

import argparse
import csv
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path

FRAMEWORK = "Metal"


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def sdk_path(name):
    return Path(run("xcrun", "--sdk", name, "--show-sdk-path"))


def headers_path(sdk):
    return sdk / "System/Library/Frameworks" / f"{FRAMEWORK}.framework" / "Headers"


def scan(headers):
    macos_only = []
    reverse = []
    for path in sorted(headers.glob("*.h")):
        for line_number, raw in enumerate(path.read_text(errors="replace").splitlines(), 1):
            text = raw.strip()
            if not text:
                continue
            has_macos = "macos(" in text
            has_ios = "ios(" in text
            unavailable_ios = "API_UNAVAILABLE(ios" in text
            unavailable_macos = "API_UNAVAILABLE(macos" in text
            if unavailable_ios or (has_macos and not has_ios):
                macos_only.append({
                    "header": path.name,
                    "line": line_number,
                    "declaration": text,
                })
            if unavailable_macos or (has_ios and not has_macos):
                reverse.append({
                    "header": path.name,
                    "line": line_number,
                    "declaration": text,
                })
    return macos_only, reverse


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--macos-sdk")
    parser.add_argument("--ios-sdk")
    parser.add_argument("--output-dir", default="docs/generated")
    args = parser.parse_args()

    macos_sdk = Path(args.macos_sdk) if args.macos_sdk else sdk_path("macosx")
    ios_sdk = Path(args.ios_sdk) if args.ios_sdk else sdk_path("iphoneos")
    macos_headers = headers_path(macos_sdk)
    ios_headers = headers_path(ios_sdk)

    macos_only, _ = scan(macos_headers)
    _, reverse = scan(ios_headers)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    document = {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "toolchain": run("xcodebuild", "-version").replace("\n", " "),
        "framework": FRAMEWORK,
        "macOSSDK": str(macos_sdk),
        "iOSSDK": str(ios_sdk),
        "macOSHeaderCount": len(list(macos_headers.glob("*.h"))),
        "iOSHeaderCount": len(list(ios_headers.glob("*.h"))),
        "macOSOnlyDeclarationCount": len(macos_only),
        "reverseDirectionDeclarationCount": len(reverse),
        "macOSOnly": macos_only,
        "reverseDirection": reverse,
    }

    json_path = output_dir / "metal_api_inventory.json"
    csv_path = output_dir / "metal_api_inventory.csv"
    json_path.write_text(json.dumps(document, indent=2) + "\n")

    with csv_path.open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["direction", "header", "line", "declaration"])
        for row in macos_only:
            writer.writerow(["macOS-only", row["header"], row["line"], row["declaration"]])
        for row in reverse:
            writer.writerow(["reverse", row["header"], row["line"], row["declaration"]])

    print(f"macOS-only declarations: {len(macos_only)}")
    print(f"reverse-direction declarations: {len(reverse)}")
    print(json_path)
    print(csv_path)


if __name__ == "__main__":
    main()
