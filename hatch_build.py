"""Build hook: compile the Zig library and put it inside the wheel.

Runs `zig build` (from the `ziglang` PyPI package, so no Zig install is
needed) and adds the shared library next to the Python package. The wheel is
tagged for the platform the library was built for, which is the host unless
`EUSPINOLIA_TARGET` names a Zig target triple — the library links nothing,
not even libc, so every supported wheel can be cross-compiled from one
machine.
"""

from __future__ import annotations

import os
import subprocess
import sys
import sysconfig
from pathlib import Path

from hatchling.builders.hooks.plugin.interface import BuildHookInterface

# Zig target triple -> (wheel platform tag, library file name). The Linux
# tags are honest: the library has no libc dependency, so it runs on any
# glibc or musl system the tag admits. The 32-bit ARM triple spells out the
# hard-float ABI because it decides how f64 arguments are passed, and that
# has to match the armhf Python on Raspberry Pi OS.
TARGETS = {
    "x86_64-linux": ("manylinux2014_x86_64.musllinux_1_1_x86_64", "libeuspinolia.so"),
    "aarch64-linux": ("manylinux2014_aarch64.musllinux_1_1_aarch64", "libeuspinolia.so"),
    "arm-linux-musleabihf": ("manylinux2014_armv7l.musllinux_1_1_armv7l", "libeuspinolia.so"),
    "x86_64-macos": ("macosx_11_0_x86_64", "libeuspinolia.dylib"),
    "aarch64-macos": ("macosx_11_0_arm64", "libeuspinolia.dylib"),
    "x86_64-windows": ("win_amd64", "euspinolia.dll"),
    "aarch64-windows": ("win_arm64", "euspinolia.dll"),
}


def host_library_name() -> str:
    if sys.platform == "win32":
        return "euspinolia.dll"
    if sys.platform == "darwin":
        return "libeuspinolia.dylib"
    return "libeuspinolia.so"


def host_platform_tag() -> str:
    # The same normalisation `wheel` applies to sysconfig's platform string.
    return sysconfig.get_platform().replace("-", "_").replace(".", "_")


def zig_command() -> list[str]:
    try:
        import ziglang  # noqa: F401
    except ImportError:
        return ["zig"]
    return [sys.executable, "-m", "ziglang"]


class ZigBuildHook(BuildHookInterface):
    PLUGIN_NAME = "custom"

    def initialize(self, version: str, build_data: dict) -> None:
        target = os.environ.get("EUSPINOLIA_TARGET")
        if target:
            if target not in TARGETS:
                raise ValueError(
                    f"EUSPINOLIA_TARGET={target!r} is not one of: {', '.join(TARGETS)}"
                )
            platform_tag, library = TARGETS[target]
        else:
            platform_tag, library = host_platform_tag(), host_library_name()

        prefix = Path(self.root) / "build" / f"zig-{target or 'host'}"
        command = zig_command() + [
            "build",
            "-Doptimize=ReleaseSafe",
            "-Dstrip=true",
            "--prefix",
            str(prefix),
        ]
        if target:
            command.append(f"-Dtarget={target}")
        subprocess.run(command, cwd=self.root, check=True)

        # Zig installs DLLs under bin/ and everything else under lib/.
        built = next(p for p in (prefix / "lib" / library, prefix / "bin" / library) if p.is_file())

        build_data["pure_python"] = False
        build_data["tag"] = f"py3-none-{platform_tag}"
        build_data["force_include"][str(built)] = f"euspinolia/{library}"
