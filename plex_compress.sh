#!/bin/bash

# === Konfiguration ===
SOURCE_DIR="${SOURCE_DIR:-/whirlpool/media/data/movies}"
DRYRUN=false
INTERACTIVE=false
SIZE_LIMIT="+10G" # Minimum filstørrelse for cron/auto mode

# === Funktioner ===
show_help() {
    cat << EOF
Brug: $0 [OPTIONER]

OPTIONER:
    -d, --dry-run        Simuler handlinger uden at ændre filer
    -i, --interactive    Interaktivt valg af filer med fzf og preview
    -s, --source DIR     Angiv kildemappe (standard: $SOURCE_DIR)
    -h, --help           Vis denne hjælp

MILJØVARIABLER:
    SOURCE_DIR          Overstyr standard kildemappe
    ENCODER            Overstyr encoder (x264/x265)
    Q                  Overstyr kvalitet (standard: auto)
    EPRESET           Overstyr encoder preset (standard: fast)

EKSEMPLER:
    $0                              # Automatisk konvertering
    $0 --interactive                # Interaktivt valg
    $0 --dry-run --source /movies   # Test med anden mappe
EOF
}

# --- Parametre ---
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--dry-run)
            DRYRUN=true
            echo "=== DRY-RUN tilstand ==="
            shift
            ;;
        -i|--interactive)
            INTERACTIVE=true
            echo "=== INTERAKTIV tilstand ==="
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
            echo "Ukendt option: $1"
            show_help
            exit 1
            ;;
    esac
done

# === Validering ===
if [ ! -d "$SOURCE_DIR" ]; then
    echo "Fejl: Kildemappe '$SOURCE_DIR' findes ikke."
    exit 1
fi

# --- Afhængighedstjek ---
REQUIRED_DEPS=(HandBrakeCLI)
if [ "$INTERACTIVE" = true ]; then
    REQUIRED_DEPS+=(fzf mediainfo numfmt)
else
    REQUIRED_DEPS+=(numfmt)
fi

for cmd in "${REQUIRED_DEPS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Fejl: '$cmd' er ikke installeret."
        echo "For interaktiv tilstand kræves: HandBrakeCLI, fzf, mediainfo, numfmt"
        echo "For auto-tilstand kræves: HandBrakeCLI, numfmt"
        exit 1
    fi
done

# --- Auto-vælg encoder baseret på CPU (kan overstyres via ENV) ---
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
    # Fallback for systemer uden /proc/cpuinfo (fx macOS)
    echo "Advarsel: Kan ikke detektere CPU-funktioner. Bruger x264 som standard."
    : "${ENCODER:=x264}"
    : "${Q:=20}"
    : "${EPRESET:=fast}"
fi
echo "Encoder-valg: $ENCODER (q=$Q, preset=$EPRESET)"

# --- Find filer ---
if [ "$INTERACTIVE" = true ]; then
    # Interaktiv: vis alle MKV/MP4, størrelsessorteret, preview i bunden
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
                FILE=$(echo {} | cut -f2-)
                echo "� Fil: $FILE"
                echo "� Størrelse: $(stat -c %s "$FILE" | numfmt --to=iec --suffix=B)"
                echo
                mediainfo --Inform="
                    General;� Format: %{Format}
                    � Bitrate: %{OverallBitRate/String}
                    ⏱ Varighed: %{Duration/String}

                    Video;� Video: %{Format} %{Width}x%{Height} %{FrameRate/String}

                    Audio;� Lydspor: %{Format} %{Channel(s)/String} (%{Language})
                " "$FILE" 2>/dev/null
            ' \
            --preview-window=down:wrap |
        awk -v RS='\0' -v ORS='\0' -F'\t' '{print $2}'
    )
else
    # Cron/auto: kun store filer
    mapfile -d '' -t SELECTED_FILES < <(
        find "$SOURCE_DIR" -type f \( -iname "*.mkv" -o -iname "*.mp4" \) -size "$SIZE_LIMIT" -print0
    )
fi

