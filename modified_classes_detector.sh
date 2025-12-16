#!/bin/bash
set -euo pipefail

# ==============================================================================
# Orchestratore pipeline (DRY-RUN / STUB first)
# - Niente chiamate reali a Chat2UnitTest finché non lo decidi tu
# - Struttura pronta per:
#   i) modified -> rigenera test -> ju2jmh -> benchmark
#   ii) deleted -> elimina test
#   iii) added -> genera test -> aggiorna coverage -> ju2jmh -> benchmark
# ==============================================================================

# ===== Switch =================================================================
DRY_RUN="${DRY_RUN:-1}"          # 1 = niente modifiche “vere” (consigliato ora)
PUSH_ENABLED="${PUSH_ENABLED:-0}" # 1 = abilita push (solo quando sei pronto)

# ===== Git identity ===========================================================
git config user.name  "Kekkodarco" || true
git config user.email "f.darco6@studenti.unisa.it" || true

# ===== Paths (repo) ===========================================================
PROD_ROOT="app/src/main/java"
TEST_ROOT="app/src/test/java"
BENCH_ROOT="ju2jmh/src/jmh/java"

COVERAGE_MATRIX_JSON="app/coverage-matrix.json"

# AST fat jar
AST_JAR="$(ls -1 app/build/libs/app-*-all.jar 2>/dev/null | head -n 1)"
if [[ -z "$AST_JAR" ]]; then
  echo "ERRORE: fatJar non trovato. Esegui: ./gradlew :app:fatJar"
  exit 1
fi

# Output AST (quando lo modificherai per crearli tutti e 3)
MODIFIED_METHODS_FILE="modified_methods.txt"
ADDED_METHODS_FILE="added_methods.txt"
DELETED_METHODS_FILE="deleted_methods.txt"

# Chat2UnitTest input (generati dal builder)
INPUT_MODIFIED_JSON="input_modified.json"
INPUT_ADDED_JSON="input_added.json"

# Chat2UnitTest input builder (classe nel jar)
CHAT2UNITTEST_INPUT_BUILDER_CLASS="Chat2UnitTestInputBuilder"

# Ju2Jmh
JU2JMH_CONVERTER_JAR="./ju-to-jmh/converter-all.jar"
OUTPUT_BENCH_CLASSES_FILE="ju2jmh/benchmark_classes_to_generate.txt"

# Repo remoto corretto (tuo)
REMOTE_WITH_TOKEN="https://Kekkodarco:${ACTIONS_TOKEN:-}@github.com/Kekkodarco/GradleProject.git"

# ===== Utils ==================================================================
sep() { printf '%*s\n' "90" '' | tr ' ' '-'; }

sanitize_line() {
  local s="$1"
  s="${s%$'\r'}"
  printf "%s" "$(echo -n "$s" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
}

ensure_file_or_empty() {
  # crea file vuoto se non esiste (così la pipeline non esplode)
  local f="$1"
  [[ -f "$f" ]] || : > "$f"
}

