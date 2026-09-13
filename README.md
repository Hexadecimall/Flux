# Flux

Flux is a build system written in Zig with declarative configuration, parallel
C/C++ compilation, and content-based incremental rebuilds.

The current implementation builds executables and static libraries with Clang,
GCC, Zig, or a custom compiler definition. Dependency downloads, installation
manifests, and function-level recompilation are not implemented.

## Commands

```text
flux init
flux check
flux build -profile release -jobs 8
flux build -target x86_64-unknown-linux-musl
flux run "Hello" -- argument
flux test
flux clean
```

`init` creates a starter `Build.flx` without overwriting existing configuration.
`check` checks syntax; `build` validates the supported configuration and builds.
`run` builds an executable and forwards arguments and its exit status. `test`
builds and executes targets declared with the `test` kind.

Outputs are stored under `build/<target-triple>/<profile>/out/`. Compiler caches
and temporary files stay under `build/.flux/`. `clean` removes marked generated
profile directories and retains compiler caches.

Each source file has an independent object cache. A fresh compiler dependency
scan detects header changes, including newly resolved includes. The cache hashes
dependency contents, compiler version, arguments, environment, and object contents.
Unchanged objects are reused; unchanged link inputs and outputs skip linking.
Adding a source does not rename existing objects. Compilation is bounded by
`-jobs` (default 4), and a process lock prevents competing writers.

The current cache granularity is a C/C++ translation unit. Editing one function
recompiles its source file and any affected dependents, not individual functions.
Dependency preprocessing and content checks still run during a no-change build.

## Installing Flux

`./install.sh` downloads a binary from `Hexadecimall/Flux` releases for the host
OS and architecture, verifies its SHA-256 checksum, and installs to `/usr/local/bin`.

```sh
./install.sh -prefix "$INSTALL_PREFIX" -version 0.2.0
```

An existing installation is not replaced. Supported targets are macOS and Linux
on aarch64 and x86_64. Release tags use `v<version>`; each release must contain
`flux-<architecture>-apple-darwin` or `flux-<architecture>-unknown-linux-musl`
and a matching `.sha256` file. The default version is 0.2.0.

## Building Flux

Zig 0.16.0 is required. Build and cache locations can be selected explicitly:

```sh
zig build --cache-dir build/bootstrap-cache --global-cache-dir build/global-cache --prefix build/bootstrap
zig build test --cache-dir build/bootstrap-cache --global-cache-dir build/global-cache
python3 -B tests/integration.py build/bootstrap/bin/flux build -compiler clang
python3 -B tests/integration.py build/bootstrap/bin/flux build -compiler zig
```

Flux defaults to ReleaseFast with debug information stripped. Unit tests use
Debug. Integration tests compile real programs and cover incremental source and
header edits, no-change builds, libraries, failed-build recovery, and commands.

## Configuration

`Build.flx` is the project root. `Lockfile.flx` is reserved for dependency locking;
dependency resolution and lockfile generation are not implemented yet.
Other `.flx` files are loaded explicitly with `yoink()`.

```flx
project("Example") {
    language(cxx) {
        compiler(zig)
    }

    target("Hello", executable) {
        source(implementation) {
            "src/*.cpp"
        }

        source(header) {
            "include/*.hpp"
        }
    }
}
```

Unquoted language names select built-in language definitions. Quoted names are
open-ended and can be supplied by custom compiler definitions.

```flx
definition(compiler) {
    name("customCompiler")
    executable("customcc")

    language("customLanguage") {
        implementation(argument(1), "")
        header(argument(2), "-header")
        library(argument(3), "-l {lib}")

        optimization(argument(4)) {
            none("-O0")
            low("-O1")
            medium("-O2")
            high("-O3")
            max("-OMAX")
        }

        output(argument(5), "-o")
    }
}
```

```flx
project("Custom Project") {
    language("customLanguage") {
        compiler("customCompiler")
    }
}
```

Built-in compiler selections are `builtIn`, `gcc`, `clang`, and `zig`.

Custom compiler argument groups are emitted in their declared `argument()`
order. A non-empty template is split into command arguments before its values.
`{lib}` expands once per library. Debug selects `none`; release selects `max`.
The compiler must create the requested output path. Failed invocations retain
the last successful artifact.

Custom-language targets currently invoke their compiler once per target and do
not share the C/C++ translation-unit cache. Mixing custom-language and C/C++
sources in one target is not implemented yet.

`builtIn` currently invokes an installed Zig toolchain. Native macOS Zig C++
links against the runtime discovered in the active SDK. Cross compilation through
Zig accepts canonical vendor-containing triples and translates them for the driver.
GCC cross compilation requires a dedicated driver and is not implemented yet.

Target kinds are `executable`, `staticLibrary`, and `test`. An executable or test
can link a project static library using `use("libraryName")`. Transitive static
library dependencies are not implemented. Target settings also include
`includeDirectory("include")` and `define("FEATURE=1")`.

Source patterns support `*`, `?`, and recursive `**`. `yoink()` resolves filenames
relative to the containing configuration, deduplicates canonical paths, and
rejects cycles. Wildcards in yoink filenames are not implemented yet.

A project can build C and C++ with independent compiler selections and combine
their compiled object files. It can also declare a custom language backed by a
custom compiler definition.

```flx
project("Mixed Languages") {
    language(c) {
        compiler(clang)
    }

    language(cxx) {
        compiler(zig)
    }

    language("customLanguage") {
        compiler("customCompiler")
    }
}
```

## License

Flux is licensed under Apache-2.0.
