#!/usr/bin/env bash
# wire_casette.sh — Mount the Cassette iOS client's music folder into Navidrome
# and trigger a scan so the app can download the matched .lrc lyrics.
#
# What it does:
#   1. Symlinks /Users/even/mine/music/casette under the Navidrome MusicFolder
#      (the scanner follows directory symlinks — scanner.followsymlinks defaults
#      to true, and is set explicitly in navidrome.toml).
#   2. Triggers a scan of the running Navidrome process (SIGUSR1 = incremental
#      scan), or tells you to start it (it scans on startup).
#
# Re-run any time you add more .lrc files. For an ALREADY-scanned song whose
# .lrc you edited, do a FULL rescan instead (see the note at the bottom).
#
# Usage:  bash cassette/wire_casette.sh

set -euo pipefail

MUSIC_FOLDER="/Users/even/Music/Music/Media.localized/Music"
CASETTE="/Users/even/mine/music/casette"
LINK="$MUSIC_FOLDER/casette"

# ---------------------------------------------------------------------------
# 1) Symlink casette into the library (idempotent)
# ---------------------------------------------------------------------------
if [ ! -d "$CASETTE" ]; then
  echo "ERROR: casette folder not found: $CASETTE" >&2
  exit 1
fi

if [ -L "$LINK" ]; then
  echo "Symlink already exists: $LINK -> $(readlink "$LINK")"
elif [ -e "$LINK" ]; then
  echo "ERROR: $LINK exists and is NOT a symlink (refusing to overwrite). Aborting." >&2
  exit 1
else
  ln -s "$CASETTE" "$LINK"
  echo "Created symlink: $LINK -> $CASETTE"
fi

# ---------------------------------------------------------------------------
# 2) Trigger a scan
# ---------------------------------------------------------------------------
# The scanner listens for SIGUSR1 and runs ScanAll(incremental). A new symlinked
# folder is picked up by an incremental scan because its audio files are new.
PID="$(pgrep -f 'navidrome' | head -n1 || true)"
if [ -n "$PID" ]; then
  echo "Navidrome process found (pid $PID) — sending SIGUSR1 to trigger a scan..."
  kill -SIGUSR1 "$PID"
  echo "Scan triggered. Watch the Navidrome log; once it finishes, open the Cassette"
  echo "app and either wait for the cache TTL or tap the refresh (↻) button in the lyrics view."
else
  echo "No running Navidrome process found."
  echo "Start it (it scans on startup):  cd $(dirname "$0")/../apple_navidrome && make dev"
  echo "Or run a standalone full scan once built:  ./navidrome scan --full"
fi

# ---------------------------------------------------------------------------
# Full rescan (for edited .lrc on already-scanned songs)
# ---------------------------------------------------------------------------
# Navidrome only re-extracts lyrics from a .lrc sidecar when it re-imports the
# audio file (full scan, or the audio file's mtime changed). An incremental scan
# will NOT refresh lyrics for songs it already imported. To force that:
#   cd ../apple_navidrome && make stop && make dev      # startup scan re-imports
# or, with a built binary and the server stopped:
#   ./navidrome scan --full
# After the server has the new lyrics, tap the ↻ refresh button in the Cassette
# lyrics view to bypass the app's cache TTL.
echo "Done."
