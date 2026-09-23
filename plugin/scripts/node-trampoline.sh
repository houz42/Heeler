#!/bin/sh
# herdr spawns plugin commands with PATH=/usr/bin:/bin:/usr/sbin:/sbin, so
# `node` is usually missing from its spawn env. This trampoline finds a
# real node binary and re-execs the real entrypoint with it.
#
# Resolution order: HEELER_NODE env > plugin node-path override file >
# mise shim (the standard on mise-managed hosts) > ~/.local/bin > Homebrew
# (arm64 + x64) > /usr/bin.
PLUGIN_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ENTRY="$1"; shift
NODE="${HEELER_NODE:-}"
if [ -z "$NODE" ] && [ -f "$PLUGIN_DIR/node-path" ]; then
  P=$(cat "$PLUGIN_DIR/node-path" 2>/dev/null)
  if [ -n "$P" ] && [ -x "$P" ]; then NODE="$P"; fi
fi
if [ -z "$NODE" ]; then
  for c in "$HOME/.local/share/mise/shims/node" "$HOME/.local/bin/node" \
           /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node; do
    if [ -x "$c" ] && "$c" -e 'process.exit(0)' >/dev/null 2>&1; then
      NODE="$c"; break
    fi
  done
fi
if [ -z "$NODE" ]; then
  echo "heeler plugin: no working node found (tried HEELER_NODE, node-path override, mise shim, ~/.local/bin, Homebrew, /usr/bin)" >&2
  exit 127
fi
exec "$NODE" "$PLUGIN_DIR/$ENTRY" "$@"
