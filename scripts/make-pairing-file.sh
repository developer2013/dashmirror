#!/bin/bash
# make-pairing-file.sh – puts a Remote Pairing file into DashMirror on your iPhone ("Touch in the car").
#
#   scripts/make-pairing-file.sh                 # iPhone and bundle ID are detected
#   UDID=00008140-… BUNDLE_ID=com.you.dashmirror PMD3=~/venv/bin/pymobiledevice3 scripts/make-pairing-file.sh
#
# Needs: Xcode (devicectl), pymobiledevice3 (`pip install pymobiledevice3`), DashMirror installed on the iPhone,
# and a Remote Pairing between this Mac and the iPhone made by pymobiledevice3. If there is none yet, connect the
# iPhone by cable, unlock it and run once:
#   pymobiledevice3 mounter auto-mount
#   pymobiledevice3 developer core-device get-device-info
#
# The file is a key: whoever has it gets full developer access to that iPhone, also from the same Wi-Fi. This script
# builds it in a private temporary folder, copies it into DashMirror's Documents and deletes the local copy. At its
# next start DashMirror moves it out of Documents (which the Files app shows) into Application Support, with file
# protection and excluded from backups. Never commit or share it.
# It is the same pairing pymobiledevice3 uses (shown as "Mac" under Settings › Privacy & Security › Developer Mode).
set -euo pipefail
cd "$(dirname "$0")/.."

PMD3="${PMD3:-$(command -v pymobiledevice3 || true)}"
if [ -z "$PMD3" ] || [ ! -x "$PMD3" ]; then
    echo "pymobiledevice3 not found. Install it (pip install pymobiledevice3) or set PMD3=/path/to/pymobiledevice3." >&2
    exit 1
fi
# The Python that belongs to pymobiledevice3 (same virtualenv).
PY="$(dirname "$PMD3")/python3"
[ -x "$PY" ] || PY="$(dirname "$PMD3")/python"
[ -x "$PY" ] || { echo "No python next to $PMD3." >&2; exit 1; }

BUNDLE_ID="${BUNDLE_ID:-$(sed -n 's/^DASHMIRROR_BUNDLE_ID *= *//p' Config/Local.xcconfig 2>/dev/null | tail -1)}"
[ -n "$BUNDLE_ID" ] || { echo "No bundle ID: set DASHMIRROR_BUNDLE_ID in Config/Local.xcconfig or BUNDLE_ID=…" >&2; exit 1; }

TMP=$(mktemp -d)
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

# Build pairingFile.plist from pymobiledevice3's Remote Pairing record. Prints the iPhone's UDID.
UDID=$(UDID="${UDID:-}" "$PY" - "$TMP/pairingFile.plist" <<'EOF'
import os, plistlib, sys
from pymobiledevice3.common import get_home_folder
from pymobiledevice3.pair_records import generate_host_id

records = sorted(get_home_folder().glob("remote_*.plist"))
wanted = os.environ.get("UDID")
if wanted:
    records = [r for r in records if r.stem == f"remote_{wanted}"]
if not records:
    sys.exit("No Remote Pairing record found. Connect the iPhone by cable, unlock it and run once:\n"
             "  pymobiledevice3 mounter auto-mount\n  pymobiledevice3 developer core-device get-device-info")
if len(records) > 1:
    sys.exit("Several iPhones paired – choose one with UDID=…: "
             + ", ".join(r.stem.removeprefix("remote_") for r in records))

record = plistlib.loads(records[0].read_bytes())
pairing = {
    "public_key": record["public_key"],
    "private_key": record["private_key"],
    # The identifier this Mac registered with; pymobiledevice3 derives it from the host name.
    "identifier": record.get("host_identifier") or generate_host_id(),
}
old = os.umask(0o077)
with open(sys.argv[1], "wb") as f:
    plistlib.dump(pairing, f, fmt=plistlib.FMT_XML)
os.umask(old)
print(records[0].stem.removeprefix("remote_"))
EOF
)

echo "iPhone $UDID: copying the pairing file into $BUNDLE_ID …"
xcrun devicectl device copy to --device "$UDID" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source "$TMP/pairingFile.plist" --destination Documents/pairingFile.plist >/dev/null
echo "Done. In DashMirror on the iPhone: Touch in the car › Forward touch to the iPhone (or Reconnect)."