update_coverage_for_classes_with_retry() {
  # Esegue ./gradlew :app:test solo sulle test-class associate alle classi di produzione modificate.
  # Convenzione: <ProdFQN> -> <ProdFQN>Test
  # Retry fino a 10: in futuro, dentro il loop ci metterai la rigenerazione Chat2UnitTest.

  local -a PROD_CLASSES=("${@}")

  if ((${#PROD_CLASSES[@]} == 0)); then
    echo "[coverage] Nessuna classe modificata: skip."
    return 0
  fi

  local -a TEST_CLASSES=()
  for prod_fqn in "${PROD_CLASSES[@]}"; do
    prod_fqn="$(sanitize_line "$prod_fqn")"
    [[ -z "$prod_fqn" ]] && continue

    local test_fqn="${prod_fqn}Test"
    echo "[coverage] Classe prod: $prod_fqn -> test: $test_fqn"
    TEST_CLASSES+=("$test_fqn")
  done

  if ((${#TEST_CLASSES[@]} == 0)); then
    echo "[coverage] Nessuna test class calcolata: skip."
    return 0
  fi

  local CMD=( "./gradlew" ":app:test" )
  for cls in "${TEST_CLASSES[@]}"; do
    CMD+=( "--tests" "$cls" )
  done

  echo "[coverage] Comando: ${CMD[*]}"

  local MAX_ATTEMPTS=10
  local attempt=1
  local EXIT_CODE=0

  # con set -e, un test fallito ucciderebbe lo script: lo disabilitiamo durante i tentativi
  set +e
  while (( attempt <= MAX_ATTEMPTS )); do
    echo "[coverage] Tentativo $attempt/$MAX_ATTEMPTS..."
    "${CMD[@]}"
    EXIT_CODE=$?

    if (( EXIT_CODE == 0 )); then
      echo "[coverage] OK: test passati al tentativo $attempt."
      break
    fi

    echo "[coverage] KO (exit=$EXIT_CODE)."

    # Placeholder: qui (in futuro) richiamerai Chat2UnitTest per fixare/rigenerare e poi ritenti.
    echo "[coverage] [DRY-RUN] Qui rigenererei/fixerei i test con Chat2UnitTest e riscriverei i file."
    attempt=$((attempt + 1))
  done
  set -e

  if (( EXIT_CODE != 0 )); then
    echo "[coverage] ERRORE: dopo $MAX_ATTEMPTS tentativi i test falliscono ancora. Pipeline KO."
    exit $EXIT_CODE
  fi

  echo "[coverage] Coverage aggiornata (esecuzione test mirati completata)."
}

# ==============================================================================
# STEP A: Git diff -> classi modificate (FQN)
# ==============================================================================
sep
echo "[A] Calcolo classi modificate via git diff..."

current_commit="$(git log --format="%H" -n 1)"
previous_commit="$(git log --format="%H" -n 2 | tail -n 1)"

git_diff="$(git diff -U0 --minimal "$previous_commit" "$current_commit")"

modified_classes=()
while IFS= read -r line; do
  if [[ $line =~ ^\+++\ .*\/main\/java\/(.*\/)?([^\/]+)\.java$ ]]; then
    packages="${BASH_REMATCH[1]}"
    file_name="${BASH_REMATCH[2]}"

    if [[ -n "$packages" ]]; then
      packages="${packages%/}"
      packages="${packages}."
    fi

    class_name="${packages//\//.}${file_name%.java}"
    modified_classes+=("$class_name")
  fi
done <<< "$git_diff"

if ((${#modified_classes[@]} == 0)); then
  echo "[A] Nessuna classe di produzione modificata trovata. Stop."
  exit 0
fi

echo "[A] Classi modificate:"
printf '%s\n' "${modified_classes[@]}"
sep

tmp_classes_file="modified_classes.txt"
printf "%s\n" "${modified_classes[@]}" > "$tmp_classes_file"

# ==============================================================================
# STEP B: AST -> produce files methods (oggi almeno modified; domani 3 file)
# ==============================================================================
echo "[B] Eseguo AST..."
if [[ ! -f "$AST_JAR" ]]; then
  echo "[B] ERRORE: $AST_JAR non trovato. Devi buildare il jar (task shadow/fat jar)."
  exit 1
fi

java -jar "$AST_JAR" "$tmp_classes_file"
rm -f "$tmp_classes_file"

# “Compatibilità”: se oggi AST genera solo modified_methods.txt, non moriamo
ensure_file_or_empty "$MODIFIED_METHODS_FILE"
ensure_file_or_empty "$ADDED_METHODS_FILE"
ensure_file_or_empty "$DELETED_METHODS_FILE"

echo "[B] Output AST:"
echo " - $MODIFIED_METHODS_FILE (righe: $(wc -l < "$MODIFIED_METHODS_FILE" | tr -d ' '))"
echo " - $ADDED_METHODS_FILE    (righe: $(wc -l < "$ADDED_METHODS_FILE" | tr -d ' '))"
echo " - $DELETED_METHODS_FILE  (righe: $(wc -l < "$DELETED_METHODS_FILE" | tr -d ' '))"
sep

# ==============================================================================
# STEP C: Genera input.json per Chat2UnitTest (MODIFIED / ADDED separati)
# ==============================================================================
echo "[C] Genero input.json per Chat2UnitTest con $CHAT2UNITTEST_INPUT_BUILDER_CLASS ..."

if [[ -s "$MODIFIED_METHODS_FILE" ]]; then
  echo "[C] -> $INPUT_MODIFIED_JSON da $MODIFIED_METHODS_FILE"
  java -cp "$AST_JAR" "$CHAT2UNITTEST_INPUT_BUILDER_CLASS" \
    "$MODIFIED_METHODS_FILE" "$PROD_ROOT" "$INPUT_MODIFIED_JSON"
else
  echo "[C] -> modified vuoto: skip $INPUT_MODIFIED_JSON"
  rm -f "$INPUT_MODIFIED_JSON" 2>/dev/null || true
fi

if [[ -s "$ADDED_METHODS_FILE" ]]; then
  echo "[C] -> $INPUT_ADDED_JSON da $ADDED_METHODS_FILE"
  java -cp "$AST_JAR" "$CHAT2UNITTEST_INPUT_BUILDER_CLASS" \
    "$ADDED_METHODS_FILE" "$PROD_ROOT" "$INPUT_ADDED_JSON"
else
  echo "[C] -> added vuoto: skip $INPUT_ADDED_JSON"
  rm -f "$INPUT_ADDED_JSON" 2>/dev/null || true
fi

sep

# ==============================================================================
# STEP D: (DRY-RUN) Chat2UnitTest
# ==============================================================================
echo "[D] Chat2UnitTest (DRY-RUN=${DRY_RUN})"

if [[ -f "$INPUT_MODIFIED_JSON" ]]; then
  echo "[D] MODIFIED: userei $INPUT_MODIFIED_JSON per rigenerare test + eliminare vecchi"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[D] [DRY-RUN] Nessuna rigenerazione reale eseguita."
  else
    echo "[D] TODO: chiamata reale a Chat2UnitTest per MODIFIED"
    # qui metterai la tua chiamata vera
  fi
fi

if [[ -f "$INPUT_ADDED_JSON" ]]; then
  echo "[D] ADDED: userei $INPUT_ADDED_JSON per generare nuovi test"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[D] [DRY-RUN] Nessuna generazione reale eseguita."
  else
    echo "[D] TODO: chiamata reale a Chat2UnitTest per ADDED"
  fi
fi

sep

# ==============================================================================
# STEP E: Coverage-Matrix (oggi: placeholder; domani: aggiorni dopo ADDED/MODIFIED)
# ==============================================================================
echo "[E] Coverage-matrix: $COVERAGE_MATRIX_JSON"
# Anche in DRY_RUN puoi decidere di eseguire i test (serve proprio per aggiornare coverage).
# Quindi NON lo blocco su DRY_RUN: lo blocchiamo solo se vuoi tu.

update_coverage_for_classes_with_retry "${modified_classes[@]}"

sep

# ==============================================================================
# STEP F: Ju2Jmh + Benchmark (oggi: DRY-RUN)
# ==============================================================================
echo "[F] Ju2Jmh (DRY-RUN=${DRY_RUN})"
if [[ "$DRY_RUN" == "1" ]]; then
  echo "[F] [DRY-RUN] Skipping conversione test->benchmark e run JMH."
else
  echo "[F] TODO: qui inserirai conversione ju2jmh e run benchmark selettivi"
fi
sep

# ==============================================================================
# STEP G: Deleted methods (oggi: DRY-RUN)
# ==============================================================================
echo "[G] Deleted methods (DRY-RUN=${DRY_RUN})"
if [[ -s "$DELETED_METHODS_FILE" ]]; then
  echo "[G] Metodi eliminati trovati:"
  cat "$DELETED_METHODS_FILE"
  echo "[G] TODO: per ciascun metodo eliminato -> coverage-matrix -> elimina test"
else
  echo "[G] Nessun metodo eliminato."
fi
sep

# ==============================================================================
# STEP H: Commit & Push (controllati da DRY_RUN e PUSH_ENABLED)
# ==============================================================================
echo "[H] Git commit/push (DRY_RUN=${DRY_RUN}, PUSH_ENABLED=${PUSH_ENABLED})"

git add "$TEST_ROOT" || true
git add "$BENCH_ROOT" || true
git add "$COVERAGE_MATRIX_JSON" || true

if [[ -n "$(git status --porcelain)" ]]; then
  echo "[H] Ci sono modifiche da committare."
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[H] [DRY-RUN] Non faccio commit/push."
  else
    git commit -m "Update tests/benchmarks/coverage for modified classes" || true

    if [[ "$PUSH_ENABLED" == "1" ]]; then
      if [[ -z "${ACTIONS_TOKEN:-}" ]]; then
        echo "[H] ERRORE: ACTIONS_TOKEN non settato, non posso pushare."
        exit 1
      fi
      git remote set-url origin "$REMOTE_WITH_TOKEN"
      git push origin main
      echo "[H] Push completato."
    else
      echo "[H] Push disabilitato (PUSH_ENABLED=0)."
    fi
  fi
else
  echo "[H] Nessuna modifica rilevata."
fi

sep
echo "DONE"
