# plex_compress.sh

A Bash script for compressing large video files (MKV/MP4) in a Plex library using HandBrakeCLI. The script supports both interactive and automatic (cron) mode, and can run in dry-run mode to simulate actions without changing files.

## Features
- **Automatic encoder selection** (x264/x265) based on CPU support
- **Configurable source directory** via flag or environment variable
- **Intelligent dependency checking** - only what's required for the selected mode
- **Interactive mode**: Select files with fzf and see detailed preview
- **Cron/auto mode**: Automatically finds large video files (default: >10GB)
- **Dry-run**: Simulates actions without changing files
- **Detailed progress**: File sizes before/after, savings and statistics
- **Safety checks**: Write access and collision-safe temp files
- **Error handling**: Robust handling with status reports
- **Help system**: Built-in help and usage information

## Dependencies
- HandBrakeCLI
- fzf (interactive mode only)
- mediainfo (interactive mode only)
- numfmt


## Flag Overview

| Flag              | Short version | Function                                                      |
|-------------------|---------------|---------------------------------------------------------------|
| `--dry-run`       | `-d`          | Simulates actions without changing files                      |
| `--interactive`   | `-i`          | Interactive file selection with fzf and preview              |
| `--source DIR`    | `-s DIR`      | Specify source directory (default: /whirlpool/media/data/movies) |
| `--help`          | `-h`          | Show help and usage                                           |

You can combine flags, e.g. run both interactive and dry-run:

```bash
./plex_compress.sh --interactive --dry-run --source /my/movie/folder
```

## Usage
```bash
./plex_compress.sh [OPTIONS]
```

See the table above for details about individual flags.

## Examples
- Automatic compression of large files:
  ```bash
  ./plex_compress.sh
  ```
- Interactive file selection:
  ```bash
  ./plex_compress.sh --interactive
  ```
- Simulation with different directory:
  ```bash
  ./plex_compress.sh --dry-run --source /my/video/folder
  ```
- Combination of options:
  ```bash
  ./plex_compress.sh --interactive --dry-run --source /test
  ```

## Environment Variables
- `SOURCE_DIR` (path): Override default source directory
- `ENCODER` (x264/x265): Override automatic encoder selection
- `Q` (quality): Override default quality (lower = better quality, larger file)
- `EPRESET` (HandBrake preset): Override preset (e.g. fast, medium)

## Typical Workflow
1. Script checks for required programs.
2. Selects encoder based on CPU or ENV.
3. Finds relevant video files (interactive or automatic).
4. For each file:
   - Checks write access and if output already exists
   - Runs HandBrakeCLI with selected parameters
   - On success: deletes original and saves new file
   - On error: original is kept

## Error Handling
- Missing dependencies stops the script
- Missing write access gives message to run with sudo
- Output file exists: file is skipped

## Author
- k-dannemand

---

*See the script for more details and customizations.*
