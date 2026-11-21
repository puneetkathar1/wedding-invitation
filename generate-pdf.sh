#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CHROME_BIN=${CHROME_BIN:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}
OUTPUT=${1:-"$SCRIPT_DIR/WeddingInvitation.pdf"}

if [ ! -x "$CHROME_BIN" ]; then
  printf 'Chrome not found at %s. Set CHROME_BIN to your Chrome executable.\n' "$CHROME_BIN" >&2
  exit 1
fi

case "$OUTPUT" in
  /*) ;;
  *) OUTPUT="$PWD/$OUTPUT" ;;
esac

OUTPUT_DIR=$(dirname -- "$OUTPUT")
if [ ! -d "$OUTPUT_DIR" ]; then
  printf 'Output directory does not exist: %s\n' "$OUTPUT_DIR" >&2
  exit 1
fi

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/wedding-invitation-pdf.XXXXXX")
PROFILE_DIR="$TEMP_DIR/chrome-profile"
TEMP_PDF="$TEMP_DIR/WeddingInvitation.pdf"
TEMP_PAGE="$SCRIPT_DIR/.wedding-invitation-pdf-$$.html"
cleanup() {
  rm -rf "$TEMP_DIR"
  rm -f "$TEMP_PAGE"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

if [ -e "$TEMP_PAGE" ]; then
  printf 'Temporary export page already exists: %s\n' "$TEMP_PAGE" >&2
  exit 1
fi

python3 - "$SCRIPT_DIR/index.html" "$TEMP_PAGE" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]).read_text()

# The downloaded invitation has image data appended to these two image tags.
source, repaired_images = re.subn(
    r'(<img alt="Divya and Harsh" src="[^"]+")/9j/[A-Za-z0-9+/]+={0,2}">',
    r"\1>",
    source,
)
if repaired_images != 2:
    raise SystemExit(f"Expected two invitation photo tags, repaired {repaired_images}.")

source, calendar_links = re.subn(
    r'(<a\b[^>]*\bid="cal"[^>]*\bhref=")[^"]*(")',
    r"\1https://calendar.google.com/calendar/render?action=TEMPLATE&amp;text=Divya%20%26%20Harsh%20Wedding&amp;dates=20270222T133000Z%2F20270222T203000Z&amp;location=Sports%20Club%20Tilhari%2C%20Jabalpur\2",
    source,
    count=1,
)
if calendar_links != 1:
    raise SystemExit("Could not prepare the clickable calendar link for PDF export.")

styles = r"""
<style>
@page { size: 210mm 2260mm; margin: 10mm 12mm 5mm; }
@media print {
  html, body, *, *::before, *::after {
    -webkit-print-color-adjust: exact !important;
    print-color-adjust: exact !important;
  }
  #env, #sc, #up, #mu, #pg, section:has(.scr), section:has(#shr),
  .tl .sp0, .tl .sp1, .tl .fw, .ev2 .nd {
    display: none !important;
  }
  .paper .nm, .pc .sec h2.gv {
    background: none !important;
    background-clip: border-box !important;
    -webkit-background-clip: border-box !important;
    -webkit-text-fill-color: currentColor !important;
    color: var(--rose-deep) !important;
  }
  .tx, .rv, .ev2, .fam > div {
    opacity: 1 !important;
    filter: none !important;
    transform: none !important;
    animation: none !important;
    transition: none !important;
    visibility: visible !important;
  }
  .fam, .fam > div, .ev2, .grp, .calw, .mph, .closing-section {
    break-inside: avoid;
    page-break-inside: avoid;
  }
}
</style>
"""
if source.count("</head>") != 1:
    raise SystemExit("Could not find the document head for PDF-only styles.")
Path(sys.argv[2]).write_text(source.replace("</head>", styles + "</head>", 1))
PY

PAGE_URL=$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).as_uri())' "$TEMP_PAGE")

"$CHROME_BIN" \
  --headless \
  --disable-gpu \
  --disable-extensions \
  --no-first-run \
  --no-default-browser-check \
  --user-data-dir="$PROFILE_DIR" \
  --no-pdf-header-footer \
  --virtual-time-budget=10000 \
  --print-to-pdf="$TEMP_PDF" \
  "$PAGE_URL"

swift -e '
import Darwin
import Foundation
import PDFKit

let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let document = PDFDocument(url: url) else {
    fputs("Could not read the generated PDF.\n", stderr)
    exit(1)
}
guard document.pageCount == 1 else {
    fputs("Expected one long PDF page, got \(document.pageCount) pages.\n", stderr)
    exit(1)
}
let text = document.string ?? ""
guard !text.localizedCaseInsensitiveContains("Counting down"),
      !text.localizedCaseInsensitiveContains("21 Days"),
      !text.localizedCaseInsensitiveContains("until Divya"),
      !text.localizedCaseInsensitiveContains("Share invitation") else {
    fputs("The countdown or share button is still visible in the PDF.\n", stderr)
    exit(1)
}

var hasCalendarLink = false
var hasMapLink = false
for index in 0..<document.pageCount {
    for annotation in document.page(at: index)?.annotations ?? [] {
        guard let action = annotation.action as? PDFActionURL,
              let link = action.url?.absoluteString else { continue }
        hasCalendarLink = hasCalendarLink || link.contains("calendar.google.com")
        hasMapLink = hasMapLink || link.contains("google.com/maps")
    }
}
guard hasCalendarLink && hasMapLink else {
    fputs("The PDF is missing its clickable calendar or map link.\n", stderr)
    exit(1)
}
' "$TEMP_PDF"

mv -f "$TEMP_PDF" "$OUTPUT"
printf 'Created one-page PDF with clickable calendar and map links: %s\n' "$OUTPUT"
