#!/bin/bash

SOURCE_DIR="/whirlpool/media/data/movies"
DRYRUN=false
INTERACTIVE=false
SIZE_LIMIT="+10G" # Minimum filstørrelse for cron/auto mode

# --- Parametre ---
for arg in "$@"; do
    case $arg in
        -d|--dry-run)
            DRYRUN=true
            echo "=== DRY-RUN tilstand ==="
            ;;
        -i|--interactive)
            INTERACTIVE=true
            echo "=== INTERAKTIV tilstand ==="
            ;;
    esac
done

# --- Afhængighedstjek ---
for cmd in HandBrakeCLI fzf mediainfo numfmt; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Fejl: '$cmd' er ikke installeret."
        exit 1
    fi
done

# --- Auto-vælg encoder baseret på CPU (kan overstyres via ENV) ---
CPU_FLAGS=$(grep -m1 -oE 'avx2|fma|sse4_2' /proc/cpuinfo | tr '\n' ' ')
if echo "$CPU_FLAGS" | grep -qi 'avx2'; then
  : "${ENCODER:=x265}"
  : "${Q:=22}"
  : "${EPRESET:=fast}"
else
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
    echo "Ingen filer fundet til konvertering."
    exit 0
fi

# --- Behandl de valgte filer ---
for FILE in "${SELECTED_FILES[@]}"; do
    [ -f "$FILE" ] || { echo "Springer over: $FILE (ikke en fil)"; continue; }

    DIRNAME=$(dirname "$FILE")
    BASENAME=$(basename "$FILE")
    NAME="${BASENAME%.*}"
    OUT_FINAL="$DIRNAME/${NAME}.mp4"
    TEMP_FILE="$DIRNAME/${NAME}_new.mp4"

    # Skip hvis output allerede findes
    if [ -f "$OUT_FINAL" ]; then
        echo "Springer over: $FILE (output findes allerede: $OUT_FINAL)"
        continue
    fi

    # Tjek skriveadgang (uden sudo)
    if [ ! -w "$DIRNAME" ] || [ ! -w "$FILE" ]; then
        echo "Mangler skriveadgang til '$DIRNAME' eller '$FILE'."
        echo "Kør i stedet: sudo -E \"$0\" $([ "$INTERACTIVE" = true ] && echo -i) $([ "$DRYRUN" = true ] && echo -d)"
        continue
    fi

    if [ "$DRYRUN" = true ]; then
        echo "[DRY-RUN] Ville konvertere: $FILE"
        echo "[DRY-RUN] Ville gemme som: $TEMP_FILE"
        echo "[DRY-RUN] Efter succes: slette original og omdøbe til: $OUT_FINAL"
        continue
    fi

    echo "Behandler: $FILE"
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
        echo "Konvertering OK – sletter original og flytter ny fil"
        rm -f -- "$FILE" || { echo "Advarsel: kunne ikke slette original (rettigheder?)"; }
        mv -f -- "$TEMP_FILE" "$OUT_FINAL" || { echo "Advarsel: kunne ikke flytte $TEMP_FILE til $OUT_FINAL"; }
    else
        echo "Konvertering FEJLEDE – original beholdes. (status=$HB_STATUS)"
        [ -f "$TEMP_FILE" ] && rm -f -- "$TEMP_FILE"
    fi
done
