#!/bin/bash

# === Configuration ===
SOURCE_DIR="${SOURCE_DIR:-/whirlpool/media/data/movies}"
DRYRUN=false
INTERACTIVE=false
SIZE_LIMIT="+10G" # Minimum file size for cron/auto mode

# === Functions ===
show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

OPTIONS:
    -d, --dry-run        Simulate actions without changing files
    -i, --interactive    Interactive file selection with fzf and preview
    -s, --source DIR     Specify source directory (default: $SOURCE_DIR)
    -h, --help           Show this help

ENVIRONMENT VARIABLES:
    SOURCE_DIR          Override default source directory
    ENCODER            Override encoder (x264/x265)
    Q                  Override quality (default: auto)
    EPRESET           Override encoder preset (default: fast)

EXAMPLES:
    $0                              # Automatic conversion
    $0 --interactive                # Interactive selection
    $0 --dry-run --source /movies   # Test with different directory
EOF
}

# --- Parameters ---
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--dry-run)
            DRYRUN=true
            echo "=== DRY-RUN mode ==="
            shift
            ;;
        -i|--interactive)
            INTERACTIVE=true
            echo "=== INTERACTIVE mode ==="
            shift
            ;;
        -s|--source)
            SOURCE_DIR="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# === Validation ===
if [ ! -d "$SOURCE_DIR" ]; then
    echo "Error: Source directory '$SOURCE_DIR' does not exist."
    exit 1
fi

# --- Dependency check ---
REQUIRED_DEPS=(HandBrakeCLI)
if [ "$INTERACTIVE" = true ]; then
    REQUIRED_DEPS+=(fzf mediainfo numfmt)
else
    REQUIRED_DEPS+=(numfmt)
fi

for cmd in "${REQUIRED_DEPS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: '$cmd' is not installed."
        echo "For interactive mode requires: HandBrakeCLI, fzf, mediainfo, numfmt"
        echo "For auto mode requires: HandBrakeCLI, numfmt"
        exit 1
    fi
done

# --- Auto-select encoder based on CPU (can be overridden via ENV) ---
if [ -f /proc/cpuinfo ]; then
    CPU_FLAGS=$(grep -m1 -oE 'avx2|fma|sse4_2' /proc/cpuinfo 2>/dev/null | tr '\n' ' ')
    if echo "$CPU_FLAGS" | grep -qi 'avx2'; then
        : "${ENCODER:=x265}"
        : "${Q:=22}"
        : "${EPRESET:=fast}"
    else
        : "${ENCODER:=x264}"
        : "${Q:=20}"
        : "${EPRESET:=fast}"
    fi
else
    # Fallback for systems without /proc/cpuinfo (e.g. macOS)
    echo "Warning: Cannot detect CPU features. Using x264 as default."
    : "${ENCODER:=x264}"
    : "${Q:=20}"
    : "${EPRESET:=fast}"
fi
echo "Encoder selection: $ENCODER (q=$Q, preset=$EPRESET)"

