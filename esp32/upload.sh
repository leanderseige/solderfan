#!/usr/bin/env bash
set -euo pipefail

find_port() {
  local pattern port

  for pattern in /dev/cu.usbserial-* /dev/cu.SLAB_USBtoUART* /dev/cu.wchusbserial* /dev/cu.usbmodem*; do
    for port in $pattern; do
      if [[ -e "$port" ]]; then
        printf '%s\n' "$port"
        return 0
      fi
    done
  done

  return 1
}

upload() {
  pio run -t upload --upload-port "$PORT"
}

PORT="${1:-}"

if [[ -z "$PORT" ]]; then
  PORT="$(find_port || true)"
fi

if [[ -z "$PORT" ]]; then
  echo "Kein ESP32 USB-Port gefunden."
  echo "Schliesse das Board an und pruefe mit: ls /dev/cu.*"
  exit 1
fi

echo "Upload-Port: $PORT"
echo "Versuche automatischen Upload..."

if upload; then
  exit 0
fi

cat <<'EOF'

Automatischer Upload fehlgeschlagen.

Manueller Bootloader-Modus:
  1. BOOT gedrueckt halten
  2. EN/RESET kurz druecken
  3. BOOT weiter gedrueckt halten
  4. Unten Enter druecken
  5. BOOT loslassen, sobald der Upload startet

EOF

read -r -p "Bereit fuer manuellen Retry? Enter druecken..."
upload
