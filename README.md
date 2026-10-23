# EdgeNotes

[**English**](README.md) · [繁體中文](README.zh-Hant.md) · [简体中文](README.zh-Hans.md)

![EdgeNotes banner](assets/hero.svg)

![preview](https://img.shields.io/badge/release-0.8.0--preview.1-ffb383?style=flat-square) ![GPLv3](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)

**Notes that stay within reach.** A standalone project in the personal macOS tools collection.

## What it does

- Open notes from the screen edge; organize folders and search cards.
- Paste inline images with Command–V between text paragraphs.
- Use templates, tags, source links, favorite destinations, calculations and trash.

## Install a preview

Download the macOS ZIP from [Releases](https://github.com/yoko1234p/EdgeNotes/releases/tag/v0.8.0-preview.1), unzip, and move `EdgeNotes.app` to Applications. This preview uses ad-hoc signing and is **not notarized**. On first launch, use Finder’s **Open** context menu; if macOS blocks it, review **System Settings → Privacy & Security → Open Anyway**. Grant only the permissions you need. Do not install over a working copy without backing up local data.

## Build from source

```sh
cd DeskTools
APP_UI_LANGUAGE=zh-Hant swift test -j 4
bash Scripts/build.sh release
```

The required local `Shared/` packages and build helpers are included. Building does not install or launch the app.

## Requirements and limits

macOS 14+; Xcode 27/Swift 6 and Python 3 for source builds. Notes are stored under ~/Library/Application Support/EdgeNotes/. Export important data before storage changes. The editor is not a full rich-text editor or iCloud sync client; calculation syntax is bounded, and exchange rates have an update date.

## Contribute and license

Original application code is GPL-3.0-only. Keep bundled third-party and data notices; see [LICENSE](LICENSE), [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), [CONTRIBUTING.md](CONTRIBUTING.md), and [SECURITY.md](SECURITY.md).
