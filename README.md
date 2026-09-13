# Flux

Flux is a fast, cross-platform build system with a declarative configuration
language, parallel scheduling, content-addressed caching, and first-class custom
compiler definitions.

## Configuration

`Build.flx` is the project root. `Lockfile.flx` records resolved dependencies.
Other `.flx` files are loaded explicitly with `yoink()`.

```flx
project("Cool Project") {
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
    name("coolDudeCompiler")
    executable("coolcc")

    language("coolLanguage") {
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
    language("coolLanguage") {
        compiler("coolDudeCompiler")
    }
}
```

Built-in compiler selections are `builtIn`, `gcc`, `clang`, and `zig`.

A project may select any number of languages. Each language has an independent
compiler selection, and targets may combine their compiled object files.

```flx
project("Mixed Languages") {
    language(c) {
        compiler(clang)
    }

    language(cxx) {
        compiler(zig)
    }

    language("coolLanguage") {
        compiler("coolDudeCompiler")
    }
}
```

## License

Flux is licensed under Apache-2.0.
