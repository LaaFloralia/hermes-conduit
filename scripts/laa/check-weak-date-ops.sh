#!/bin/bash
# Fails when a Mach-O still links Foundation's `Date.<=` / `Date.>=`.
#
# Xcode 27.2's Foundation adds `static func <= (Date, Date)` and
# `static func >= (Date, Date)` (`$s10Foundation4DateV2leoiySbAC_ACtFZ`,
# `$s10Foundation4DateV2geoiySbAC_ACtFZ`), and a build that calls them carries
# a weak import behind an OS-version check. Mac build 2611021827 stopped at
# pc=0x0 on a MacBook (macOS 27.2) right after that check, at a call to
# `Date.<=`. The app writes those comparisons as `!(b < a)` and `!(a < b)`
# instead; `<` is long-standing Foundation API and is not weak-linked.
#
# Usage:
#   scripts/laa/check-weak-date-ops.sh <Mach-O | .app | .appex>...
#
# A bundle argument is expanded to its main executable. Every architecture
# slice of every binary is checked. Exit 0 = clean, 1 = weak import found,
# 2 = nothing could be read.
set -uo pipefail

# Both the plain function (`...FZ`) and the protocol-witness thunk a client can
# emit (`...FTW`) share this prefix, so match the prefix rather than the exact
# mangling: any import of them is the same weak dependency.
PATTERNS=(
  '\$s10Foundation4DateV2leoi'
  '\$s10Foundation4DateV2geoi'
)

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <Mach-O | .app | .appex>..." >&2
  exit 2
fi

# Expand bundles to the executable inside them. iOS bundles keep it at the
# bundle root, a Mac Catalyst bundle under Contents/MacOS; Info.plist names it.
binaries=()
for input in "$@"; do
  if [ -d "$input" ]; then
    case "$input" in
      *.app|*.appex)
        if [ -f "$input/Contents/Info.plist" ]; then
          plist="$input/Contents/Info.plist"
          root="$input/Contents/MacOS"
        else
          plist="$input/Info.plist"
          root="$input"
        fi
        name=$(plutil -extract CFBundleExecutable raw -o - "$plist" 2>/dev/null)
        [ -n "$name" ] || name=$(basename "$input")
        name=${name%.app}
        name=${name%.appex}
        exe="$root/$name"
        if [ ! -f "$exe" ]; then
          echo "check-weak-date-ops: no executable at $exe" >&2
          exit 2
        fi
        binaries+=("$exe")
        ;;
      *)
        echo "check-weak-date-ops: not an app bundle: $input" >&2
        exit 2
        ;;
    esac
  elif [ -f "$input" ]; then
    binaries+=("$input")
  else
    echo "check-weak-date-ops: missing $input" >&2
    exit 2
  fi
done

# Undefined symbols of one slice, one per line. A self-contained binary has
# none, so empty output with a zero status is a real answer; only a failing
# nm means the file could not be read.
undefined_symbols() {
  local bin="$1" arch="$2"
  if [ -n "$arch" ]; then
    nm -u -arch "$arch" "$bin" 2>/dev/null
  else
    nm -u "$bin" 2>/dev/null
  fi
}

hits=0
checked=0
for bin in "${binaries[@]}"; do
  archs=$(lipo -archs "$bin" 2>/dev/null)
  if [ -z "$archs" ]; then
    # A thin file, or one lipo can't read; nm still has the answer.
    archs="(native)"
  fi
  found_here=0
  for arch in $archs; do
    [ "$arch" = "(native)" ] && arch=""
    symbols=$(undefined_symbols "$bin" "$arch")
    if [ "$?" -ne 0 ]; then
      echo "check-weak-date-ops: cannot read undefined symbols: $bin ${arch:-native}" >&2
      exit 2
    fi
    for pattern in "${PATTERNS[@]}"; do
      matched=$(printf '%s\n' "$symbols" | grep -E -- "$pattern" | head -1)
      if [ -n "$matched" ]; then
        echo "weak Date comparison: $(basename "$bin") [${arch:-native}] $matched"
        found_here=1
      fi
    done
  done
  checked=$((checked + 1))
  if [ "$found_here" -eq 0 ]; then
    echo "ok $(basename "$bin") ($(echo $archs | tr ' ' ','))"
  else
    hits=$((hits + 1))
  fi
done

if [ "$hits" -ne 0 ]; then
  echo "FAIL: $hits of $checked binaries import Date.<= / Date.>= (weak-linked)" >&2
  exit 1
fi
echo "PASS: $checked binaries, no weak Date.<= / Date.>= import"
