#!/bin/bash

# === Configuration ===
SOURCE_DIR="${SOURCE_DIR:-/whirlpool/media/data/movies}"
DRYRUN=false
INTERACTIVE=false
SIZE_LIMIT="+10G" # Minimum file size for cron/auto mode
MIN_SIZE="+1G" # Minimum file size for interactive mode
TV_MODE=false
RECURSIVE=false
MAX_DEPTH="${MAX_DEPTH:-3}" # Maximum recursion depth
BATCH_SEASON=false

# === Functions ===
show_help() {
    cat << EOF
Usage: $0 [OPTIONS]

OPTIONS:
    -d, --dry-run           Simulate actions without changing files
    -i, --interactive       Interactive file selection with fzf and preview
    -s, --source DIR        Specify source directory (default: $SOURCE_DIR)
    -r, --recursive         Enable recursive search in subdirectories
    -t, --tv-mode           Optimize for TV shows (lower size limits, better organization)
    --max-depth N           Maximum recursion depth (default: $MAX_DEPTH)
    --min-size SIZE         Minimum file size for interactive mode (default: $MIN_SIZE)
    --size-limit SIZE       Minimum file size for auto mode (default: $SIZE_LIMIT)
    --batch-season          Process entire seasons at once
    -h, --help              Show this help

SIZE FORMATS:
    Use standard suffixes: 500M, 1G, 2.5G, etc.

ENVIRONMENT VARIABLES:
    SOURCE_DIR          Override default source directory
    ENCODER            Override encoder (x264/x265)
    Q                  Override quality (default: auto)
    EPRESET           Override encoder preset (default: fast)
    MAX_DEPTH          Maximum search depth for recursive mode

EXAMPLES:
    $0                                    # Automatic conversion (files >10G)
    $0 --interactive --min-size 500M     # Interactive with smaller files
    $0 --tv-mode --recursive             # TV show mode with recursive search
    $0 --interactive --batch-season      # Interactive season selection
    $0 --dry-run --source /tv-shows      # Test with TV show directory
EOF
}

# Function to format file paths for better TV show display
format_tv_path() {
    local file="$1"
    local source="$2"
    
    # Remove source directory prefix for cleaner display
    local relative_path="${file#$source/}"
    
    # Extract show/season info for TV mode
    if [ "$TV_MODE" = true ]; then
        # Try to extract show name and season
        if echo "$relative_path" | grep -qi "season\|s[0-9]"; then
            local show_part=$(echo "$relative_path" | cut -d'/' -f1)
            local season_part=$(echo "$relative_path" | cut -d'/' -f2)
            local file_part=$(basename "$relative_path")
            echo "📺 $show_part ▸ $season_part ▸ $file_part"
        else
            echo "🎬 $relative_path"
        fi
    else
        # Truncate very long paths
        if [ ${#relative_path} -gt 80 ]; then
            echo "...${relative_path: -77}"
        else
            echo "$relative_path"
        fi
    fi
}

# Function to get directory statistics for TV shows
get_directory_stats() {
    local dir="$1"
    local min_size="$2"
    
    echo "📁 $(basename "$dir")"
    
    # Count files by type and size
    local total_files=$(find "$dir" -maxdepth 1 -type f \( -iname "*.mkv" -o -iname "*.mp4" \) | wc -l)
    local large_files=$(find "$dir" -maxdepth 1 -type f \( -iname "*.mkv" -o -iname "*.mp4" \) -size "$min_size" | wc -l)
    
    if [ "$total_files" -gt 0 ]; then
        echo "  📊 Episodes: $large_files/$total_files (≥$(echo "$min_size" | sed 's/+//'))"
        
        # Show total directory size
        local dir_size=$(du -sh "$dir" 2>/dev/null | cut -f1)
        echo "  💾 Total: $dir_size"
        
        # If this looks like a season directory, show additional info
        if echo "$(basename "$dir")" | grep -qi "season\|s[0-9]"; then
            local avg_size=$(find "$dir" -maxdepth 1 -type f \( -iname "*.mkv" -o -iname "*.mp4" \) -exec stat -c%s {} \; | awk '{sum+=$1; count++} END {if(count>0) print sum/count}' | numfmt --to=iec --suffix=B)
            echo "  📏 Avg episode: $avg_size"
        fi
    else
        echo "  📊 No video files found"
    fi
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
        -r|--recursive)
            RECURSIVE=true
            echo "=== RECURSIVE search enabled ==="
            shift
            ;;
        -t|--tv-mode)
            TV_MODE=true
            MIN_SIZE="+500M"  # Lower threshold for TV episodes
            SIZE_LIMIT="+2G"  # Lower auto threshold for TV
            echo "=== TV MODE (optimized for TV shows) ==="
            shift
            ;;
        --max-depth)
            MAX_DEPTH="$2"
            shift 2
            ;;
        --min-size)
            MIN_SIZE="$2"
            shift 2
            ;;
        --size-limit)
            SIZE_LIMIT="$2"
            shift 2
            ;;
        --batch-season)
            BATCH_SEASON=true
            echo "=== BATCH SEASON mode ==="
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
        if [ "$TV_MODE" = true ]; then
            : "${Q:=24}"  # Slightly lower quality for TV episodes (smaller files)
        else
            : "${Q:=22}"
        fi
        : "${EPRESET:=fast}"
    else
        : "${ENCODER:=x264}"
        if [ "$TV_MODE" = true ]; then
            : "${Q:=22}"  # Adjusted for TV episodes
        else
            : "${Q:=20}"
        fi
        : "${EPRESET:=fast}"
    fi