# --- Hvis ingen filer fundet ---
if [ ${#SELECTED_FILES[@]} -eq 0 ]; then
    echo "Ingen filer fundet til konvertering i '$SOURCE_DIR'."
    if [ "$INTERACTIVE" != true ]; then
        echo "Tip: Prøv --interactive for at vælge filer manuelt."
    fi
    exit 0
fi

echo "Fandt ${#SELECTED_FILES[@]} fil(er) til behandling."

# --- Behandl de valgte filer ---
PROCESSED=0
SKIPPED=0
FAILED=0

for FILE in "${SELECTED_FILES[@]}"; do
    [ -f "$FILE" ] || { echo "Springer over: $FILE (ikke en fil)"; ((SKIPPED++)); continue; }

    DIRNAME=$(dirname "$FILE")
    BASENAME=$(basename "$FILE")
    NAME="${BASENAME%.*}"
    OUT_FINAL="$DIRNAME/${NAME}.mp4"
    # Brug PID for at undgå navnekollisioner
    TEMP_FILE="$DIRNAME/${NAME}_temp_$$.mp4"

    echo ""
    echo "=== Fil $((PROCESSED + SKIPPED + FAILED + 1))/${#SELECTED_FILES[@]}: $BASENAME ==="

    # Skip hvis output allerede findes
    if [ -f "$OUT_FINAL" ]; then
        echo "Springer over: Output findes allerede ($OUT_FINAL)"
        ((SKIPPED++))
        continue
    fi

    # Tjek skriveadgang (uden sudo)
    if [ ! -w "$DIRNAME" ] || [ ! -w "$FILE" ]; then
        echo "Mangler skriveadgang til '$DIRNAME' eller '$FILE'."
        echo "Kør i stedet: sudo -E \"$0\" $([ "$INTERACTIVE" = true ] && echo -i) $([ "$DRYRUN" = true ] && echo -d)"
        ((FAILED++))
        continue
    fi

    if [ "$DRYRUN" = true ]; then
        echo "[DRY-RUN] Ville konvertere: $FILE"
        echo "[DRY-RUN] Ville gemme som: $TEMP_FILE"
        echo "[DRY-RUN] Efter succes: slette original og omdøbe til: $OUT_FINAL"
        ((PROCESSED++))
        continue
    fi

    # Vis filstørrelse før konvertering
    ORIGINAL_SIZE=$(stat -c%s "$FILE" 2>/dev/null || echo "0")
    ORIGINAL_SIZE_H=$(echo "$ORIGINAL_SIZE" | numfmt --to=iec --suffix=B)
    echo "Original størrelse: $ORIGINAL_SIZE_H"
    
    echo "Konverterer: $FILE"
    echo "Kommando: HandBrakeCLI -i \"$FILE\" -o \"$TEMP_FILE\" -e $ENCODER -q $Q --encoder-preset $EPRESET --optimize -E ac3 --audio-copy-mask ac3 --audio-fallback ac3"
    
    HandBrakeCLI \
        -i "$FILE" \
        -o "$TEMP_FILE" \
        -e "$ENCODER" -q "$Q" --encoder-preset "$EPRESET" \
        --optimize \
        -E ac3 \
        --audio-copy-mask ac3 \
        --audio-fallback ac3

    HB_STATUS=$?

    # Sikkerheds-tjek: kun succes hvis exit=0 OG outputfil findes og har indhold
    if [ $HB_STATUS -eq 0 ] && [ -s "$TEMP_FILE" ]; then
        # Vis størrelsesforskel
        NEW_SIZE=$(stat -c%s "$TEMP_FILE" 2>/dev/null || echo "0")
        NEW_SIZE_H=$(echo "$NEW_SIZE" | numfmt --to=iec --suffix=B)
        if [ "$ORIGINAL_SIZE" -gt 0 ] && [ "$NEW_SIZE" -gt 0 ]; then
            SAVINGS=$((ORIGINAL_SIZE - NEW_SIZE))
            SAVINGS_H=$(echo "$SAVINGS" | numfmt --to=iec --suffix=B)
            PERCENT=$((SAVINGS * 100 / ORIGINAL_SIZE))
            echo "Ny størrelse: $NEW_SIZE_H (sparet: $SAVINGS_H, $PERCENT%)"
        fi
        
        echo "Konvertering OK – sletter original og flytter ny fil"
        if rm -f -- "$FILE"; then
            if mv -f -- "$TEMP_FILE" "$OUT_FINAL"; then
                echo "Succes: $OUT_FINAL"
                ((PROCESSED++))
            else
                echo "Fejl: kunne ikke flytte $TEMP_FILE til $OUT_FINAL"
                ((FAILED++))
            fi
        else
            echo "Fejl: kunne ikke slette original (rettigheder?)"
            ((FAILED++))
        fi
    else
        echo "Konvertering FEJLEDE – original beholdes. (exit status: $HB_STATUS)"
        [ -f "$TEMP_FILE" ] && rm -f -- "$TEMP_FILE"
        ((FAILED++))
    fi
done

# === Sammendrag ===
echo ""
echo "=== SAMMENDRAG ==="
echo "Behandlede filer: $PROCESSED"
echo "Sprunget over: $SKIPPED"
echo "Fejlede: $FAILED"
echo "Total: ${#SELECTED_FILES[@]}"
