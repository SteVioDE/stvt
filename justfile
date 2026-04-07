default:
  just -l

build:
  zig build

release:
  zig build -Doptimize=ReleaseFast

run:
  zig build run

test:
  zig build test
