default:
  just -l

build:
  zig build

release:
  zig build -Doptimize=ReleaseFast

bundle: release
  #!/usr/bin/env bash
  set -euo pipefail
  APP="zig-out/stvt.app"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS"
  mkdir -p "$APP/Contents/Resources"
  cp macos/Info.plist "$APP/Contents/"
  cp macos/stvt.icns "$APP/Contents/Resources/"
  cp zig-out/bin/stvt "$APP/Contents/MacOS/stvt"
  echo "Built $APP"

run:
  zig build run

test:
  zig build test
