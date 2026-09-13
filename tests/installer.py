"""Check release installation with local download fixtures."""

import argparse
import hashlib
import os
import pathlib
import subprocess
import tempfile

MOCK_CURL = r'''#!/usr/bin/env python3
import os
import pathlib
import sys
arguments = sys.argv[1:]
scenario = os.environ["FLUX_SCENARIO"]
address = arguments[-1]
expected = os.environ["FLUX_ASSET"]
assert address.startswith("https://github.com/Hexadecimall/Flux/releases/download/v0.3.0/")
assert address.rsplit("/", 1)[1] in (expected, expected + ".sha256")
assert arguments[arguments.index("--proto") + 1] == "=https"
assert arguments[arguments.index("--proto-redir") + 1] == "=https"
if scenario == "downloadFailure" or (scenario == "checksumFailure" and address.endswith(".sha256")):
    sys.exit(22)
fixture = "checksum" if address.endswith(".sha256") else "binary"
pathlib.Path(arguments[arguments.index("--output") + 1]).write_bytes(
    (pathlib.Path(os.environ["FLUX_FIXTURES"]) / fixture).read_bytes())
'''


def exercise(installer, scratch):
    scenarios = ("success", "downloadFailure", "checksumFailure", "mismatch",
                 "invalidChecksum", "smokeFailure", "wrongVersion", "existing")
    platforms = (("Darwin", "arm64", "aarch64-apple-darwin"),
                 ("Darwin", "x86_64", "x86_64-apple-darwin"),
                 ("Linux", "aarch64", "aarch64-unknown-linux-musl"),
                 ("Linux", "x86_64", "x86_64-unknown-linux-musl"))
    cases = [(scenario, *platforms[0]) for scenario in scenarios]
    cases += [("success", *platform) for platform in platforms[1:]]
    cases += [("unsupported", "FreeBSD", "x86_64", "unused"),
              ("unsupported", "Linux", "riscv64", "unused")]
    for scenario, system, machine, target in cases:
        with tempfile.TemporaryDirectory(prefix="flux-installer-", dir=scratch) as temporary:
            root = pathlib.Path(temporary)
            commands = root / "commands"
            commands.mkdir()
            (commands / "curl").write_text(MOCK_CURL)
            (commands / "curl").chmod(0o755)
            (commands / "uname").write_text(
                f'#!/bin/sh\ncase "$1" in -s) echo {system};; -m) echo {machine};; esac\n')
            (commands / "uname").chmod(0o755)
            version = "0.4.0" if scenario == "wrongVersion" else "0.3.0"
            binary = f'#!/bin/sh\necho "Flux {version}"\n'.encode()
            if scenario == "smokeFailure":
                binary += b"exit 19\n"
            (root / "binary").write_bytes(binary)
            checksum = hashlib.sha256(binary).hexdigest()
            if scenario == "mismatch":
                checksum = "0" * 64
            elif scenario == "invalidChecksum":
                checksum = "invalid"
            (root / "checksum").write_text(checksum + "\n")
            prefix = root / "prefix with spaces"
            destination = prefix / "bin/flux"
            if scenario == "existing":
                destination.parent.mkdir(parents=True)
                destination.write_bytes(b"previous installation")
            environment = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ["PATH"],
                               FLUX_SCENARIO=scenario, FLUX_FIXTURES=str(root),
                               FLUX_ASSET="flux-" + target)
            result = subprocess.run(
                ["/bin/sh", str(installer), "-prefix", str(prefix)],
                env=environment, capture_output=True, text=True, timeout=30)
            if scenario == "success":
                assert result.returncode == 0, result.stdout + result.stderr
                assert result.stdout == "Installed flux.\n"
                assert destination.read_bytes() == binary
                assert os.access(destination, os.X_OK)
            else:
                assert result.returncode != 0, scenario
                if scenario == "existing":
                    assert destination.read_bytes() == b"previous installation"
                else:
                    assert not destination.exists(), scenario
            assert not list(prefix.glob("bin/.flux-*")), scenario
            print(f"installer: {scenario} ({system}/{machine}) passed")
    for arguments in (("-prefix",), ("-unknown",), ("-version", "1.10.0"),
                      ("-version", "1.0.10"), ("-version", "../other")):
        result = subprocess.run(["/bin/sh", str(installer), *arguments], capture_output=True)
        assert result.returncode != 0
    print("installer: invalid options passed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("scratch", type=pathlib.Path)
    options = parser.parse_args()
    exercise(pathlib.Path(__file__).resolve().parent.parent / "install.sh", options.scratch.resolve())
