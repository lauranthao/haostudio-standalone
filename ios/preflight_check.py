#!/usr/bin/env python3
"""Standalone (e) preflight checks for ios/ (run, do not ship-depend)."""
import re, pathlib, json, plistlib

ios = pathlib.Path.home() / "workspace/deploy/standalone-app/ios"
pbx = (ios / "HAoStudio.xcodeproj/project.pbxproj").read_text()

# 1. file refs exist
missing = []
for m in re.finditer(r"(\w+) /\* ([^*]+) \*/ = \{isa = PBXFileReference;.*?path = ([^;]+); sourceTree = \"<group>\";", pbx):
    oid, name, path = m.groups()
    path = path.strip()
    cands = [ios / path, ios / "HAoStudio" / path, ios / "HAoStudioLyrics" / path]
    if not any(c.exists() for c in cands):
        missing.append((name.strip(), path))
print("1. missing file refs:", missing or "NONE")

# 2. Assets
for cj in ["HAoStudio/Assets.xcassets/AppIcon.appiconset/Contents.json",
           "HAoStudio/Assets.xcassets/Logo.imageset/Contents.json"]:
    d = json.loads((ios / cj).read_text())
    imgs = [i.get("filename") for i in d.get("images", []) if i.get("filename")]
    ok = all((ios / cj).parent.joinpath(f).exists() for f in imgs)
    print("2.", cj.split("/")[-2], "images exist:", ok, imgs)

# 3. Info.plist
pl = plistlib.load(open(ios / "HAoStudio/Info.plist", "rb"))
print("3. displayName:", pl.get("CFBundleDisplayName"),
      "| bgModes:", pl.get("UIBackgroundModes"),
      "| arm64:", pl.get("UIRequiredDeviceCapabilities"),
      "| launch:", pl.get("UILaunchStoryboardName"),
      "| URLSchemes:", [u.get("CFBundleURLSchemes") for u in pl.get("CFBundleURLTypes", [])],
      "| URLName:", [u.get("CFBundleURLName") for u in pl.get("CFBundleURLTypes", [])],
      "| ATS arbitrary:", pl.get("NSAppTransportSecurity"),
      "| LiveActivities:", pl.get("NSSupportsLiveActivities"))

# 4. audio session + resume + bridges
vc = (ios / "HAoStudio/ViewController.swift").read_text()
print("4. audio playback:", "setCategory(.playback" in vc,
      "| resumeWebMusicIfNeeded:", "func resumeWebMusicIfNeeded" in vc,
      "| NativeMusicPlayer refs:", vc.count("NativeMusicPlayer.shared"),
      "| __HAO_NATIVE__:", "__HAO_NATIVE__" in vc,
      "| loadFileURL:", "loadFileURL" in vc,
      "| __HAO_TMDB_KEY__:", "__HAO_TMDB_KEY__" in vc)
hosts = re.findall(r'"([a-z0-9.\-]+)"', vc.split("allowedHosts")[1].split("]")[0])
print("   allowlist hosts:", len(hosts), "| has search.cdn.huya.com:", "search.cdn.huya.com" in hosts)

# 5. brace balance
for f in sorted((ios / "HAoStudio").glob("*.swift")) + sorted((ios / "HAoStudioLyrics").glob("*.swift")):
    s = f.read_text()
    flag = "" if s.count("{") == s.count("}") and s.count("(") == s.count(")") else "  <-- MISMATCH"
    print("5.", f.name, "braces", s.count("{"), s.count("}"), "parens", s.count("("), s.count(")"), flag)

# 6. Podfile / lock
print("6. Podfile IJK 0.1.5:", "pod 'IJKMediaFramework', '0.1.5'" in (ios / "Podfile").read_text(),
      "| lock IJK 0.1.5:", "IJKMediaFramework (0.1.5)" in (ios / "Podfile.lock").read_text())

# 7. codemagic.yaml
try:
    import yaml
    y = yaml.safe_load(open(pathlib.Path.home() / "workspace/deploy/standalone-app/codemagic.yaml"))
    print("7. codemagic.yaml parses, workflows:", list(y["workflows"].keys()),
          "| artifacts:", y["workflows"]["ios-unsigned"]["artifacts"])
except ImportError:
    print("7. pyyaml missing — skipped parse check")

# 8. build settings summary
print("8. SWIFT_VERSION:", sorted(set(re.findall(r"SWIFT_VERSION = ([\d.]+)", pbx))),
      "| deploy:", sorted(set(re.findall(r"IPHONEOS_DEPLOYMENT_TARGET = ([\d.]+)", pbx))),
      "| bundle ids:", sorted(set(re.findall(r"com\.haostudio\.[a-z.]+", pbx))),
      "| device family:", sorted(set(re.findall(r"TARGETED_DEVICE_FAMILY = \"([^\"]+)\"", pbx))))
print("   ARCHS/VALID_ARCHS set:", "ARCHS" in pbx, "| armv7 anywhere:", "armv7" in pbx)
