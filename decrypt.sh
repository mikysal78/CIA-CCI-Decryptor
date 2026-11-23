#!/usr/bin/env bash
# CIA-CCI-Decryptor - organizzazione Giochi/3DS
set -uo pipefail
shopt -s nullglob nocaseglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
THREEDS="$ROOT/3DS"

INPUT_DIR="$THREEDS/Originali"
OUTPUT_DIR="$THREEDS/Decrittati"
AUDIT_DIR="$THREEDS/audit"
TMP_ROOT="$AUDIT_DIR/tmp"
LOG_DIR="$AUDIT_DIR/logs"

BIN="$SCRIPT_DIR/bin"
SEEDDB="$BIN/seeddb.bin"

DEBUG=0
FORCE=0
GAME_FORMAT=cci
STRIP_TITLE_ID=1

usage() {
    cat <<HELP
Utilizzo: ./decrypt.sh [opzioni]

  --debug           Mostra i comandi e conserva il log dettagliato
  --force           Sovrascrive i risultati già presenti
  --cia             Produce CIA per i giochi compatibili
  --cci             Produce CCI (predefinito)
  --keep-title-id   Mantiene il Title ID nel nome
  -h, --help        Mostra questo aiuto

Input : $INPUT_DIR
Output: $OUTPUT_DIR
HELP
}

while (($#)); do
    case "$1" in
        --debug) DEBUG=1 ;;
        --force) FORCE=1 ;;
        --cia) GAME_FORMAT=cia ;;
        --cci) GAME_FORMAT=cci ;;
        --keep-title-id) STRIP_TITLE_ID=0 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Opzione sconosciuta: $1" >&2; usage; exit 1 ;;
    esac
    shift
done

for tool in ctrtool makerom ctrdecrypt dlchelper; do
    [[ -x "$BIN/$tool" ]] || {
        echo "Errore: manca $BIN/$tool" >&2
        exit 1
    }
done

[[ -f "$SEEDDB" ]] || {
    echo "Errore: manca $SEEDDB" >&2
    exit 1
}

mkdir -p "$INPUT_DIR" "$OUTPUT_DIR" "$TMP_ROOT" "$LOG_DIR"

LOGFILE="$LOG_DIR/decrypt-$(date +%Y%m%d-%H%M%S).log"

{
    echo "======================================"
    echo " CIA-CCI-Decryptor - sessione"
    echo " Data: $(date --iso-8601=seconds)"
    echo " Input: $INPUT_DIR"
    echo " Output: $OUTPUT_DIR"
    echo " Debug: $DEBUG"
    echo "======================================"
    echo
} >>"$LOGFILE"

run() {
    local status

    {
        printf '+'
        printf ' %q' "$@"
        printf '\n'
    } >>"$LOGFILE"

    if ((DEBUG)); then
        printf '+'
        printf ' %q' "$@"
        printf '\n'
        "$@" 2>&1 | tee -a "$LOGFILE"
        status=${PIPESTATUS[0]}
    else
        "$@" >>"$LOGFILE" 2>&1
        status=$?
    fi

    return "$status"
}

decrypt_rom() {
    local rom="$1"
    local status

    {
        echo
        echo "===== Decrittazione: $rom ====="
        printf '+ %q %q\n' "$BIN/ctrdecrypt" "$rom"
    } >>"$LOGFILE"

    if ((DEBUG)); then
        "$BIN/ctrdecrypt" "$rom" 2>&1 | tee -a "$LOGFILE"
        status=${PIPESTATUS[0]}
    else
        "$BIN/ctrdecrypt" "$rom" >>"$LOGFILE" 2>&1
        status=$?
    fi

    return "$status"
}

