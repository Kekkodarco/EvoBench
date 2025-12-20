#!/bin/bash
set -euo pipefail

# ===================== Config =================================================
PROD_ROOT="app/src/main/java"
TEST_ROOT="app/src/test/java"
COVERAGE_MATRIX_JSON="app/coverage-matrix.json"

AST_JAR="app/build/libs/app-all.jar"
CHAT2UNITTEST_INPUT_BUILDER_CLASS="Chat2UnitTestInputBuilder"
#attualmente sto usando un percorso locale per chat2unittest, successivamente dovra' essere modificato con una repo di github
export RUN_CHAT2UNITTEST=1
CHAT2UNITTEST_JAR="/c/Users/franc/IdeaProjects/chat2unittest/target/chat2unittest-1.0-SNAPSHOT-jar-with-dependencies.jar"
CHAT2UNITTEST_HOST="https://uncourtierlike-louvered-katelin.ngrok-free.dev/v1/chat/completions"
CHAT2UNITTEST_MODEL="codellama-7b-instruct-hf"
CHAT2UNITTEST_TEMP="0.4"
#numero massimo tentativi generazione test
MAX_CHAT2UNITTEST_ATTEMPTS="${MAX_CHAT2UNITTEST_ATTEMPTS:-5}"

MODIFIED_METHODS_FILE="modified_methods.txt"
ADDED_METHODS_FILE="added_methods.txt"
DELETED_METHODS_FILE="deleted_methods.txt"

INPUT_MODIFIED_JSON="input_modified.json"
INPUT_ADDED_JSON="input_added.json"

TESTS_TO_DELETE_FILE="tests_to_delete.txt"
TESTS_TO_REGENERATE_FILE="tests_to_regenerate.txt"

BENCH_ROOT="ju2jmh/src/jmh/java"

# switch per step futuri (LLM/bench)
RUN_CHAT2UNITTEST="${RUN_CHAT2UNITTEST:-1}"
RUN_JU2JMH="${RUN_JU2JMH:-0}"
RUN_AMBER="${RUN_AMBER:-0}"

# ===================== Utils ==================================================
sep(){ printf '%*s\n' 90 '' | tr ' ' '-'; }

sanitize_line() {
  local s="$1"
  s="${s%$'\r'}"
  printf "%s" "$(echo -n "$s" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
}

fqn_to_test_path() {
  local test_class_fqn="$1"
  echo "$TEST_ROOT/$(echo "$test_class_fqn" | tr '.' '/')".java
}

ensure_file() {
  local f="$1"
  : > "$f"
}

# Estrae classi test uniche da file con righe tipo: banca.ContoBancarioTest.testX
extract_test_classes() {
  local tests_file="$1"
  [[ -s "$tests_file" ]] || return 0

  while IFS= read -r line; do
    line="$(sanitize_line "$line")"
    [[ -z "$line" ]] && continue
    # rimuove solo l'ultimo segmento dopo l'ultimo punto (il nome del metodo test)
    echo "${line%.*}"
  done < "$tests_file" | sort -u
}

# Converte lista di classi test in argomenti gradle: --tests "A" --tests "B"
build_gradle_tests_args() {
  local classes_file="$1"
  local args=()
  while IFS= read -r c; do
    c="$(sanitize_line "$c")"
    [[ -z "$c" ]] && continue
    args+=( --tests "$c" )
  done < "$classes_file"
  printf "%s\n" "${args[@]}"
}

