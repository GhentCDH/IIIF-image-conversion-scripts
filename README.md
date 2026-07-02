# IIIF image conversion scripts

A small collection of shell scripts that convert source images (typically large
TIFFs) into tiled, multi-resolution formats suitable for serving through a IIIF
image server: **JPEG 2000** (`.jp2`), **High Throughput JPEG 2000 / HTJ2K**
(`.jph`), and **pyramidal TIFF** (`.tif`).

## Layout

- `scripts/` — the standalone file-to-file converters, the shared `common.sh` helper, and `validate_j2k.sh`.
- `convert_folder.sh` — batch/folder converter: walks a source tree, converts images with a chosen **profile**, copies metadata, tracks already-converted files, optional daemon mode.
- `profiles/` — one file per conversion profile (`id` = filename). Each declares an output extension and a command.
- `test/` — `input/` source images, `output/` results, and `run_all_converters.sh` (the batch driver).
- `install.sh` — optional installer that symlinks the converters as `iiif-*` commands.
- `README.md`, `iiif_image_conversion.md` — documentation and notes.

## Requirements

| Tool | Used by | Notes |
|------|---------|-------|
| [`kdu_compress`](https://kakadusoftware.com/) | `kakadu_*` scripts | Kakadu (proprietary) |
| [`grk_compress`](https://github.com/GrokImageCompression/grok) | `grok_*` scripts | Grok (open source) |
| [`vips`](https://www.libvips.org/) | `vips_*` scripts | libvips |
| [`jpylyzer`](https://jpylyzer.openpreservation.org/) | `validate_j2k.sh` | `pipx install jpylyzer` |

Each converter checks that its tool is installed and prints a clear error if not.

## Converter scripts

All converters share the same interface:

```
./scripts/<script>.sh [-v|--verbose] [-h|--help] <input_file> <output_file>
```

- The output **extension is validated** (`.jp2`, `.jph`, or `.tiff`/`.tif`/`.ptif`).
- `--verbose` shows the underlying tool's warnings/progress (suppressed by default).
- Options may appear before or after the filenames.

| Script | Tool | Output | Compression |
|--------|------|--------|-------------|
| `grok_j2k_lossy.sh`        | Grok   | `.jp2` | lossy (irreversible 9-7, ~3 bpp) |
| `grok_j2k_lossless.sh`     | Grok   | `.jp2` | lossless (reversible 5-3) |
| `grok_htj2k_lossless.sh`   | Grok   | `.jph` | lossless HTJ2K |
| `kakadu_j2k_lossy.sh`      | Kakadu | `.jp2` | lossy (~3 bpp) |
| `kakadu_j2k_lossless.sh`   | Kakadu | `.jp2` | lossless |
| `kakadu_htj2k_lossy.sh`    | Kakadu | `.jph` | lossy HTJ2K (~3 bpp) |
| `kakadu_htj2k_lossless.sh` | Kakadu | `.jph` | lossless HTJ2K |
| `vips_ptiff_lossy_jpeg.sh` | vips   | `.tif` | pyramidal TIFF, JPEG Q90 |
| `vips_ptiff_lossless.sh`   | vips   | `.tif` | pyramidal TIFF, Zstandard |

`scripts/common.sh` is a shared helper sourced by every converter (argument parsing,
tool/extension checks, usage). It is not meant to be run directly.

## Batch / folder conversion: `convert_folder.sh`

For converting whole directory trees, `convert_folder.sh` walks a source folder,
converts source images with a chosen **profile**, copies extra files (metadata)
verbatim, and tracks which inputs are already converted so re-runs only do new or
changed work. It can also run as a polling daemon.

```
./convert_folder.sh --profile <id|path> -i <input_dir> -o <output_dir> [options]
```

What it does each run:

1. **Scan** the source tree and build a list of actions (this phase has no side
   effects, so `--simulate` can print exactly what *would* happen).
2. **Process**: create the mirrored output folders, copy metadata files, and convert
   images (in parallel with `--parallel`). Each conversion's output is captured to a
   per-job log so parallel output never interleaves; a summary of OK/failed is printed.

How "already converted" is decided: the profile pins the **output extension**, so the
target name is `image.<ext>` (e.g. `page.tif` → `page.jp2`). A file is skipped when a
non-empty target exists and is newer than the source — unless `--force`.

### Options

| Option | Meaning |
|--------|---------|
| `--profile <id\|path>` | **Required.** Profile id (looked up in `profiles/`) or a path to a profile file. |
| `-i, --input <dir>` | Source directory (walked recursively). |
| `-o, --output <dir>` | Destination directory (structure mirrored). |
| `--convert <exts>` | Comma-separated extensions to convert. Default `tif,tiff,jpg,jpeg,png`. |
| `--copy <exts\|all>` | Comma-separated extensions to copy verbatim, or `all` for every non-converted file. Default `yaml,xml,txt`. (An extension in both `--convert` and `--copy` is converted.) |
| `-f, --force` | Reconvert/recopy even if the target is up to date. |
| `--safe-time <sec>` | Ignore files modified within the last *n* seconds (still being written). Default `30`. |
| `--modified <expr>` | Only consider files modified after this time (anything `date -d` accepts, e.g. `'2 days ago'`). |
| `-j, --parallel <n>` | Max parallel conversions. Default `1`. |
| `-S, --simulate` | Scan only; print the planned actions, change nothing. |
| `--validate` | Validate produced `.jp2`/`.jph` outputs with `validate_j2k.sh`. |
| `--require <name…>` | Only process a folder if it contains one of these filenames. |
| `-d, --daemon` | Loop forever, re-scanning each cycle. |
| `--sleep-time <sec>` | Seconds between daemon cycles. Default `60`. |
| `-v, --verbose` | More logging; echo each conversion's full output. |
| `-l, --list-profiles` | List available profiles (id, extension, command) and exit. |
| `-h, --help` | Show help. |

Examples:

```sh
# Dry run: see what would be converted/copied.
./convert_folder.sh --profile kakadu_j2k_lossy -i ./src -o ./out --simulate

# Convert to lossy JP2, 4 at a time, validating the results.
./convert_folder.sh --profile kakadu_j2k_lossy -i ./src -o ./out -j 4 --validate

# Watch a drop folder, copying alto XML and yaml alongside the images.
./convert_folder.sh --profile grok_j2k_lossless -i ./incoming -o ./iiif \
    --copy xml,yaml -d --sleep-time 30
```

## Conversion profiles

A **profile** is the registration layer `convert_folder.sh` uses to know *what* to run
and *what extension* it produces (so it can name and track targets). It is a small file
in `profiles/` whose filename is the profile id:

```
# profiles/kakadu_j2k_lossy
label   = Kakadu, JPEG 2000 (JP2), lossy (~3 bpp)
ext     = jp2
command = kakadu_j2k_lossy.sh --prepare {in} {out}
```

- `label` — *optional* human-readable summary shown by `--list-profiles` (falls back to
  the command when omitted).
- `ext` — the single output extension the command produces.
- `command` — the conversion command. `{in}` and `{out}` are replaced with the input
  and output paths (quoted automatically). The command may call one of the standalone
  `scripts/*.sh` converters (they're put on `PATH` automatically) **or** any tool
  directly — so a custom one-liner is a valid profile without writing a script:

```
# profiles/my_grok_jp2
ext     = jp2
command = grk_compress -i {in} -o {out} -r 8 -n 7 -c [256,256] -p RPCL -I --plt --tlm
```

`--profile` accepts a bare id (resolved against `profiles/`) or a path to any profile
file. Built-in profiles ship for every standalone converter:

| Profile id | ext |
|------------|-----|
| `kakadu_j2k_lossy`, `kakadu_j2k_lossless` | jp2 |
| `kakadu_htj2k_lossy`, `kakadu_htj2k_lossless` | jph |
| `grok_j2k_lossy`, `grok_j2k_lossless` | jp2 |
| `grok_htj2k_lossless` | jph |
| `vips_ptiff_lossy_jpeg`, `vips_ptiff_lossless` | tif |

The Kakadu profiles include `--prepare` so they accept any input (compressed TIFF, PNG,
JPEG, …); see the Kakadu input-formats note below.

## Helper scripts

- **`test/run_all_converters.sh`** — batch-converts every image in `test/input` with every
  converter, writing `test/output/<image>_<converter>.<ext>` and timing each run.
  ```
  ./test/run_all_converters.sh [--validate] [converter.sh ...]
  ```
  Pass specific converter names to run a subset; `--validate` runs jpylyzer on the
  resulting `.jp2`/`.jph` files afterwards.

- **`validate_j2k.sh`** — validates `.jp2`/`.jph` files with jpylyzer.
  ```
  ./scripts/validate_j2k.sh [file-or-directory ...]
  ```
  Defaults to `test/output`; reports PASS/FAIL per file and exits non-zero on
  any failure.

## Install (optional)

To run the converters from anywhere as commands, symlink them into a bin
directory with `install.sh`. They are installed with an `iiif-` prefix and
hyphenated names, e.g. `scripts/kakadu_j2k_lossy.sh` → `iiif-kakadu-j2k-lossy`,
`scripts/validate_j2k.sh` → `iiif-validate-j2k`, and the batch orchestrator
`convert_folder.sh` → `iiif-convert-folder`.

```sh
./install.sh              # per-user, into ~/.local/bin (no sudo)
./install.sh --global     # system-wide, into /usr/local/bin (may need sudo)
./install.sh --uninstall  # remove the symlinks (add --global to match)
```

This works because each script resolves `common.sh` relative to its real
location, so the symlink runs correctly from anywhere. `common.sh` (sourced
helper) and `run_all_converters.sh` (uses relative paths) are not installed.

The installer only **symlinks** — nothing is copied. In particular `iiif-convert-folder`
finds `scripts/` and `profiles/` relative to its real location in this repo, so **keep
the repo in place** after installing. `profiles/` is not (and need not be) installed:
add custom profiles to this repo's `profiles/` directory, or pass a full path to
`--profile`.

## JPEG 2000 options explained

The JP2/JPH scripts use settings tuned for IIIF tile delivery. The Kakadu and Grok
flags below are equivalent (Grok inherits the OpenJPEG-style CLI):

| Purpose | Kakadu | Grok | Why |
|---------|--------|------|-----|
| Resolution levels | `Clevels=6` | `-n 7` | 6 DWT decompositions → 7 resolutions. For ~11k-px images the coarsest level (~175 px) fits in a single tile, giving a clean thumbnail. |
| Precinct size | `Cprecincts={256,256}` | `-c [256,256]` | Matches the 256×256 tile size the server delivers, so a region request maps directly to precincts. |
| Code-block size | `Cblk={64,64}` | `-b 64,64` | Standard JPEG 2000 code-block size. |
| Progression order | `Corder=RPCL` | `-p RPCL` | Resolution-Position-Component-Layer: low-res data first, ideal for progressive/zoomable delivery. |
| Packet/tile index markers | `ORGgen_plt=yes ORGgen_tlm=8 ORGplt_parts=R` | `--plt --tlm` | PLT (packet-length) and TLM (tile-length) markers let the server seek directly to a tile without scanning the whole codestream. |
| Tile-parts by resolution | `ORGtparts=R` | `--tile-parts R` | Groups the codestream by resolution for efficient partial reads. |
| SOP markers | `Cuse_sop=yes` | `-S` | Start-of-packet markers aid robust random access. |
| Quality layers | `Clayers=1` | (single rate) | One quality layer — sufficient for tile serving. |
| Lossy rate | `-rate 3.0` (≈3 bpp) | `-r 8` (8:1 ratio) | For 8-bit RGB these are equivalent (24 bpp ÷ 8 = 3 bpp). |
| Lossy wavelet | (default 9-7) | `-I` | Irreversible 9-7 transform for lossy encoding. |
| Lossless | `Creversible=yes -rate -` | (no rate, no `-I`) | Reversible 5-3 transform, no rate cap. |
| HTJ2K mode | `Cmodes=HT Cplex=...` | `-M 64` | Enables the High Throughput block coder (faster decode). |

## Note: Grok and lossy HTJ2K

There is no `grok_htj2k_lossy.sh` script. On the tested Grok build, the High
Throughput (HT) block coder **does not apply rate control**: requesting a lossy
target (`-r`/`-q`) with `-M 64` is silently ignored, and the encoder always emits a
near-lossless codestream (verified: `-r 8`, `-r 50`, and no rate flag all produce
the same ~110 MB output). The reason is structural — the HT cleanup pass encodes a
code-block in one shot and offers far fewer truncation points than the standard
arithmetic coder, so Grok's HT path here cannot truncate to a bitrate.

For **lossy** HTJ2K, use **`kakadu_htj2k_lossy.sh`** instead — Kakadu implements
optimized HT truncation (and the `Cplex` complexity constraint) and hits the target
bitrate correctly. Grok is fine for lossless JP2/JPH and lossy JP2.

## Note: Kakadu input formats

The `kdu_compress` demo binary ships with a **simple image reader that only accepts
uncompressed TIFF** (plus BMP/PNM/RAW). Compressed TIFF (LZW, Deflate, JPEG, …) and
other formats (PNG, JPEG, …) are rejected with:

```
Kakadu Error: The simple TIFF file reader in this demo application can only
read uncompressed TIFF files.
```

Grok (`grk_compress`, via libtiff) and vips have no such restriction.

To handle this, the `kakadu_*` scripts accept a **`--prepare`** flag: it transcodes
the input to a temporary uncompressed TIFF via vips, runs the conversion on that, and
deletes the temp file afterwards. Use it when the input is a compressed TIFF or any
non-uncompressed-TIFF format:

```sh
./scripts/kakadu_j2k_lossy.sh --prepare compressed_input.tif output.jp2
```

`--prepare` requires vips and writes a full uncompressed TIFF to the system temp dir
(set `TMPDIR` to relocate it), so only use it when needed. Without `--prepare`, an
unsupported input fails with Kakadu's "uncompressed TIFF only" error. (You can also
pre-convert manually: `vips tiffsave input.tif uncompressed.tif --compression none`.)

## Further reading

### [TIFF Image Encoding: Optimizing for Size, Speed and Quality](https://iipimage.sourceforge.io/2024/12/tiff-image-encoding-optimizing-for-size-speed-and-quality)

- If speed is the main criteria, uncompressed tiled multi-resolution pyramid TIFF is, by far, the fastest solution. For comparison, tile decoding of an optimally encoded HTJ2K JPEG2000 image is about 50x slower than uncompressed tiled multi-resolution pyramid TIFF.  If, however, storage space is an issue and you don’t need compatibility with closed-source software, ZStandard is an excellent choice for lossless compression with both fast decoding and smaller file sizes than both LZW and Deflate.
- For lossy compression, again if compatibility with closed-source software is not an issue, WebP provides a significant improvement in file size over JPEG and even beats lossy JPEG2000 at equivalent levels of quality. Lossy WebP decoding is, however, about 30% slower than JPEG, but is still reasonable and is faster than Deflate.

### [Evaluating HTJ2K as a Drop-In Replacement for JPEG2000 with IIIF](https://journal.code4lib.org/articles/17596)

- The testing clearly shows that tiled multi-resolution pyramid TIFF is the fastest format for IIIF, but it comes at a cost of significantly more storage space compared to both HTJ2K and JP2. For small collections with high visitor traffic, the storage costs for TIFF may potentially be outweighed by the increased performance.
- For users already using JPEG2000, the results show a clear performance advantage to migrating from JP2 (JPEG2000 Part 1) to HTJ2K (JPEG2000 Part 15) for all IIIF requests tested. There is a slight increased storage cost for HTJ2K but the improvement in performance could outweigh the increase.

### [HTJ2K : High-Throughput JPEG2000 Encoding / Decoding Test Results](https://merovingio.c2rmf.cnrs.fr/HTJ2K/)

### [iipsrv 1.3 Changelog](https://iipimage.sourceforge.io/2025/05/iipsrv-1-3)

- Low latency pass through mode: This new functionality allows encoded image tile data to be sent without the need for any encode-decode cycle when no modification of the image data is required. This provides a fast highly efficient path that allows iipsrv to function as a fully dynamic image server, yet with almost the speed and efficiency of static image tiles.
