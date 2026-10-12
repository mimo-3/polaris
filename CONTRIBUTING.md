# Contributing

Issues and pull requests are welcome in English or Japanese. 日本語で書いても大丈夫です。

## Requirements

- macOS 14 or later
- Swift 6, from the Command Line Tools or Xcode
- Python 3, used by the smoke test and `scripts/bundle.sh`

## Opening a pull request

1. For a large change, open an issue first so we can agree on the direction.
2. Fork the repository and create a branch from `main`.
3. Run these and make sure they pass:

   ```sh
   swift build
   make test
   python3 scripts/polaris-backend-smoke.py
   ```

4. If you changed the UI, run `make snapshots` and attach the affected images from `snapshots/` to the pull request.
5. In the pull request, describe what changed, why, and how you checked it.

`make test` fails when no Swift Testing test passes. The smoke test runs the built `polaris-mcp` over stdio and updates one state file from several processes. CI runs the same three commands on macOS for pull requests and pushes to `main`.

Contributions are accepted under the MIT License, the same as the rest of the project.

## Specs

The product spec is in [docs/product.md](docs/product.md) and the screen spec is in [docs/design.md](docs/design.md). Both are written in Japanese. If your change alters behavior described there, update the doc in the same pull request.

## Security issues

Do not report vulnerabilities in a public issue. Follow [SECURITY.md](SECURITY.md) instead.
