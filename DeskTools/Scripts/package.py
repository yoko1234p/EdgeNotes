#!/usr/bin/env python3
"""Package our own Swift executables; no resources are copied from reference apps."""
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

source = Path(sys.argv[1])
versions = {"CaptureText": ("0.9.0", "15"), "DevWorkbench": ("0.6.0", "10"), "EdgeNotes": ("0.8.0", "21")}
available = [('EdgeNotes', 'edgenotes', True)]
requested = sys.argv[3:] or [name for name, _, _ in available]
if any(name not in {item[0] for item in available} for name in requested):
    raise ValueError("Only CaptureText, DevWorkbench and EdgeNotes can be packaged")
for name, scheme, accessory in available:
    if name not in requested:
        continue
    destination = Path("dist") / f"{name}.app"
    if destination.exists():
        shutil.rmtree(destination)
    contents = destination / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Resources").mkdir()
    shutil.copy2(source / name, contents / "MacOS" / name)
    shutil.copy2(Path("dist") / f"{name}.icns", contents / "Resources" / "AppIcon.icns")
    info = {
        "CFBundleName": name, "CFBundleDisplayName": name,
        "CFBundleIdentifier": "local.pakwingho." + scheme,
        "CFBundleExecutable": name, "CFBundlePackageType": "APPL",
        "CFBundleInfoDictionaryVersion": "6.0", "CFBundleShortVersionString": versions[name][0],
        "CFBundleVersion": versions[name][1], "CFBundleDevelopmentRegion": "en",
        "CFBundleIconFile": "AppIcon", "NSPrincipalClass": "NSApplication",
        "LSMinimumSystemVersion": "14.0", "LSUIElement": accessory,
        "NSHighResolutionCapable": True,
        "CFBundleURLTypes": [{"CFBundleURLName": "local.pakwingho." + scheme,
                              "CFBundleURLSchemes": [scheme]}],
        "NSHumanReadableCopyright": "Independent implementation · 2026",
    }
    if name == "CaptureText":
        info["NSScreenCaptureUsageDescription"] = "框選後在此 Mac 辨認螢幕文字。"
        info["CFBundleDocumentTypes"] = [{"CFBundleTypeName": "圖片",
            "LSItemContentTypes": ["public.image"], "CFBundleTypeRole": "Viewer", "LSHandlerRank": "Alternate"}]
    if name == "EdgeNotes":
        info["CFBundleDocumentTypes"] = [{"CFBundleTypeName": "筆記文字草稿",
            "LSItemContentTypes": ["local.pakwingho.edgetext", "local.pakwingho.edgedraft", "public.plain-text", "net.daringfireball.markdown"],
            "CFBundleTypeRole": "Viewer", "LSHandlerRank": "Alternate"}]
        info["UTExportedTypeDeclarations"] = [{"UTTypeIdentifier": "local.pakwingho.edgetext",
            "UTTypeConformsTo": ["public.plain-text"], "UTTypeDescription": "EdgeNotes 文字草稿",
            "UTTypeTagSpecification": {"public.filename-extension": ["edgetext"]}},
            {"UTTypeIdentifier": "local.pakwingho.edgedraft", "UTTypeConformsTo": ["public.json"],
             "UTTypeDescription": "EdgeNotes 收藏草稿", "UTTypeTagSpecification": {"public.filename-extension": ["edgedraft"]}}]
    if name == "DevWorkbench":
        resources = source / "DeskTools_WorkbenchCore.bundle"
        if not resources.is_dir():
            raise FileNotFoundError(f"Missing offline tool resources: {resources}")
        shutil.copytree(resources, contents / "Resources" / resources.name)
        info["NSServices"] = [{
            "NSMenuItem": {"default": "Inspect in DevWorkbench"},
            "NSMessage": "inspectText", "NSPortName": "DevWorkbench",
            "NSSendTypes": ["public.utf8-plain-text", "NSStringPboardType"],
            "NSRequiredContext": {}, "NSTimeout": "3000",
        }]
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    subprocess.run([sys.executable, "../scripts/localization/package-resources.py", str(source), str(destination), "DeskTools_DeskCore"], check=True)
    print(f"Packaged {destination}")