else
    # Fallback for systems without /proc/cpuinfo (e.g. macOS)
    echo "Warning: Cannot detect CPU features. Using x264 as default."
    : "${ENCODER:=x264}"
    if [ "$TV_MODE" = true ]; then
        : "${Q:=22}"
    else
        : "${Q:=20}"
    fi
    : "${EPRESET:=fast}"
fi

if [ "$TV_MODE" = true ]; then
    echo "Encoder selection: $ENCODER (q=$Q, preset=$EPRESET) - TV MODE"
else
    echo "Encoder selection: $ENCODER (q=$Q, preset=$EPRESET)"
fi

# --- Find files ---
# Set up find command based on options
FIND_OPTS=(-type f \( -iname "*.mkv" -o -iname "*.mp4" \))

if [ "$RECURSIVE" = true ]; then
    FIND_OPTS+=(-maxdepth "$MAX_DEPTH")
    echo "Searching recursively (max depth: $MAX_DEPTH)..."
else
    FIND_OPTS+=(-maxdepth 1)
fi

if [ "$INTERACTIVE" = true ]; then
    echo "Using minimum size: $MIN_SIZE for interactive selection"
    
    # Interactive: show files with TV-friendly organization
    mapfile -d '' -t SELECTED_FILES < <(
        find "$SOURCE_DIR" "${FIND_OPTS[@]}" -size "$MIN_SIZE" \
            -printf "%s\t%p\0" |
        sort -z -nr -k1,1 |
        awk -v RS='\0' -F'\t' -v tv_mode="$TV_MODE" -v source="$SOURCE_DIR" '{
            cmd="numfmt --to=iec --suffix=B " $1;
            cmd | getline hsize;
            close(cmd);
            
            # Format path for TV mode
            path = $2;
            if (tv_mode == "true") {
                # Debug: print original path to stderr
                print "DEBUG: Original path: " path > "/dev/stderr";
                print "DEBUG: Source: " source > "/dev/stderr";
                
                # Remove source prefix and format for TV display
                if (substr(path, 1, length(source) + 1) == source "/") {
                    path = substr(path, length(source) + 2);
                    print "DEBUG: After prefix removal: " path > "/dev/stderr";
                }
                
                # Split path into components
                split(path, parts, "/");
                print "DEBUG: Parts count: " length(parts) > "/dev/stderr";
                for (i = 1; i <= length(parts); i++) {
                    print "DEBUG: Part " i ": " parts[i] > "/dev/stderr";
                }
                
                # Format based on directory structure
                if (length(parts) >= 3 && match(parts[2], /[Ss]eason|[Ss][0-9]/)) {
                    # TV show with season: Show ▸ Season ▸ Episode
                    printf "%-8s\t📺 %s ▸ %s ▸ %s\t%s\0", hsize, parts[1], parts[2], parts[3], $2;
                } else if (length(parts) >= 2) {
                    # TV show without clear season: Show ▸ Episode
                    printf "%-8s\t📺 %s ▸ %s\t%s\0", hsize, parts[1], parts[2], $2;
                } else {
                    # Single file
                    printf "%-8s\t🎬 %s\t%s\0", hsize, path, $2;
                }
            } else {
                printf "%-8s\t%s\t%s\0", hsize, path, $2;
            }
        }' |
        fzf --multi --read0 --print0 \
            --delimiter=$'\t' \
            --with-nth=1,2 \
            --preview '
                # Get file path from the third field (actual path)
                FILE=$(echo "{3}" | sed "s/^'"'"'//; s/'"'"'$//")
                
                if [ -f "$FILE" ]; then
                    echo "📁 File: $FILE"
                    echo "📏 Size: $(stat -c %s "$FILE" 2>/dev/null | numfmt --to=iec --suffix=B 2>/dev/null || echo "Unknown")"
                    
                    # Show directory context for TV shows
                    if [ "'"$TV_MODE"'" = true ]; then
                        PARENT_DIR=$(dirname "$FILE")
                        echo "📂 Directory: $(basename "$PARENT_DIR")"
                        
                        # Count episodes in same directory
                        EPISODE_COUNT=$(find "$PARENT_DIR" -maxdepth 1 -type f \( -iname "*.mkv" -o -iname "*.mp4" \) | wc -l)
                        echo "📊 Episodes in directory: $EPISODE_COUNT"
                        
                        # Show total directory size
                        DIR_SIZE=$(du -sh "$PARENT_DIR" 2>/dev/null | cut -f1)
                        echo "💾 Directory size: $DIR_SIZE"
                    fi
                    
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
                    echo "❌ File not found: $FILE"
                fi
            ' \
            --preview-window=down:wrap |
        awk -v RS='\0' -v ORS='\0' -F'\t' '{print $3}'
    )
