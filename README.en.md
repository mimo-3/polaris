# Polaris

[日本語](README.md)

Polaris is a macOS app that keeps today's most important work in front of everything else on your screen. You write one North Star sentence, put up to three tasks you are working on now in "now", and leave the rest in "later". A mode describes the kind of day, such as a work day, a reading day, or a rest day. Each mode can list apps to avoid, and when one of them comes to the front, the note points you back to your North Star.

The MCP server ships inside the app as `polaris-mcp`. MCP clients such as AI agents can read and write the same state as the app.

The app runs as a small sticky note that floats above all Spaces and full-screen apps, plus a menu bar icon. Shortcuts:

- ⌃⌥P: edit the North Star
- ⌃⌥N: add a task
- ⌃⌥O: interact with the note
- ⌃⌥H: hide
- ⌃⌥T: let clicks pass through

This is a summary. The Japanese [README.md](README.md) and the specs in [docs/product.md](docs/product.md) and [docs/design.md](docs/design.md) have the full details, all in Japanese.

## Build

You need macOS 14 or later and Swift 6 from the Command Line Tools or Xcode. There are no external packages and no Xcode project.

```sh
swift build
make test
make app
open build/Polaris.app
```

`make app` builds `build/Polaris.app` and signs it. Set `SIGNING_IDENTITY` to your signing identity for any build you give to others. Without it the app gets an ad-hoc signature.

## Install and connect MCP

```sh
make install
claude mcp add polaris -- /Applications/Polaris.app/Contents/MacOS/polaris-mcp
```

`make install` copies the new app first and then swaps it with the existing `/Applications/Polaris.app`. If the install fails, the old app stays in place. Your data is not touched.

For other MCP clients, use `/Applications/Polaris.app/Contents/MacOS/polaris-mcp` as the stdio command. In Claude Desktop, the config looks like this:

```json
{
  "mcpServers": {
    "polaris": {
      "command": "/Applications/Polaris.app/Contents/MacOS/polaris-mcp"
    }
  }
}
```

If you set `INSTALL_DIR`, the command becomes `<INSTALL_DIR>/Polaris.app/Contents/MacOS/polaris-mcp`. The swap needs APFS, so `INSTALL_DIR` must be on an APFS volume. To try it without installing, point the client to the absolute path of `.build/debug/polaris-mcp` after `swift build`.

## Updating

Update the app and `polaris-mcp` together, then restart your MCP clients. The current version migrates the state file to schema version 2 on first access, and older versions cannot read it. An old `polaris-mcp` that is still running returns an `unsupportedSchema` error.

The migration also converts date keys that older versions wrote in the Japanese or Buddhist calendar to the Gregorian calendar. Japanese-calendar years are read in the era current at migration time. Keys that cannot be converted are kept as they are.

## Where data is stored

State is stored in `~/.polaris/state.json`. Set `POLARIS_HOME` to an absolute directory path to use a different location. A symlink is fine. The directory it resolves to must be owned by you and must not be writable by group or others. Point the app and `polaris-mcp` to the same location so they share state.

If `state.json` becomes unreadable, use "状態を作り直す" (rebuild state) in the menu bar. Polaris moves the broken file aside and starts fresh, keeping the five newest backups. Backups made by older versions are not deleted.

## Privacy

Polaris makes no network connections. It saves data only in `~/.polaris/state.json` or the `POLARIS_HOME` directory and sends nothing elsewhere. When the frontmost app changes, Polaris checks its bundle ID against the apps to avoid in the current mode. That check happens in memory, and the bundle ID is not saved. Global shortcuts use Carbon's `RegisterEventHotKey`, so Polaris does not need Accessibility permission.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for issues and pull requests. Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md), not in a public issue.

## License

MIT. See [LICENSE](LICENSE).

## For developers

`make app` reads these environment variables:

| Variable | Default |
|---|---|
| `SIGNING_IDENTITY` | ad-hoc signature |
| `BUNDLE_IDENTIFIER` | `dev.mimo.polaris` |
| `VERSION` | `1.0.0` |
| `BUILD_NUMBER` | `git rev-list --count HEAD`, or `1` if that fails |

`make release` builds a signed and notarized `build/Polaris.dmg` and requires a Developer ID Application identity in `SIGNING_IDENTITY`. `make test` fails when no Swift Testing test passes. `python3 scripts/polaris-backend-smoke.py` runs the built `polaris-mcp` over stdio and updates one state file from several processes. CI runs `swift build`, `make test`, and the smoke test on macOS for pull requests and pushes to `main`.

`polaris-mcp` speaks newline-delimited JSON-RPC 2.0 over stdio. It supports MCP protocol versions `2024-11-05` and `2025-06-18` and does not accept batch requests. It provides 20 tools; call `tools/list` for their input schemas. A banner is a short message an MCP client shows on the note with `polaris_nudge`, and it shows the sender as `MCP: <client name>`.

`PolarisCore` is a Swift Package library. The app and `polaris-mcp` read and write state through it. `PolarisStore.changes()` yields `Result<State, Error>`: `.success` for the initial state and each new revision, and `.failure` once when the state cannot be read, while it keeps watching.

The state file format, snapshots, and other details are in the Japanese README.