output_name() {
    local name="$1"
    local prefix='^[0-9A-Fa-f]{16}[ _.-]+(.+)$'

    if ((STRIP_TITLE_ID)) && [[ "$name" =~ $prefix ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf '%s' "$name"
    fi
}

build() {
    local output="$1"
    shift

    local tmp_output="${output}.tmp.$$"

    if [[ -e "$output" ]] && (( ! FORCE )); then
        echo "Già presente, salto: $(basename "$output")"
        return 0
    fi

    rm -f -- "$tmp_output"

    if ! run "$BIN/makerom" "$@" -ignoresign -target p -o "$tmp_output"; then
        echo "ERRORE: makerom non è riuscito a creare $output" >&2
        rm -f -- "$tmp_output"
        return 1
    fi

    if [[ ! -s "$tmp_output" ]]; then
        echo "ERRORE: file prodotto assente o vuoto: $tmp_output" >&2
        rm -f -- "$tmp_output"
        return 1
    fi

    if ! mv -f -- "$tmp_output" "$output"; then
        echo "ERRORE: impossibile installare il risultato: $output" >&2
        rm -f -- "$tmp_output"
        return 1
    fi

    echo "Creato: $output"
}
process_rom() (
    local source="$1"
    local extension="${source##*.}"
    local name="${source%.*}"
    local output
    local jobdir
    local rom
    local f stem index id ver
    local args=()
    local dlc=()

    output="$(output_name "$name")"
    jobdir="$(mktemp -d "$TMP_ROOT/job.XXXXXXXX")"
    trap 'rm -rf -- "$jobdir"' EXIT

    # Copia temporanea: il dump originale non viene mai modificato.
    cp --reflink=auto -- "$INPUT_DIR/$source" "$jobdir/$source" || {
        return 1
    }

    cd "$jobdir" || return 1
    rom="$source"

    echo "Elaborazione: $source"
    echo "===== Elaborazione: $source =====" >>"$LOGFILE"

    if ! "$BIN/ctrtool" --seeddb="$SEEDDB" "$rom" \
        >content.txt 2>ctrtool-error.log; then
        {
            echo "ERRORE: ctrtool non riesce a leggere $source"
            cat ctrtool-error.log
        } >>"$LOGFILE"

        echo "ERRORE: ctrtool non riesce a leggere $source" >&2
        if ((DEBUG)); then
            cat ctrtool-error.log
        fi
        return 1
    fi

    cat content.txt >>"$LOGFILE"

    if grep -Eq 'Crypto.*None' content.txt && (( ! DEBUG )); then
        echo "Il file risulta già decrittato: $source"
        echo "Esito: già decrittato, nessuna operazione necessaria" >>"$LOGFILE"
        return 0
    fi

    if ! decrypt_rom "$rom"; then
        echo "ERRORE: decrittazione fallita: $source"
        return 1
    fi

    if [[ "${extension,,}" == "3ds" || "${extension,,}" == "cci" ]]; then
        for f in "$name".*.ncch; do
            stem="${f%.ncch}"
            index=$((16#${stem##*.}))
            args+=(-i "$f:$index:$index")
        done

        if ((${#args[@]})); then
            build "$OUTPUT_DIR/$output-decrypted.cci" \
                -f cci "${args[@]}" || { return 1; }
        else
            echo "ERRORE: nessun file NCCH generato per $source" >&2
                    return 1
        fi

    elif [[ "${extension,,}" == "cia" ]]; then
        for f in "$name".*.ncch; do
            stem="${f%.ncch}"
            id=$((16#${stem##*.}))
            stem="${stem%.*}"
            index="${stem##*.}"
            args+=(-i "$f:$index:$index")
            dlc+=(-i "$f:$index:$id")
        done

        if ((${#args[@]} == 0)); then
            echo "ERRORE: nessun contenuto NCCH generato per $source" >&2
                    return 1
        else
            ver=$(grep 'TitleVersion' content.txt |
                tail -n1 |
                sed -n 's/.*(v\{0,1\}\([0-9]*\)).*/\1/p')
            ver=${ver:-0}

            if grep -Eq '^T.*d.*00040000' content.txt; then
                if [[ "$GAME_FORMAT" == "cci" ]]; then
                    build "$OUTPUT_DIR/$output-decrypted.cci" \
                        -f cci "${args[@]}" || { return 1; }
                else
                    build "$OUTPUT_DIR/$output-decrypted.cia" \
                        -f cia "${args[@]}" -ver "$ver" || { return 1; }
                fi
            fi

            if grep -Eq '^T.*d.*0004000e' content.txt; then
                build "$OUTPUT_DIR/$output (Update)-decrypted.cia" \
                    -f cia "${dlc[@]}" -ver "$ver" || { return 1; }
            fi

            if grep -Eq '^T.*d.*0004008c' content.txt; then
                if ! run "$BIN/dlchelper" "$source" "$ver"; then
                    echo "ERRORE: dlchelper non è riuscito per $source" >&2
                                            return 1
                fi

                if [[ -s "$source (DLC)-decrypted.cia" ]]; then
                    if ! mv -f -- "$source (DLC)-decrypted.cia" \
                        "$OUTPUT_DIR/$output (DLC)-decrypted.cia"; then
                        echo "ERRORE: impossibile salvare il DLC di $source" >&2
                                                        return 1
                    fi
                else
                    echo "ERRORE: dlchelper non ha prodotto il CIA DLC per $source" >&2
                                            return 1
                fi
            fi
        fi
    fi

    echo
)

echo "======================================"
echo " CIA-CCI-Decryptor"
echo "======================================"
echo "Originali : $INPUT_DIR"
echo "Decrittati: $OUTPUT_DIR"
echo

found=0
total=0
failed=0

for rom in "$INPUT_DIR"/*.{3ds,cci,cia}; do
    [[ -f "$rom" ]] || continue
    found=1
    ((total += 1))
    process_rom "$(basename "$rom")" || ((failed += 1))
done

if (( ! found )); then
    echo "Nessun file .3ds, .cci o .cia trovato in Originali."
fi

echo
echo "======================================"
echo " RIEPILOGO"
echo "======================================"
echo "File trovati:       $total"
echo "Elaborazioni OK:    $((total - failed))"
echo "Elaborazioni KO:    $failed"
echo "Log: $LOGFILE"

if ((failed)); then
    echo "ATTENZIONE: una o più elaborazioni sono fallite." >&2
    exit 1
fi

echo "Tutte le elaborazioni sono terminate."
