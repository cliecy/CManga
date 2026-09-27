"""Build native ARM64 binaries; never package an x64 bundle as ARM64."""

from build import build


if __name__ == "__main__":
    build("arm64")
