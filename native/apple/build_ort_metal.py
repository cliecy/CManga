#!/usr/bin/env python3
"""Build the pinned native ORT + Dawn Metal XCFramework (no JS or CPU EP fallback).

Invoked automatically by both Podfiles and the standalone macOS CMake target.
All downloads, tools, sources and binaries stay in the ignored repository build/.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ORT_COMMIT = "2e2543fbe9fae542f921d47a72d21d5a4ef0b710"  # official v1.29.0
# cmake/deps.txt in that commit verifies Dawn's source archive by SHA1.
DAWN_COMMIT = "a192e3019a9a20db23329e631328b39b9867049a"  # v20260714.215939
DAWN_ARCHIVE_SHA1 = "3056ed22d1606258ab43221b8c85b55b88614137"
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
CACHE = ROOT / "build" / "apple-ort"


def run(*args, cwd=None, env=None):
    subprocess.run([str(arg) for arg in args], cwd=cwd, env=env, check=True)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("macos", "ios", "all"), default="all")
    parser.add_argument("--jobs", type=int, default=None)
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Apple XCFrameworks require macOS and the full Xcode toolchain")
    memory = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True))
    jobs = args.jobs or max(1, min(os.cpu_count() or 1, 4, memory // (3 * 1024**3)))
    if jobs < 1:
        parser.error("--jobs must be positive")
    CACHE.mkdir(parents=True, exist_ok=True)
    # pod install, CMake and both platforms may request this dependency together.
    with (CACHE / "builder.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        xcode = subprocess.check_output(["xcodebuild", "-version"], text=True).strip()
        identity = {
            "ort": ORT_COMMIT, "dawn": DAWN_COMMIT,
            "dawn_archive_sha1": DAWN_ARCHIVE_SHA1,
            "patch": digest(HERE / "ort-metal.patch"),
            "builder": digest(Path(__file__)),
            "podspec": digest(HERE / "CMangaOnnxRuntime.podspec"),
            "xcode": xcode,
        }
        platforms = ("macos", "ios") if args.platform == "all" else (args.platform,)
        pending = []
        for platform in platforms:
            package = CACHE / platform / "package"
            manifest = package / "build-identity.json"
            if manifest.exists() and json.loads(manifest.read_text()) == identity and (package / "onnxruntime.xcframework" / "Info.plist").exists():
                print(f"Using pinned Metal runtime: {package}", flush=True)
            else:
                pending.append(platform)
        if not pending:
            return
        tools = CACHE / "tools"
        python = tools / "bin" / "python3"
        if not python.exists():
            run(sys.executable, "-m", "venv", tools)
        requirements = ["cmake==3.31.10", "packaging==25.0", "PyYAML==6.0.2"]
        tool_stamp = tools / "cmanga-requirements.json"
        if not tool_stamp.exists() or json.loads(tool_stamp.read_text()) != requirements:
            run(python, "-m", "pip", "install", "--disable-pip-version-check", *requirements)
            tool_stamp.write_text(json.dumps(requirements))
        env = dict(os.environ)
        env["PATH"] = str(tools / "bin") + os.pathsep + env.get("PATH", "")
        env["PYTHONNOUSERSITE"] = "1"
        # Include patch identity in checkout directory: never mutate/reuse a
        # differently patched source tree or reset a developer's checkout.
        source = CACHE / ("source-" + ORT_COMMIT[:12] + "-" + identity["patch"][:12])
        ready = source / ".cmanga-source-ready"
        if not ready.exists():
            if source.exists():
                shutil.rmtree(source)
            run("git", "init", source)
            run("git", "remote", "add", "origin", "https://github.com/microsoft/onnxruntime.git", cwd=source)
            run("git", "fetch", "--depth", "1", "origin", ORT_COMMIT, cwd=source)
            run("git", "checkout", "--detach", "FETCH_HEAD", cwd=source)
            actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
            if actual != ORT_COMMIT:
                raise RuntimeError("ONNX Runtime source identity mismatch")
            run("git", "submodule", "update", "--init", "--recursive", "--depth", "1", cwd=source)
            run("git", "apply", HERE / "ort-metal.patch", cwd=source)
            ready.write_text(ORT_COMMIT)
        for platform in pending:
            output = CACHE / platform
            # A new patched checkout must not reuse a CMake cache whose source
            # directory refers to an older patch. Unchanged slices stay cached.
            work = output / ("build-" + identity["patch"][:12])
            settings = {
                "build_osx_archs": ({"macosx": ["arm64", "x86_64"]} if platform == "macos" else {
                    "iphoneos": ["arm64"], "iphonesimulator": ["arm64", "x86_64"]}),
                "build_params": {
                    "base": [
                        f"--parallel={jobs}", "--use_xcode", "--build_apple_framework",
                        "--use_webgpu=static_lib", "--skip_tests", "--skip_submodule_sync",
                        "--cmake_extra_defines",
                        # Upstream FIND_PACKAGE_ARGS otherwise substitutes host
                        # re2/absl/etc. for the pinned, checksummed sources.
                        "FETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER",
                        "onnxruntime_BUILD_UNIT_TESTS=OFF",
                        "onnxruntime_BUILD_DAWN_SHARED_LIBRARY=OFF",
                        "DAWN_ENABLE_METAL=ON", "DAWN_ENABLE_NULL=OFF",
                        "DAWN_ENABLE_VULKAN=OFF", "DAWN_ENABLE_D3D11=OFF", "DAWN_ENABLE_D3D12=OFF",
                        "DAWN_ENABLE_SWIFTSHADER=OFF", "DAWN_ENABLE_WEBGPU_ON_WEBGPU=OFF",
                        "TINT_BUILD_MSL_WRITER=ON",
                        "CMAKE_POLICY_VERSION_MINIMUM=3.5",
                    ],
                    "macosx": ["--macos=MacOSX", "--apple_deploy_target=13.3"],
                    "iphoneos": ["--ios", "--apple_deploy_target=16.3"],
                    "iphonesimulator": ["--ios", "--apple_deploy_target=16.3"],
                },
            }
            if platform == "ios":
                # ORT's iOS toolchain enables ARC globally, but Dawn's .mm
                # utilities use manual retain/release. ORT explicitly enables
                # ARC on its own Objective-C sources after these base flags.
                settings["build_params"]["base"].append("CMAKE_CXX_FLAGS=-fno-objc-arc")
            output.mkdir(parents=True, exist_ok=True)
            settings_path = output / "build-settings.json"
            settings_path.write_text(json.dumps(settings, indent=2) + "\n")
            run(python, source / "tools/ci_build/github/apple/build_apple_framework.py",
                "--build_dir", work, "--config", "Release", settings_path, env=env)
            assembled = work / "framework_out"
            package = output / "package"
            staging = output / "package-staging"
            if staging.exists():
                shutil.rmtree(staging)
            shutil.copytree(assembled, staging, symlinks=True)
            shutil.copy2(HERE / "CMangaOnnxRuntime.podspec", staging)
            # Preserve upstream notices alongside the vendored static framework.
            shutil.copy2(source / "ThirdPartyNotices.txt", staging)
            shutil.copy2(source / "cmake/deps.txt", staging / "dependencies.txt")
            (staging / "build-identity.json").write_text(json.dumps(identity, indent=2) + "\n")
            if package.exists():
                shutil.rmtree(package)
            staging.rename(package)
            print(f"Built pinned Metal runtime: {package}", flush=True)


if __name__ == "__main__":
    main()
