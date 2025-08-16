# plex_compress.sh

Et Bash-script til at komprimere store videofiler (MKV/MP4) i et Plex-bibliotek ved hjælp af HandBrakeCLI. Scriptet understøtter både interaktiv og automatisk (cron) tilstand, og kan køre i dry-run mode for at simulere handlinger uden at ændre filer.

## Funktioner
- **Automatisk valg af encoder** (x264/x265) baseret på CPU-understøttelse
- **Interaktiv tilstand**: Vælg filer med fzf og se detaljeret preview (kræver fzf, mediainfo, numfmt)
- **Cron/auto-tilstand**: Finder automatisk store videofiler (standard: >10GB)
- **Dry-run**: Simulerer handlinger uden at ændre filer
- **Sikkerhedstjek**: Skriveadgang og outputfil eksisterer ikke i forvejen
- **Bevarer kun succesfulde konverteringer**

## Afhængigheder
- HandBrakeCLI
- fzf (kun interaktiv)
- mediainfo (kun interaktiv)
- numfmt


## Oversigt over flag

| Flag              | Kort version | Funktion                                                      |
|-------------------|--------------|---------------------------------------------------------------|
| `--dry-run`       | `-d`         | Simulerer handlinger uden at ændre filer                      |
| `--interactive`   | `-i`         | Interaktivt valg af filer med fzf og preview                  |

Du kan kombinere flag, fx både køre interaktivt og i dry-run:

```bash
./plex_compress.sh --interactive --dry-run
```

## Brug
```bash
./plex_compress.sh [--dry-run|-d] [--interactive|-i]
```

Se tabellen ovenfor for detaljer om de enkelte flag.

## Eksempler
- Automatisk komprimering af store filer:
  ```bash
  ./plex_compress.sh
  ```
- Interaktivt valg af filer:
  ```bash
  ./plex_compress.sh --interactive
  ```
- Simulering (ingen ændringer):
  ```bash
  ./plex_compress.sh --dry-run
  ```

## Miljøvariabler
- `ENCODER` (x264/x265): Overstyr automatisk encoder-valg
- `Q` (kvalitet): Overstyr standard kvalitet (lavere = bedre kvalitet, større fil)
- `EPRESET` (HandBrake preset): Overstyr preset (fx fast, medium)

## Typisk workflow
1. Scriptet tjekker for nødvendige programmer.
2. Vælger encoder baseret på CPU eller ENV.
3. Finder relevante videofiler (interaktivt eller automatisk).
4. For hver fil:
   - Tjekker skriveadgang og om output allerede findes
   - Kører HandBrakeCLI med valgte parametre
   - Ved succes: sletter original og gemmer ny fil
   - Ved fejl: original beholdes

## Fejlhåndtering
- Manglende afhængigheder stopper scriptet
- Manglende skriveadgang giver besked om at køre med sudo
- Outputfil eksisterer: fil springes over

## Forfatter
- k-dannemand

---

*Se scriptet for flere detaljer og tilpasninger.*
