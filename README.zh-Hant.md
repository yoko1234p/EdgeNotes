# EdgeNotes

[English](README.md) · [**繁體中文**](README.zh-Hant.md) · [简体中文](README.zh-Hans.md)

![EdgeNotes banner](assets/hero.svg)

![preview](https://img.shields.io/badge/release-0.8.0--preview.1-ffb383?style=flat-square) ![GPLv3](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)

**伸手可及的側邊筆記。** 個人 macOS 工具系列的獨立 App。

## 主要功能

- 從螢幕邊緣開啟筆記，管理資料夾及搜尋卡片。
- 按 Command–V 將圖片貼進文字段落之間。
- 使用範本、標籤、來源連結、常用目的地、文字計算及回收桶。

## 安裝預覽版

從 [Releases](https://github.com/yoko1234p/EdgeNotes/releases/tag/v0.8.0-preview.1) 下載 macOS ZIP，解壓後將 `EdgeNotes.app` 移至「應用程式」。預覽版使用臨時簽署，**未經 Apple 公證**。首次開啟時在 Finder 按右鍵選「開啟」；若系統阻擋，請到「系統設定 → 私隱與保安 → 仍要開啟」核對。只授予所需權限，覆蓋現用版本前先備份本機資料。

## 從原始碼建置

```sh
cd DeskTools
APP_UI_LANGUAGE=zh-Hant swift test -j 4
bash Scripts/build.sh release
```

所需的本機 `Shared/` 套件和建置工具已包含在 repo；建置不會自動安裝或啟動 App。

## 系統要求與限制

macOS 14 或以上；原始碼建置需 Xcode 27／Swift 6 和 Python 3。 筆記存在 ~/Library/Application Support/EdgeNotes/。更改儲存方式前請匯出重要資料。編輯器並非完整富文字或 iCloud 同步工具；計算語法有範圍限制，匯率會顯示更新日期。

## 參與及授權

原創 App 程式碼以 GPL-3.0-only 發布；附帶的第三方及資料授權須各自保留。詳見 [LICENSE](LICENSE)、[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)、[CONTRIBUTING.md](CONTRIBUTING.md) 和 [SECURITY.md](SECURITY.md)。
