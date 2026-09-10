#!/bin/bash
# Transport de délégation vers un modèle worker bon marché.
#
# Choix de conception, et en quoi ils diffèrent de shunt/AiKA :
#
#   * Transport = `claude -p`, donc aucune clé API, aucun SaaS, aucun compte.
#     Ça tourne sur l'abonnement Claude Code déjà en place.
#
#   * Le message passe par STDIN, pas par argv. shunt fait transiter la requête
#     sur la ligne de commande et doit donc refuser tout ce qui dépasse ARG_MAX
#     (400 Ko sur macOS, 120 Ko sur Linux). Ici, pas de plafond de ce type.
#
#   * Overhead mesuré : le prompt système de Claude Code coûte 24 706 tokens en
#     configuration naïve. `--system-prompt` (remplacement) + `--disallowed-tools`
#     (suppression des définitions d'outils) le ramènent à 11 335, soit −54 %.
#     Le worker n'a besoin d'aucun outil : tout le corpus est dans le message.
#
#   * Chaque appel écrit une ligne dans un registre JSONL : tokens et coût RÉELS
#     côté worker. C'est ce qui permet de calculer un coût net, ce qu'aucune
#     mesure publiée sur shunt ne fait aujourd'hui.

BARRAGE_WORKER_MODEL="${BARRAGE_WORKER_MODEL:-claude-haiku-4-5-20251001}"
BARRAGE_LEDGER="${BARRAGE_LEDGER:-.barrage/ledger.jsonl}"

BARRAGE_NO_TOOLS="Bash,Read,Write,Edit,NotebookEdit,Glob,Grep,WebFetch,WebSearch,Task,TodoWrite,BashOutput,KillShell,SlashCommand,Skill"

# Instructions volontairement identiques (en anglais) à celles des modes AiKA
# `bulk-reader` et `code-writer`, pour que la comparaison reste à variables égales.
BARRAGE_SP_BULK_READER="You are a precise code analyst. Read the provided files and answer the question concisely. Output structured bullets only. No greetings, no prose, no preambles, no summaries. Lead every bullet with the exact name, type, or line number. Use nested bullets for details. Skip anything the caller did not ask for."
BARRAGE_SP_CODE_WRITER="You generate code files based on a spec and reference files. Match the existing patterns, conventions, naming, and style exactly. Output only the code — no explanations, no markdown fences unless asked. If the spec is ambiguous, make reasonable choices that match the patterns in the reference code."

BARRAGE_TMPFILES=()
barrage_tmpfile() {
  local f
  f=$(mktemp) || return 1
  BARRAGE_TMPFILES+=("$f")
  trap 'rm -f "${BARRAGE_TMPFILES[@]}"' EXIT
  printf -v "$1" '%s' "$f"
}

barrage_preflight() {
  local missing=""
  command -v jq     >/dev/null 2>&1 || missing="$missing jq"
  command -v claude >/dev/null 2>&1 || missing="$missing claude"
  if [ -n "$missing" ]; then
    echo "Erreur : commande(s) manquante(s) :$missing" >&2
    echo "  jq     — brew install jq" >&2
    echo "  claude — https://claude.com/claude-code" >&2
    return 1
  fi
  return 0
}

# barrage_invoke <mode> <fichier_message>
# Écrit la réponse du worker sur stdout. Journalise le coût réel sur stderr et
# dans le registre.
barrage_invoke() {
  local mode="$1" message_file="$2"
  local system_prompt raw text

  case "$mode" in
    bulk-reader) system_prompt="$BARRAGE_SP_BULK_READER" ;;
    code-writer) system_prompt="$BARRAGE_SP_CODE_WRITER" ;;
    *) echo "Erreur : mode inconnu « $mode »" >&2; return 1 ;;
  esac

  barrage_tmpfile raw || return 1

  if ! claude -p \
        --model "$BARRAGE_WORKER_MODEL" \
        --system-prompt "$system_prompt" \
        --disallowed-tools "$BARRAGE_NO_TOOLS" \
        --output-format json \
        < "$message_file" > "$raw" 2>/dev/null
  then
    echo "Erreur : l'appel au worker a échoué (modèle : $BARRAGE_WORKER_MODEL)." >&2
    return 1
  fi

  if ! jq -e . "$raw" >/dev/null 2>&1; then
    echo "Erreur : réponse du worker illisible." >&2
    head -c 400 "$raw" >&2
    return 1
  fi

  # Une réponse en erreur ne doit pas être servie comme un résultat valide.
  if [ "$(jq -r '.is_error // false' "$raw")" = "true" ]; then
    echo "Erreur : le worker a renvoyé une erreur : $(jq -r '.result // "inconnue"' "$raw")" >&2
    return 1
  fi

  text=$(jq -r '.result // empty' "$raw")
  if [ -z "$text" ]; then
    echo "Erreur : le worker n'a renvoyé aucun texte." >&2
    return 1
  fi

  barrage_log "$mode" "$message_file" "$raw"
  printf '%s\n' "$text"
}

# Registre : une ligne JSON par délégation. C'est l'instrument de mesure.
barrage_log() {
  local mode="$1" message_file="$2" raw="$3"
  local dir bytes

  dir=$(dirname "$BARRAGE_LEDGER")
  mkdir -p "$dir" 2>/dev/null || return 0
  bytes=$(wc -c < "$message_file" | tr -d ' ')

  jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg mode "$mode" \
    --arg model "$BARRAGE_WORKER_MODEL" \
    --argjson payload_bytes "$bytes" \
    --slurpfile r "$raw" \
    '{
      ts: $ts, mode: $mode, model: $model, payload_bytes: $payload_bytes,
      worker: {
        input_tokens:        ($r[0].usage.input_tokens // 0),
        cache_write_tokens:  ($r[0].usage.cache_creation_input_tokens // 0),
        cache_read_tokens:   ($r[0].usage.cache_read_input_tokens // 0),
        output_tokens:       ($r[0].usage.output_tokens // 0),
        cost_usd:            ($r[0].total_cost_usd // 0),
        duration_ms:         ($r[0].duration_ms // 0)
      }
    }' >> "$BARRAGE_LEDGER" 2>/dev/null || return 0

  jq -r '"[barrage: \(.mode) | \(.worker.input_tokens + .worker.cache_write_tokens + .worker.cache_read_tokens) tokens worker | $\(.worker.cost_usd) | \(.worker.duration_ms)ms]"' \
    <<< "$(tail -1 "$BARRAGE_LEDGER")" >&2
}
