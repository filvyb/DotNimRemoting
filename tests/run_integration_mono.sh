#!/usr/bin/env bash
#
# Run the Nim <-> .NET interop integration tests using Mono instead of
# Windows + msbuild (see tests/Dockerfile for the Windows path).
#
# Requires: mono, mcs (Mono C# compiler), nim.
#
# It builds the .NET Lib/Server/Client with mcs and the Nim client/server with
# nim, then exercises both directions:
#   1. Nim client   -> .NET (Mono) server   on port 8080
#   2. .NET (Mono) client -> Nim server      on port 8081
#
# Exits 0 only if both round-trips return the expected echo string.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTNET_DIR="$SCRIPT_DIR/dotnet"
NIM_DIR="$SCRIPT_DIR/nim"
OUT_DIR="$DOTNET_DIR/out"

SERVER_PORT=8080   # .NET (Mono) server, used by direction 1
NIM_PORT=8081      # Nim server, used by direction 2

# Background process IDs, killed on exit.
PIDS=()

cleanup() {
  for pid in "${PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH" >&2; exit 127; }
}

# Wait until a TCP port accepts connections (or time out).
wait_for_port() {
  local port="$1" tries="${2:-15}"
  for ((i = 1; i <= tries; i++)); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
      exec 3>&- 3<&-
      return 0
    fi
    sleep 1
  done
  echo "ERROR: port $port never opened" >&2
  return 1
}

require mono
require mcs
require nim

ulimit -s 65536 2>/dev/null || true

echo "=== Building .NET projects with mcs ==="
mkdir -p "$OUT_DIR"
mcs -target:library -out:"$OUT_DIR/Lib.dll" "$DOTNET_DIR/Lib/IEchoService.cs"
mcs -target:exe -out:"$OUT_DIR/Server.exe" \
  -r:System.Runtime.Remoting.dll -r:"$OUT_DIR/Lib.dll" "$DOTNET_DIR/Server/Program.cs"
mcs -target:exe -out:"$OUT_DIR/Client.exe" \
  -r:System.Runtime.Remoting.dll -r:"$OUT_DIR/Lib.dll" "$DOTNET_DIR/Client/Program.cs"

echo "=== Building Nim binaries ==="
nim c --hints:off -d:nimCallDepthLimit=30000 -o:"$NIM_DIR/client" "$NIM_DIR/client.nim"
nim c --hints:off -d:nimCallDepthLimit=30000 -o:"$NIM_DIR/server" "$NIM_DIR/server.nim"

failures=0

# ---------------------------------------------------------------------------
# Direction 1: Nim client -> .NET (Mono) server
# ---------------------------------------------------------------------------
echo
echo "=== Test 1: Nim client -> .NET (Mono) server (port $SERVER_PORT) ==="
# Program.cs ends with Console.ReadLine(); feed it a never-closing stdin
# (sleep infinity) so it keeps listening instead of hitting EOF and exiting.
( cd "$OUT_DIR" && sleep infinity | mono Server.exe ) >/tmp/mono_server.log 2>&1 &
PIDS+=($!)

if wait_for_port "$SERVER_PORT" && "$NIM_DIR/client"; then
  echo "Test 1: PASS"
else
  echo "Test 1: FAIL"; cat /tmp/mono_server.log >&2
  failures=$((failures + 1))
fi
pkill -f "mono Server.exe" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Direction 2: .NET (Mono) client -> Nim server
# ---------------------------------------------------------------------------
echo
echo "=== Test 2: .NET (Mono) client -> Nim server (port $NIM_PORT) ==="
"$NIM_DIR/server" >/tmp/nim_server.log 2>&1 &
PIDS+=($!)

if wait_for_port "$NIM_PORT" && \
   ( cd "$OUT_DIR" && mono Client.exe "tcp://127.0.0.1:$NIM_PORT/EchoService" ); then
  echo "Test 2: PASS"
else
  echo "Test 2: FAIL"; cat /tmp/nim_server.log >&2
  failures=$((failures + 1))
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "All integration tests passed."
else
  echo "$failures integration test(s) failed." >&2
fi
exit "$failures"