# --- Find files ---
if [ "$INTERACTIVE" = true ]; then
    # Interactive: show all MKV/MP4, sorted by size, preview at bottom
    mapfile -d '' -t SELECTED_FILES < <(
        find "$SOURCE_DIR" -type f \( -iname "*.mkv" -o -iname "*.mp4" \) \
            -printf "%s\t%p\0" |
        sort -z -nr -k1,1 |
        awk -v RS='\0' -F'\t' '{
            cmd="numfmt --to=iec --suffix=B " $1;
            cmd | getline hsize;
            close(cmd);
            printf "%-8s\t%s\0", hsize, $2
        }' |
        fzf --multi --read0 --print0 \
            --delimiter=$'\t' \
            --preview '
                # Extract file path - remove size prefix and quotes
                RAW_INPUT="{}"
                # Remove leading quote if present
                RAW_INPUT=$(echo "$RAW_INPUT" | sed "s/^'"'"'//")
                # Remove trailing quote if present  
                RAW_INPUT=$(echo "$RAW_INPUT" | sed "s/'"'"'$//")
                # Extract everything after the first space (skip size)
                FILE=$(echo "$RAW_INPUT" | sed "s/^[^ ]* //")
                
                echo "Debug - Raw input: {}"
                echo "Debug - After quote removal: $RAW_INPUT"
                echo "Debug - Extracted file path: $FILE"
                echo "---"
                
                if [ -f "$FILE" ]; then
                    echo "📁 File: $FILE"
                    echo "📏 Size: $(stat -c %s "$FILE" 2>/dev/null | numfmt --to=iec --suffix=B 2>/dev/null || echo "Unknown")"
                    echo
                    if command -v mediainfo >/dev/null 2>&1; then
                        mediainfo --Inform="
                            General;🎬 Format: %Format%
                            📊 Bitrate: %OverallBitRate/String%
                            ⏱ Duration: %Duration/String%

                            Video;🎥 Video: %Format% %Width%x%Height% %FrameRate/String%

                            Audio;🔊 Audio: %Format% %Channel\(s\)/String% (%Language%)
                        " "$FILE" 2>/dev/null || echo "Could not read media info"
                    else
                        echo "mediainfo not available"
                    fi
                else
                    echo "File not found: $FILE"
                fi
            ' \
            --preview-window=down:wrap |
        awk -v RS='\0' -v ORS='\0' -F'\t' '{print $2}'
    )
else
    # Cron/auto: only large files
    mapfile -d '' -t SELECTED_FILES < <(
        find "$SOURCE_DIR" -type f \( -iname "*.mkv" -o -iname "*.mp4" \) -size "$SIZE_LIMIT" -print0
    )
fi

# --- If no files found ---
if [ ${#SELECTED_FILES[@]} -eq 0 ]; then
    echo "No files found for conversion in '$SOURCE_DIR'."
    if [ "$INTERACTIVE" != true ]; then
        echo "Tip: Try --interactive to select files manually."
    fi
    exit 0
fi

echo "Found ${#SELECTED_FILES[@]} file(s) for processing."

# --- Process selected files ---
PROCESSED=0
SKIPPED=0
FAILED=0

for FILE in "${SELECTED_FILES[@]}"; do
    [ -f "$FILE" ] || { echo "Skipping: $FILE (not a file)"; ((SKIPPED++)); continue; }

    DIRNAME=$(dirname "$FILE")
    BASENAME=$(basename "$FILE")
    NAME="${BASENAME%.*}"
    OUT_FINAL="$DIRNAME/${NAME}.mp4"
    # Use PID to avoid name collisions
    TEMP_FILE="$DIRNAME/${NAME}_temp_$$.mp4"

    echo ""
    echo "=== File $((PROCESSED + SKIPPED + FAILED + 1))/${#SELECTED_FILES[@]}: $BASENAME ==="

    # Skip if output already exists
    if [ -f "$OUT_FINAL" ]; then
        echo "Skipping: Output already exists ($OUT_FINAL)"
        ((SKIPPED++))
        continue
    fi

    # Check write access (without sudo)
    if [ ! -w "$DIRNAME" ] || [ ! -w "$FILE" ]; then
        echo "Missing write access to '$DIRNAME' or '$FILE'."
        echo "Run instead: sudo -E \"$0\" $([ "$INTERACTIVE" = true ] && echo -i) $([ "$DRYRUN" = true ] && echo -d)"
        ((FAILED++))
        continue
    fi

    if [ "$DRYRUN" = true ]; then
        echo "[DRY-RUN] Would convert: $FILE"
        echo "[DRY-RUN] Would save as: $TEMP_FILE"
        echo "[DRY-RUN] After success: delete original and rename to: $OUT_FINAL"
        ((PROCESSED++))
        continue
    fi

    # Show file size before conversion
    ORIGINAL_SIZE=$(stat -c%s "$FILE" 2>/dev/null || echo "0")
    ORIGINAL_SIZE_H=$(echo "$ORIGINAL_SIZE" | numfmt --to=iec --suffix=B)
    echo "Original size: $ORIGINAL_SIZE_H"
    
    echo "Converting: $FILE"
    echo "Command: HandBrakeCLI -i \"$FILE\" -o \"$TEMP_FILE\" -e $ENCODER -q $Q --encoder-preset $EPRESET --optimize -E ac3 --audio-copy-mask ac3 --audio-fallback ac3"
    
    HandBrakeCLI \
        -i "$FILE" \
        -o "$TEMP_FILE" \
        -e "$ENCODER" -q "$Q" --encoder-preset "$EPRESET" \
        --optimize \
        -E ac3 \
        --audio-copy-mask ac3 \
        --audio-fallback ac3

    HB_STATUS=$?

    # Safety check: only success if exit=0 AND output file exists and has content
    if [ $HB_STATUS -eq 0 ] && [ -s "$TEMP_FILE" ]; then
        # Show size difference
        NEW_SIZE=$(stat -c%s "$TEMP_FILE" 2>/dev/null || echo "0")
        NEW_SIZE_H=$(echo "$NEW_SIZE" | numfmt --to=iec --suffix=B)
        if [ "$ORIGINAL_SIZE" -gt 0 ] && [ "$NEW_SIZE" -gt 0 ]; then
            SAVINGS=$((ORIGINAL_SIZE - NEW_SIZE))
            SAVINGS_H=$(echo "$SAVINGS" | numfmt --to=iec --suffix=B)
            PERCENT=$((SAVINGS * 100 / ORIGINAL_SIZE))
            echo "New size: $NEW_SIZE_H (saved: $SAVINGS_H, $PERCENT%)"
        fi
        
        echo "Conversion OK – deleting original and moving new file"
        if rm -f -- "$FILE"; then
            if mv -f -- "$TEMP_FILE" "$OUT_FINAL"; then
                echo "Success: $OUT_FINAL"
                ((PROCESSED++))
            else
                echo "Error: could not move $TEMP_FILE to $OUT_FINAL"
                ((FAILED++))
            fi
        else
            echo "Error: could not delete original (permissions?)"
            ((FAILED++))
        fi
    else
        echo "Conversion FAILED – original kept. (exit status: $HB_STATUS)"
        [ -f "$TEMP_FILE" ] && rm -f -- "$TEMP_FILE"
        ((FAILED++))
    fi
done

# === Summary ===
echo ""
echo "=== SUMMARY ==="
echo "Processed files: $PROCESSED"
echo "Skipped: $SKIPPED"
echo "Failed: $FAILED"
echo "Total: ${#SELECTED_FILES[@]}"