# ===================== Step 1: Modified Classes Extractor =====================
extract_modified_classes() {
  sep
  echo "[1] Extract modified classes via git diff --name-only..."

  local files
  #files="$(git diff --name-only HEAD^ HEAD -- app/src/main/java || true)"
  #files per non effettuare sempre il commit per testare le varie branches
  files="$(git diff --name-only HEAD -- app/src/main/java || true)"

  if [[ -z "${files//[[:space:]]/}" ]]; then
    echo "[1] Nessuna classe modificata in app/src/main/java. Stop."
    exit 0
  fi

  # trasforma app/src/main/java/pkg/Class.java -> pkg.Class
  local -a modified_classes=()
  while IFS= read -r f; do
    f="$(sanitize_line "$f")"
    [[ -z "$f" ]] && continue
    [[ "$f" != *.java ]] && continue

    f="${f#app/src/main/java/}" #rimuove prefisso
    if [[ "$f" != */* ]]; then
      continue
    fi
    f="${f%.java}"                  # rimuove estensione
    f="${f//\//.}"                  # / -> .
    modified_classes+=("$f")
  done <<< "$files"

  # uniq
  mapfile -t modified_classes < <(printf "%s\n" "${modified_classes[@]}" | sort -u)

  printf "%s\n" "${modified_classes[@]}" > modified_classes.txt
  echo "[1] Written modified_classes.txt:"
  cat modified_classes.txt
}

# ===================== Step 2: AST -> 3 files ================================
run_ast() {
  sep
  echo "[2] Run ASTGenerator (creates modified/added/deleted files)..."

  if [[ ! -f "$AST_JAR" ]]; then
    echo "[2] ERROR: $AST_JAR not found. Build fatJar first."
    exit 1
  fi

  # PULIZIA PRIMA
    : > "$MODIFIED_METHODS_FILE"
    : > "$ADDED_METHODS_FILE"
    : > "$DELETED_METHODS_FILE"

  java -jar "$AST_JAR" modified_classes.txt

  echo "[2] Lines:"
  echo " - modified: $(wc -l < "$MODIFIED_METHODS_FILE" | tr -d ' ')"
  echo " - added:    $(wc -l < "$ADDED_METHODS_FILE" | tr -d ' ')"
  echo " - deleted:  $(wc -l < "$DELETED_METHODS_FILE" | tr -d ' ')"
}

# ===================== Step 3: Build input json (MODIFIED/ADDED) ==============
build_inputs() {
  sep
  echo "[3] Build Chat2UnitTest input JSONs..."

  if [[ -s "$MODIFIED_METHODS_FILE" ]]; then
    java -cp "$AST_JAR" "$CHAT2UNITTEST_INPUT_BUILDER_CLASS" \
      "$MODIFIED_METHODS_FILE" "$PROD_ROOT" "$INPUT_MODIFIED_JSON"
    echo "[3] OK: $INPUT_MODIFIED_JSON"
  else
    rm -f "$INPUT_MODIFIED_JSON" 2>/dev/null || true
    echo "[3] No modified methods -> skip $INPUT_MODIFIED_JSON"
  fi

  if [[ -s "$ADDED_METHODS_FILE" ]]; then
    java -cp "$AST_JAR" "$CHAT2UNITTEST_INPUT_BUILDER_CLASS" \
      "$ADDED_METHODS_FILE" "$PROD_ROOT" "$INPUT_ADDED_JSON"
    echo "[3] OK: $INPUT_ADDED_JSON"
  else
    rm -f "$INPUT_ADDED_JSON" 2>/dev/null || true
    echo "[3] No added methods -> skip $INPUT_ADDED_JSON"
  fi
}

# ===================== Branch helpers: Coverage lookup ========================
tests_covering_methods() {
  local methods_file="$1"
  [[ -s "$methods_file" ]] || return 0
  [[ -f "$COVERAGE_MATRIX_JSON" ]] || { echo "[coverage] ERROR: $COVERAGE_MATRIX_JSON not found"; exit 1; }

  while IFS= read -r raw; do
    m="$(sanitize_line "$raw")"
    [[ -z "$m" ]] && continue
    jq -r --arg m "$m" '
      to_entries
      | map(select(.value | index($m)))
      | .[].key
    ' "$COVERAGE_MATRIX_JSON"
  done < "$methods_file" | sort -u
}

# ===================== Branch ii: DELETED =====================================
branch_deleted() {
  sep
  echo "[0] Rebuild coverage-matrix by running MainTestSuite..."
  rm -f app/coverage-matrix.json

  # forza l’esecuzione della suite che genera coverage
  ./gradlew :app:test --tests "suite.MainTestSuite" --rerun-tasks

  if [[ ! -f "app/coverage-matrix.json" ]]; then
    echo "[0] ERROR: app/coverage-matrix.json was not generated!"
    exit 1
  fi

  echo "[0] OK: coverage-matrix generated."
  sep
  echo "[BRANCH ii] DELETED methods -> remove covering tests + benchmarks + update coverage"

  if [[ ! -s "$DELETED_METHODS_FILE" ]]; then
    echo "[BRANCH ii] No deleted methods. Skip."
    return 0
  fi

  # 1) Coverage lookup: methods deleted -> test methods to delete
  tests_covering_methods "$DELETED_METHODS_FILE" > "$TESTS_TO_DELETE_FILE" || true

  echo "[BRANCH ii] Test methods to delete (from coverage-matrix):"
  if [[ -s "$TESTS_TO_DELETE_FILE" ]]; then
    cat "$TESTS_TO_DELETE_FILE"
  else
    echo "(none)"
    return 0
  fi

  # 2) Remove JUnit test methods precisely (NOT whole class)
  echo "[BRANCH ii] Pruning JUnit test methods from $TEST_ROOT ..."
  java -cp "$AST_JAR" TestPruner "$TESTS_TO_DELETE_FILE" "$TEST_ROOT"

  # 3) Remove benchmark methods precisely (benchmark_<testMethod>) from inner class _Benchmark
  echo "[BRANCH ii] Pruning benchmark methods from $BENCH_ROOT ..."
  java -cp "$AST_JAR" BenchmarkPruner "$TESTS_TO_DELETE_FILE" "$BENCH_ROOT"

  # 4) Update coverage-matrix: remove entries whose key is a deleted test method
  echo "[BRANCH ii] Updating coverage-matrix (removing deleted test entries)..."

  # Build jq del list: del(.["k1"], .["k2"], ...)
  del_args="$(awk '
    NF>0 { gsub(/"/, "\\\""); printf ".[%c%s%c],", 34, $0, 34 }
  ' "$TESTS_TO_DELETE_FILE")"
  del_args="${del_args%,}"

  tmp_cov="$(mktemp)"
  jq "del($del_args)" "$COVERAGE_MATRIX_JSON" > "$tmp_cov"
  mv "$tmp_cov" "$COVERAGE_MATRIX_JSON"

  echo "[BRANCH ii] Done."
}

# ===================== Branch i: MODIFIED =====================================
branch_modified() {
  sep
  echo "[BRANCH i] MODIFIED methods -> find covering tests, prune, regenerate (retry max=$MAX_CHAT2UNITTEST_ATTEMPTS)"

  if [[ ! -s "$MODIFIED_METHODS_FILE" ]]; then
    echo "[BRANCH i] No modified methods. Skip."
    return 0
  fi

  # 1) Lookup coverage-matrix → test da rigenerare
  tests_covering_methods "$MODIFIED_METHODS_FILE" > "$TESTS_TO_REGENERATE_FILE" || true

  echo "[BRANCH i] Tests covering modified methods:"
  if [[ -s "$TESTS_TO_REGENERATE_FILE" ]]; then
    cat "$TESTS_TO_REGENERATE_FILE"
  else
    echo "(none) -> nothing to regenerate"
    return 0
  fi

  # 2) Input per Chat2UnitTest (debug)
  echo "[BRANCH i] Input for Chat2UnitTest:"
  [[ -f "$INPUT_MODIFIED_JSON" ]] && cat "$INPUT_MODIFIED_JSON" || echo "(missing input json)"

  if [[ "$RUN_CHAT2UNITTEST" != "1" ]]; then
    echo "[BRANCH i] RUN_CHAT2UNITTEST=0 -> skip regeneration."
    return 0
  fi

  # 3) Classi test da validare (solo quelle rigenerate)
  local test_classes_file
  test_classes_file="$(mktemp)"
  extract_test_classes "$TESTS_TO_REGENERATE_FILE" > "$test_classes_file"

  echo "[BRANCH i] Test classes to validate:"
  cat "$test_classes_file"

  # 4) Prune vecchi test JUnit + vecchi benchmark (una volta sola prima dei tentativi)
  echo "[BRANCH i] Pruning old JUnit test methods..."
  java -cp "$AST_JAR" TestPruner "$TESTS_TO_REGENERATE_FILE" "$TEST_ROOT"

  echo "[BRANCH i] Pruning old benchmark methods..."
  java -cp "$AST_JAR" BenchmarkPruner "$TESTS_TO_REGENERATE_FILE" "$BENCH_ROOT"

  # 5) Retry loop
  local attempt=1
  while [[ "$attempt" -le "$MAX_CHAT2UNITTEST_ATTEMPTS" ]]; do
    sep
    echo "[BRANCH i] Attempt $attempt/$MAX_CHAT2UNITTEST_ATTEMPTS"

    # (Consigliato) elimina i file delle classi test coinvolte prima di rigenerare
    while IFS= read -r cls; do
      cls="$(sanitize_line "$cls")"
      [[ -z "$cls" ]] && continue
      tf="$(fqn_to_test_path "$cls")"
      if [[ -f "$tf" ]]; then
        rm -f "$tf"
        echo "[BRANCH i] Deleted old test file: $tf"
      fi
    done < "$test_classes_file"

    # 5a) Rigenera test con Chat2UnitTest
    echo "[BRANCH i] Running Chat2UnitTest..."
    java -jar "$CHAT2UNITTEST_JAR" "$INPUT_MODIFIED_JSON" \
      -host "$CHAT2UNITTEST_HOST" \
      -mdl "$CHAT2UNITTEST_MODEL" \
      -tmp "$CHAT2UNITTEST_TEMP"

    # Guard: ensure expected regenerated test classes exist before compiling whole test suite
    local missing=0
    while IFS= read -r cls; do
       cls="$(sanitize_line "$cls")"
       [[ -z "$cls" ]] && continue

       tf="$(fqn_to_test_path "$cls")"
       if [[ ! -s "$tf" ]]; then
         echo "[BRANCH i] Missing/empty regenerated test file: $tf"
         missing=1
         continue
       fi

       simple="${cls##*.}"  # ContoBancarioTest
       if ! grep -qE "public[[:space:]]+class[[:space:]]+$simple\\b" "$tf"; then
         echo "[BRANCH i] Regenerated file does not declare expected public class $simple: $tf"
         missing=1
       fi
    done < "$test_classes_file"

    if [[ "$missing" -eq 1 ]]; then
       echo "[BRANCH i] Regeneration incomplete -> skip gradle for this attempt."
       attempt=$((attempt+1))
       continue
    fi

    # 5b) Valida SOLO le classi rigenerate
    echo "[BRANCH i] Validating regenerated tests (only affected classes)..."
    mapfile -t gradle_args < <(build_gradle_tests_args "$test_classes_file")

    if ./gradlew :app:test --rerun-tasks "${gradle_args[@]}"; then
      echo "[BRANCH i] Attempt $attempt succeeded. Regenerated tests are valid."
      rm -f "$test_classes_file" 2>/dev/null || true
      return 0
    fi

    echo "[BRANCH i]  Attempt $attempt failed."
    attempt=$((attempt+1))
  done

  sep
  echo "[BRANCH i]  FAILED: Chat2UnitTest did not produce passing tests after $MAX_CHAT2UNITTEST_ATTEMPTS attempts."
  echo "[BRANCH i] Pipeline must fail and CI should NOT commit generated files."

  # In CI: ripulisci le modifiche (così la repo resta sul commit originale)
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "[BRANCH i] Restoring working tree changes (tests + benches)..."
    git restore "$TEST_ROOT" "$BENCH_ROOT" 2>/dev/null || true
  fi

  rm -f "$test_classes_file" 2>/dev/null || true
  exit 1
}

# ===================== Branch iii: ADDED ======================================
branch_added() {
  sep
  echo "[BRANCH iii] ADDED methods -> generate tests, update coverage, convert to bench"

  if [[ ! -s "$ADDED_METHODS_FILE" ]]; then
    echo "[BRANCH iii] No added methods. Skip."
    return 0
  fi

  echo "[BRANCH iii] Input for Chat2UnitTest:"
  [[ -f "$INPUT_ADDED_JSON" ]] && cat "$INPUT_ADDED_JSON" || echo "(missing input json)"

  if [[ "$RUN_CHAT2UNITTEST" == "1" ]]; then
    echo "[BRANCH iii] TODO: call Chat2UnitTest for ADDED using $INPUT_ADDED_JSON"
    echo "[BRANCH iii] TODO: run targeted tests to update coverage-matrix"
  else
    echo "[BRANCH iii] RUN_CHAT2UNITTEST=0 -> skip (structure ready)."
  fi
}

# ===================== MAIN ===================================================
extract_modified_classes
run_ast
build_inputs

# 3-way branches (final structure)
#branch_deleted
branch_modified
#branch_added

sep
echo "PIPELINE STRUCTURE COMPLETED."
