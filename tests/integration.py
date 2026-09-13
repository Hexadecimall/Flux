"""Exercise real compiler invocations and incremental invalidation."""

import argparse
import pathlib
import subprocess
import tempfile


def exercise(binary, scratch, compiler):
    with tempfile.TemporaryDirectory(prefix="flux-integration-", dir=scratch) as temporary:
        project = pathlib.Path(temporary)
        source = project / "source"
        source.mkdir()
        headers = project / "include"
        headers.mkdir()
        config = project / "Build.flx"
        config.write_text('''project("Mixed Project") {
    language(c) { compiler(COMPILER) }
    language(cxx) { compiler(COMPILER) }
    target("hello world", executable) {
        source(implementation) { "source/**/*.c" "source/**/*.cpp" }
        source(header) { "include/*.h" }
    }
}
'''.replace("COMPILER", compiler))
        header = headers / "value.h"
        header.write_text("#define VALUE 42\n")
        implementation = source / "value.c"
        implementation.write_text('#include "value.h"\nint value(void) { return VALUE; }\n')
        independent = source / "independent.c"
        independent.write_text("int independent(void) { return 1; }\n")
        main_source = source / "main file.cpp"
        initial_main = '''#include <stdio.h>
extern "C" int value(void);
int main() { printf("value=%d\\n", value()); return 0; }
'''
        main_source.write_text(initial_main)

        def invoke(*arguments, success=True):
            result = subprocess.run([str(binary), *arguments], cwd=project,
                                    text=True, capture_output=True, timeout=120)
            output = result.stdout + result.stderr
            if success and result.returncode != 0:
                raise AssertionError(output[-8000:])
            if not success and result.returncode == 0:
                raise AssertionError("expected failure")
            return output

        initial = invoke("run", "-jobs", "2")
        assert "value=42" in initial, initial
        assert initial.count("compiled ") == 3, initial
        unchanged = invoke("build", "-jobs", "2")
        assert "compiled " not in unchanged and "up to date:" in unchanged, unchanged
        main_source.write_text(initial_main.replace("value=%d", "edited=%d"))
        edited = invoke("run", "-jobs", "2")
        assert edited.count("compiled ") == 1 and "edited=42" in edited, edited
        header.write_text("#define VALUE 43\n")
        changed_header = invoke("run", "-jobs", "2")
        assert changed_header.count("compiled ") == 1 and "edited=43" in changed_header, changed_header
        artifact = next((project / "build").glob("*/debug/out/hello world"))
        previous = artifact.read_bytes()
        main_source.write_text("this is invalid C++\n")
        invoke("build", success=False)
        assert artifact.read_bytes() == previous, "failed build replaced the working executable"
        main_source.write_text(initial_main)
        recovered = invoke("run")
        assert "value=43" in recovered, recovered
        added = source / "aaa.c"
        added.write_text("int added(void) { return 7; }\n")
        insertion = invoke("build")
        assert insertion.count("compiled ") == 1, insertion
        config.write_text('''project("Library Project") {
    language(c) { compiler(COMPILER) }
    language(cxx) { compiler(COMPILER) }
    target("values", staticLibrary) {
        source(implementation) { "source/*.c" }
        source(header) { "include/*.h" }
    }
    target("hello world", executable) {
        use("values")
        source(implementation) { "source/*.cpp" }
    }
}
'''.replace("COMPILER", compiler))
        library_run = invoke("run")
        assert "value=43" in library_run, library_run
        library_noop = invoke("build")
        assert "compiled " not in library_noop and library_noop.count("up to date:") == 2, library_noop
        invoke("clean")
        assert not artifact.exists(), "clean left generated artifacts behind"
        assert (project / "build/.flux").exists(), "clean removed compiler caches"
        rebuilt = invoke("run")
        assert "value=43" in rebuilt, rebuilt
        saved_config = config.read_text()
        invoke("init", success=False)
        assert config.read_text() == saved_config, "init overwrote a project"
        config.write_text(saved_config.replace('"hello world", executable', '"hello world", test'))
        tested = invoke("test")
        assert "value=43" in tested, tested
        config.write_text('yoink() { "second.flx" }\n')
        (project / "second.flx").write_text('yoink() { "Build.flx" }\n')
        circular = invoke("build", success=False)
        assert "CircularYoink" in circular, circular

        custom_compiler = project / "custom-compiler"
        custom_compiler.write_text('''#!/usr/bin/env python3
import pathlib
import sys
pathlib.Path("custom-arguments.txt").write_text("\\n".join(sys.argv[1:]) + "\\n")
output = pathlib.Path(sys.argv[sys.argv.index("--output") + 1])
output.write_text("#!/bin/sh\\nprintf 'custom-ok\\\\n'\\n")
output.chmod(0o755)
''')
        custom_compiler.chmod(0o755)
        (source / "main.custom").write_text("custom source\n")
        (headers / "api.custom").write_text("custom header\n")
        config.write_text(f'''definition(compiler) {{
    name("customCompiler")
    executable("{custom_compiler}")
    language("customLanguage") {{
        optimization(argument(1)) {{
            none("--debug")
            max("--release")
        }}
        implementation(argument(2), "--sources")
        header(argument(3), "--headers")
        output(argument(4), "--output")
    }}
}}
project("Custom Project") {{
    language("customLanguage") {{ compiler("customCompiler") }}
    target("custom app", executable) {{
        source(implementation) {{ "source/*.custom" }}
        source(header) {{ "include/*.custom" }}
    }}
}}
''')
        custom_run = invoke("run")
        assert "custom-ok" in custom_run, custom_run
        custom_arguments = (project / "custom-arguments.txt").read_text().splitlines()
        assert custom_arguments[:5] == ["--debug", "--sources", "source/main.custom",
                                       "--headers", "include/api.custom"], custom_arguments
        assert custom_arguments[5] == "--output" and custom_arguments[6].endswith(".pending"), custom_arguments
        print(f"{compiler}: incremental edits, libraries, test, clean, init preservation, failure recovery, yoink cycle passed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=pathlib.Path)
    parser.add_argument("scratch", type=pathlib.Path)
    parser.add_argument("-compiler", default="clang")
    arguments = parser.parse_args()
    exercise(arguments.binary.resolve(), arguments.scratch.resolve(), arguments.compiler)
