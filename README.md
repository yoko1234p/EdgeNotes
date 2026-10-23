# EdgeNotes

Keep editable notes at the screen edge, with folders, inline images and text calculations.

**文字與筆記系列：側邊筆記、圖片、資料夾、範本與即時計算。** Interfaces support English, Traditional Chinese and Simplified Chinese.

## Features

- Open notes from a screen-edge handle; search folders and cards.
- Paste images with Command–V at the caret, with text before and after them.
- Use templates, tags, source links and favorite destinations.
- Write supported calculation results into note text; manage deleted notes in the app's trash.

## Build and test

Requires macOS 14+, Xcode 27/Swift 6 and Python 3. This repository includes its required shared packages; keep `Shared/` and `scripts/` beside `DeskTools/`.

```sh
cd DeskTools
APP_UI_LANGUAGE=zh-Hant swift test -j 4
bash Scripts/build.sh release
```

The historical package directory is named `DeskTools`, but this repository includes only EdgeNotes and its required shared modules/tests. The app bundle is written to `DeskTools/dist/EdgeNotes.app`. Building does not install or launch it. See [SIGNING.md](SIGNING.md) for ad-hoc development and your own signing identity.

## Use and limitations

Notes are stored under `~/Library/Application Support/EdgeNotes/`. Export important data before testing changes to storage or importing backups. The editor supports a bounded Markdown/inline-image workflow, not full rich-text or iCloud synchronization. Calculations support defined expressions rather than unrestricted natural language; exchange rates show their update date.

## Development and license

This app is under active development. Report the macOS version, reproduction steps and actual validation results with changes. Use synthetic data for file, clipboard and permission tests. Validate interface catalogs from the repository root with `python3 scripts/localization/check-catalogs.py`.

Original maintained code is **GPL-3.0-only**. Keep the separate dependency/data notices listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). See [LICENSE](LICENSE) and [CONTRIBUTING.md](CONTRIBUTING.md).
