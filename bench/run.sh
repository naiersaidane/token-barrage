#!/bin/bash
# Banc de mesure token-barrage.
#
# Méthode : mesure différentielle. Le nombre de tokens d'un texte est obtenu en
# comparant le contexte total d'un appel à vide et d'un appel portant ce texte,
# à drapeaux strictement identiques. Le contexte total est la somme
# input + cache_write + cache_read, qui est indépendante de l'état du cache.
#
# C'est plus exact que l'estimation chars/4 utilisée par Spotify, et ça mesure
# des tokens réellement facturés plutôt qu'une approximation.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$ROOT/plugins/token-barrage"
BENCH="$ROOT/bench"
FIXTURES="$BENCH/fixtures"
LEDGER="$BENCH/ledger.jsonl"
RESULTS="$BENCH/results.json"

MODEL="${BARRAGE_WORKER_MODEL:-claude-haiku-4-5-20251001}"
NO_TOOLS="Bash,Read,Write,Edit,NotebookEdit,Glob,Grep,WebFetch,WebSearch,Task,TodoWrite,BashOutput,KillShell,SlashCommand,Skill"
SP="You are a precise code analyst. Read the provided files and answer the question concisely. Output structured bullets only. No greetings, no prose, no preambles, no summaries. Lead every bullet with the exact name, type, or line number. Use nested bullets for details. Skip anything the caller did not ask for."

# Tarifs catalogue, $/million de tokens (entrée).
PRIX_PRINCIPAL=5      # Claude Opus 5
export BARRAGE_LEDGER="$LEDGER"

: > "$LEDGER"

# contexte_total <fichier_prompt> → tokens
contexte_total() {
  claude -p --model "$MODEL" --system-prompt "$SP" --disallowed-tools "$NO_TOOLS" \
    --output-format json < "$1" 2>/dev/null \
  | jq -r '(.usage.input_tokens // 0) + (.usage.cache_creation_input_tokens // 0) + (.usage.cache_read_input_tokens // 0)'
}

echo "▸ Étalonnage du contexte à vide…"
BASE_FILE=$(mktemp); printf '.' > "$BASE_FILE"
C0=$(contexte_total "$BASE_FILE")
echo "  overhead fixe du worker : $C0 tokens"
echo

n=$(jq '.scenarios | length' "$BENCH/scenarios.json")
echo '[]' > "$RESULTS.tmp"

for ((i=0; i<n; i++)); do
  id=$(jq -r ".scenarios[$i].id"       "$BENCH/scenarios.json")
  label=$(jq -r ".scenarios[$i].label" "$BENCH/scenarios.json")
  question=$(jq -r ".scenarios[$i].question" "$BENCH/scenarios.json")
  rel=()
  while IFS= read -r _l; do rel+=("$_l"); done < <(jq -r ".scenarios[$i].paths[]" "$BENCH/scenarios.json")

  paths=(); for p in "${rel[@]}"; do paths+=("$FIXTURES/$p"); done
  lignes=$(cat "${paths[@]}" | wc -l | tr -d ' ')

  echo "▸ [$((i+1))/$n] $label — ${lignes} lignes"

  # --- bras SANS barrage : le corpus entre tel quel dans le contexte principal
  corpus=$(mktemp)
  for p in "${paths[@]}"; do
    { printf '<file path="%s">\n' "$p"; cat "$p"; printf '</file>\n\n'; } >> "$corpus"
  done
  printf 'Question: %s\n' "$question" >> "$corpus"
  C1=$(contexte_total "$corpus")
  tok_sans=$((C1 - C0))
  echo "    sans barrage : $tok_sans tokens dans le contexte principal"

  # --- bras AVEC barrage : seul le résumé remonte
  resume=$(mktemp)
  "$PLUGIN/scripts/bulk-read" --question "$question" --paths "${paths[@]}" > "$resume" 2>/dev/null
  C2=$(contexte_total "$resume")
  tok_avec=$((C2 - C0))
  cout_worker=$(jq -r '.worker.cost_usd' "$LEDGER" | tail -1)
  echo "    avec barrage : $tok_avec tokens dans le contexte principal"
  echo "    coût worker réel : \$$cout_worker"

  jq -n \
    --arg id "$id" --arg label "$label" \
    --argjson lignes "$lignes" \
    --argjson tok_sans "$tok_sans" --argjson tok_avec "$tok_avec" \
    --argjson cout_worker "$cout_worker" \
    --argjson prix "$PRIX_PRINCIPAL" \
    '{
      id: $id, label: $label, lignes: $lignes,
      tokens_sans: $tok_sans, tokens_avec: $tok_avec,
      economie_brute_pct: (1 - ($tok_avec / $tok_sans)) * 100,
      economie_usd: (($tok_sans - $tok_avec) * $prix / 1000000),
      cout_worker_usd: $cout_worker,
      gain_net_usd: ((($tok_sans - $tok_avec) * $prix / 1000000) - $cout_worker)
    }' > "$BENCH/.scenario.json"

  jq -s '.[0] + [.[1]]' "$RESULTS.tmp" "$BENCH/.scenario.json" > "$RESULTS.tmp2"
  mv "$RESULTS.tmp2" "$RESULTS.tmp"
  rm -f "$corpus" "$resume"
  echo
done

jq -n --slurpfile s "$RESULTS.tmp" --argjson base "$C0" --arg model "$MODEL" \
  '{ mesure: "differentielle", worker_model: $model, overhead_worker_tokens: $base,
     prix_principal_usd_par_mtok: 5, scenarios: $s[0],
     economie_brute_moyenne_pct: ([$s[0][].economie_brute_pct] | add / length) }' > "$RESULTS"
rm -f "$RESULTS.tmp" "$BENCH/.scenario.json" "$BASE_FILE"
echo "✓ Résultats écrits dans bench/results.json"