else
    echo "Using size limit: $SIZE_LIMIT for automatic selection"
    # Cron/auto: files above size limit
    mapfile -d '' -t SELECTED_FILES < <(
        find "$SOURCE_DIR" "${FIND_OPTS[@]}" -size "$SIZE_LIMIT" -print0
    )
fi

# --- If no files found ---
if [ ${#SELECTED_FILES[@]} -eq 0 ]; then
    echo "No files found for conversion in '$SOURCE_DIR'."
    if [ "$INTERACTIVE" != true ]; then
        echo "Tip: Try --interactive to select files manually."
        if [ "$TV_MODE" = true ]; then
            echo "Tip: TV mode uses lower size thresholds (current: $SIZE_LIMIT)"
        fi
    else
        echo "Tip: Try lowering --min-size or enable --recursive mode."
    fi
    exit 0
fi

echo "Found ${#SELECTED_FILES[@]} file(s) for processing."

# Show directory statistics in TV mode
if [ "$TV_MODE" = true ] && [ "$INTERACTIVE" = true ]; then
    echo ""
    echo "=== TV SHOW OVERVIEW ==="
    
    # Group files by directory and show stats
    declare -A dir_counts
    for file in "${SELECTED_FILES[@]}"; do
        dir=$(dirname "$file")
        ((dir_counts["$dir"]++))
    done
    
    for dir in "${!dir_counts[@]}"; do
        count=${dir_counts["$dir"]}
        relative_dir=$(echo "$dir" | sed "s|^$SOURCE_DIR/||")
        echo "📁 $relative_dir: $count file(s) selected"
    done
    echo ""
fi

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

# Enhanced summary for TV mode
if [ "$TV_MODE" = true ] && [ "$PROCESSED" -gt 0 ]; then
    echo ""
    echo "=== TV SHOW SUMMARY ==="
    
    # Group processed files by directory for TV show statistics
    declare -A processed_dirs
    declare -A processed_counts
    
    # This is a simplified summary - in a full implementation, 
    # you'd track this during processing
    echo "TV mode processing completed."
    echo "Tip: Check individual show/season directories for results."
fi
