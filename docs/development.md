# Development

## Requirements

- Zig 0.16.0 — or none at all: `pip install -e .` fetches it from the
  `ziglang` package on PyPI
- Python 3.9 or newer, with no third-party packages; pandas only for the
  benchmark

## Working on the source

```sh
git clone https://github.com/Huseynteymurzade28/euspinolia
cd euspinolia
zig build                                    # zig-out/lib/libeuspinolia.so
python3 -c "import euspinolia; euspinolia.self_check()"
```

The package finds the library under `zig-out/` when imported from a
checkout, so there is nothing to install. Set `EUSPINOLIA_LIB` to point at
some other build.

`zig build` produces a **ReleaseSafe** library rather than Zig's usual
Debug default: Debug parses about 12x slower, which would make the library
slower than the `csv` module it is meant to beat. ReleaseSafe keeps the
bounds and overflow checks, which are worth having in code that reads
outside input. Flags:

| | |
|---|---|
| `-Doptimize=ReleaseFast` | drop the safety checks |
| `-Doptimize=Debug` | while working on the Zig side; the test suite already uses this |
| `-Dstrip=true` | omit debug info; 3.7 MB becomes 0.5 MB, and the wheels are built this way |
| `-Dtarget=aarch64-macos` | cross-compile; see [Wheels](#wheels) |

## Tests

```sh
zig build test --summary all                # Zig unit tests, ~110
python3 -m unittest discover -s tests -v    # Python-side tests, ~115
```

The Zig tests run under `DebugAllocator`, so a leaked allocation fails the
suite. The Python tests cover the whole public API plus memory ownership:
frames closed while columns are still alive, columns of closed frames,
zero-copy views, and so on. `tests/test_ffi.py` checks the bridge itself
and the tag numbers shared between `src/ffi.zig` and `euspinolia/_ffi.py`.

CI (`.github/workflows/ci.yml`) runs both suites on Linux, macOS and
Windows under Python 3.9 and 3.13, then builds every wheel and installs
each on its native runner.

## Layout

```
build.zig               shared library build definition
src/root.zig            module roots and the bridge smoke-test exports
src/csv.zig             CSV scanner and the row-major Table
src/dtype.zig           column type inference
src/frame.zig           columnar DataFrame and the conversion into it
src/agg.zig             reductions over a single column
src/filter.zig          row selection by comparing a column against a value
src/groupby.zig         hash the keys of one column, reduce others per group
src/write.zig           serialise a frame back to CSV
src/ffi.zig             the C ABI; every symbol is prefixed with `eus_`
euspinolia/_ffi.py      library discovery, loading, ctypes signatures
euspinolia/__init__.py  DataFrame, Column, Condition, GroupBy, read_csv
tests/test_ffi.py       bridge tests
tests/test_frame.py     read_csv, indexing, reductions, filtering, groupby,
                        to_csv, memory ownership
bench/make_big.py       writes the 500,000-row CSV the benchmark reads
bench/bench.py          euspinolia vs pandas vs the csv module, as a table
hatch_build.py          build hook: compile with Zig, put the library in the wheel
docs/                   what you are reading
```

## Adding to the ABI

Every function Python calls goes through `src/ffi.zig` and is declared in
`euspinolia/_ffi.py`. When adding one:

1. Write the Zig function in its module, with tests.
2. Export it from `ffi.zig` following the conventions at the top of that
   file: `eus_` prefix, `i32` status return, out-parameters for results.
   New error kinds get a new `Status` value **appended** to the enum (the
   numbers are the ABI) and a line in `statusFor` and `message`.
3. Declare `argtypes` / `restype` in `_ffi.py`; add the status to `Status`
   there, and to `_STATUS_EXCEPTIONS` if it deserves a specific exception.
4. Wrap it in `__init__.py`, test it in `tests/test_frame.py`, document it
   in `docs/api.md`.

Tag numbers shared by both sides (column types, operators, aggregates) each
have a test pinning them in `ffi.zig`; extend the test if you extend the
enum.

## Wheels

`pyproject.toml` uses hatchling with a custom hook, `hatch_build.py`, that
runs `zig build -Doptimize=ReleaseSafe -Dstrip=true` and adds the shared
library to the wheel next to the Python package. Zig comes from the
`ziglang` build dependency, so building needs nothing but `pip`:

```sh
pip install build
python -m build            # dist/euspinolia-X.Y.Z.tar.gz and a wheel for this machine
```

The library links nothing — not even libc — so it does not care which
system it is loaded on beyond the CPU and the executable format. That
makes every supported wheel buildable from one machine: set
`EUSPINOLIA_TARGET` to a Zig target triple and the hook cross-compiles and
tags the wheel accordingly.

| `EUSPINOLIA_TARGET` | wheel tag |
|---|---|
| `x86_64-linux` | `manylinux2014_x86_64.musllinux_1_1_x86_64` |
| `aarch64-linux` | `manylinux2014_aarch64.musllinux_1_1_aarch64` |
| `x86_64-macos` | `macosx_11_0_x86_64` |
| `aarch64-macos` | `macosx_11_0_arm64` |
| `x86_64-windows` | `win_amd64` |
| `aarch64-windows` | `win_arm64` |

```sh
for t in x86_64-linux aarch64-linux x86_64-macos aarch64-macos x86_64-windows aarch64-windows; do
  EUSPINOLIA_TARGET=$t python -m build --wheel
done
```

`auditwheel show` on the Linux wheel confirms it: "requires no external
shared libraries", consistent with `manylinux_2_5`. Because the package is
pure Python plus one `ctypes` library, the wheels are tagged `py3-none-*`
and work for every Python 3.9+ on the platform.

## Releasing

Releases go to PyPI through GitHub Actions and
[trusted publishing](https://docs.pypi.org/trusted-publishers/), so there
is no token to keep anywhere. One-time setup on PyPI: add a pending
publisher for the `euspinolia` project with owner `Huseynteymurzade28`,
repository `euspinolia`, workflow `ci.yml`, environment `pypi`; and in the
GitHub repository settings create an environment named `pypi`.

Then, for each release:

1. Bump the version in **three** places, which must agree —
   `euspinolia/_ffi.py` (`EXPECTED_VERSION`, which `pyproject.toml` reads),
   `src/root.zig` (`version_string`) and `build.zig.zon`. `self_check()`
   raises if the first two ever differ at runtime.
2. Add a section to `CHANGELOG.md`.
3. Commit, tag and push:

   ```sh
   git tag v0.2.0
   git push origin main v0.2.0
   ```

The `publish` job runs only for a `v*` tag, and only after the test, wheel
and smoke jobs have passed on every platform.
