# Kairos — Twitch Chat Bot (Nim Edition)

srcDir = "src"

author = "kairos"
version = "0.1.0"
description = "Interactive Twitch chat bot with games, trophies and progression system"
license = "MIT"

requires "nim >= 2.0.0"
requires "ws >= 0.5.0"

bin = @["kairos"]

task build, "Build the bot (generates the plugin aggregator first)":
  exec "nim c tools/gen_plugins.nim"
  exec "tools/gen_plugins"
  exec "nim c -d:release src/kairos.nim"

task test, "Run tests":
  exec "sh -c 'for f in tests/test_*.nim; do nim c -r \"$f\" || exit 1; done'"
