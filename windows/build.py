"""Build and package a verified Windows bundle; requires only Python's stdlib."""

import argparse
import hashlib
import platform
import re
import shutil
import struct
import subprocess
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TRANSLATION_URL = (
    "https://raw.githubusercontent.com/kira-96/"
    "Inno-Setup-Chinese-Simplified-Translation/"
    "1ff90acc4ed4aee82b1cda43253243deee3daed4/ChineseSimplified.isl"
)
TRANSLATION_SHA256 = "bf0751fa176569c6faa2f6e17ed2734617bef325d5cc06eae030fdd0258ee778"


def verify_bundle(bundle: Path, arch: str) -> None:
    required = (
        "venera.exe", "flutter_windows.dll", "onnxruntime.dll",
        "onnxruntime_providers_shared.dll", "vcruntime140.dll", "msvcp140.dll",
        "image_ai/directml/onnxruntime.dll",
        "image_ai/directml/onnxruntime_providers_shared.dll",
        "image_ai/directml/DirectML.dll",
        "data/licenses/onnxruntime/LICENSE", "data/licenses/directml/LICENSE.txt",
        "data/licenses/opencv/LICENSE",
    )
    for relative in required:
        if not (bundle / relative).is_file():
            raise RuntimeError(f"Incomplete Windows bundle: missing {relative}")
    expected_machine = {"x64": 0x8664, "arm64": 0xAA64}[arch]
    for binary in bundle.rglob("*"):
        if binary.suffix.lower() not in (".exe", ".dll"):
            continue
        with binary.open("rb") as stream:
            if stream.read(2) != b"MZ":
                raise RuntimeError(f"Invalid PE binary: {binary}")
            stream.seek(0x3C)
            pe_offset = struct.unpack("<I", stream.read(4))[0]
            stream.seek(pe_offset)
            if stream.read(4) != b"PE\0\0":
                raise RuntimeError(f"Invalid PE header: {binary}")
            machine = struct.unpack("<H", stream.read(2))[0]
        if machine != expected_machine:
            raise RuntimeError(
                f"{binary} is machine 0x{machine:04x}, not {arch}; refusing mislabeled package"
            )


def build(arch: str = "x64") -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=("x64", "arm64"), default=arch)
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--zip-only", action="store_true")
    args = parser.parse_args()
    arch = args.arch
    bundle = ROOT / "build" / "windows" / arch / "runner" / "Release"
    if args.verify_only:
        verify_bundle(bundle, arch)
        print(f"Verified {arch} bundle: {bundle}")
        return
    flutter = shutil.which("flutter")
    if not flutter:
        raise RuntimeError("Flutter SDK is not on PATH")
    host_arch = {"amd64": "x64", "x86_64": "x64", "arm64": "arm64", "aarch64": "arm64"}.get(
        platform.machine().lower()
    )
    if host_arch != arch:
        raise RuntimeError(
            f"Flutter 3.41 builds Windows for the host architecture ({host_arch}), not {arch}. "
            f"Use a native {arch} Flutter SDK on {arch} Windows; refusing a mislabeled package."
        )
    subprocess.run(
        [flutter, "build", "windows", "--release"],
        cwd=ROOT, check=True,
    )
    verify_bundle(bundle, arch)
    version_match = re.search(r"^version:\s*([^+\s]+)",
                              (ROOT / "pubspec.yaml").read_text(encoding="utf-8"), re.MULTILINE)
    if not version_match:
        raise RuntimeError("pubspec.yaml has no version")
    version = version_match.group(1)
    suffix = "-arm64" if arch == "arm64" else ""
    archive = ROOT / "build" / "windows" / f"Venera-{version}-windows{suffix}"
    shutil.make_archive(str(archive), "zip", bundle)
    if args.zip_only:
        return
    iscc = shutil.which("iscc")
    if not iscc:
        raise RuntimeError("Inno Setup 6.3+ ISCC is required (or use --zip-only)")
    translation = ROOT / "build" / "windows" / "ChineseSimplified.isl"
    if not translation.exists():
        with urllib.request.urlopen(TRANSLATION_URL, timeout=60) as response:
            content = response.read()
        if hashlib.sha256(content).hexdigest() != TRANSLATION_SHA256:
            raise RuntimeError("Installer translation download checksum mismatch")
        translation.write_bytes(content)
    if hashlib.sha256(translation.read_bytes()).hexdigest() != TRANSLATION_SHA256:
        raise RuntimeError("Cached installer translation checksum mismatch")
    script = ROOT / "windows" / ("build_arm64.iss" if arch == "arm64" else "build.iss")
    subprocess.run(
        [iscc, f"/DMyAppVersion={version}", f"/DRootPath={ROOT}",
         f"/DChineseTranslation={translation}", str(script)], cwd=ROOT, check=True,
    )


if __name__ == "__main__":
    build()
