# Lectern

*Lectern is a placeholder name.*

A free, open-source PDF reader for the Mac: fast, calm and built for reading. It's meant for people who spend hours in long books, academic papers, manuals and reports, and it aims to feel like a natural part of macOS rather than a document-processing suite.

**Never lose your place.** When you follow a reference, footnote, figure or cross-reference, Lectern lets you preview the destination, or open it beside the page you're on, without leaving where you were reading.

Lectern is a PDF reader first, plus a personal space for highlights and notes. It isn't a tool for creating, converting or managing documents.

## Principles

- **No account,** no subscription, no ads and no paid unlocks.
- **No telemetry.** No analytics, crash reporting or tracking of any kind.
- **No AI features.**
- **Works offline.** Nothing essential needs the internet. The only network use is an update check, which is off unless you turn it on.
- **Your documents stay yours.** Reading never modifies a file, annotations are standard PDF annotations saved only when you save, and reading state stays on your Mac.
- **Sandboxed.** The app runs in the macOS App Sandbox, so a malicious PDF has little to reach.

## Status

**Pre-release.** Lectern is under active development and no release has been published. [docs/progress.md](docs/progress.md) logs each milestone as it lands.

It needs macOS 26 (Tahoe) or later on Apple Silicon.

## Install

See [docs/INSTALL.md](docs/INSTALL.md). Until the first release, building from source is the only route. Releases will be a DMG and a Homebrew cask in our own tap. They aren't signed with an Apple Developer ID, so macOS asks you to allow the app once; INSTALL.md explains how and why.

## Building

Needs Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The Xcode project is generated from `project.yml` and isn't committed.

```sh
xcodegen generate
xcodebuild -project Lectern.xcodeproj -scheme Lectern -configuration Release -derivedDataPath build/DerivedData build
```

The app is at `build/DerivedData/Build/Products/Release/Lectern.app`. You can also open `Lectern.xcodeproj` in Xcode. Library code lives in the local Swift package `Packages/LecternKit`.

**Release packaging.** `scripts/release/build-dmg` builds an ad-hoc signed Release app, checks its signature and packages it as a DMG in `build/release/`, and `scripts/release/verify-dmg` checks that DMG.

## Testing

```sh
scripts/test.sh
```

This regenerates the project and runs the package tests (`swift test`) and the app-hosted tests (`xcodebuild test`) headlessly. Logs go to `build/logs/`.

The save-engine tests check the test corpus in `Tests/Corpus/` with external PDF tools, and `scripts/test.sh` fails if those tools are missing. Set them up once with:

```sh
scripts/corpus/bootstrap
```

It creates a Python virtual environment in `.venv/` and installs the Node tools in `scripts/corpus/`. It expects `qpdf`, `mupdf-tools` and `poppler` from Homebrew. See [Tests/Corpus/README.md](Tests/Corpus/README.md).

## Documentation

| Document | What it covers |
|---|---|
| [docs/product-spec.md](docs/product-spec.md) | What Lectern is for: goals, users, features and acceptance criteria |
| [docs/spec-review.md](docs/spec-review.md) | Open questions raised against the spec |
| [docs/decisions.md](docs/decisions.md) | The product decisions that answer them |
| [docs/architecture.md](docs/architecture.md) | How it's built: engine, structure, storage, build, release and milestones |
| [docs/progress.md](docs/progress.md) | Build log, milestone by milestone |
| [docs/INSTALL.md](docs/INSTALL.md) | Installing, uninstalling and why the app isn't signed |
| [docs/spikes/](docs/spikes/) | Prototype reports: saving (M0a, M4a), PDFKit behaviour (M0b), platform and distribution (M0c) |

## License

[GPL-3.0](LICENSE).
