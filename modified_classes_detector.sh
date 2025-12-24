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
MAX_CHAT2UNITTEST_ATTEMPTS="${MAX_CHAT2UNITTEST_ATTEMPTS:-10}"

MODIFIED_METHODS_FILE="modified_methods.txt"
ADDED_METHODS_FILE="added_methods.txt"
DELETED_METHODS_FILE="deleted_methods.txt"

INPUT_MODIFIED_JSON="input_modified.json"
INPUT_ADDED_JSON="input_added.json"

TESTS_TO_DELETE_FILE="tests_to_delete.txt"
TESTS_TO_REGENERATE_FILE="tests_to_regenerate.txt"

BENCH_ROOT="ju2jmh/src/jmh/java"

JU2JMH_CONVERTER_JAR="./ju-to-jmh/converter-all.jar"
JU2JMH_CLASSES_FILE="./ju2jmh/benchmark_classes_to_generate.txt"
JU2JMH_OUT_DIR="./ju2jmh/src/jmh/java"
APP_TEST_SRC_DIR="./app/src/test/java"
APP_TEST_CLASSES_DIR="./app/build/classes/java/test"

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

generate_jmh_for_testclass() {
  local test_class_fqn="$1"   # es: utente.UtenteTest

# skip non-benchmarkable/support classes
  if [[ "$test_class_fqn" == listener.* || "$test_class_fqn" == suite.* || "$test_class_fqn" == *Suite* ]]; then
    echo "[JMH] Skip conversion for support class: $test_class_fqn"
    return 0
  fi

  if [[ -z "$test_class_fqn" ]]; then
    echo "[JMH] Missing test_class_fqn"
    return 1
  fi

  if [[ ! -f "$JU2JMH_CONVERTER_JAR" ]]; then
    echo "[JMH] Missing converter jar: $JU2JMH_CONVERTER_JAR"
    return 1
  fi

  # serve perché il converter usa le classi compilate dei test
  if [[ ! -d "$APP_TEST_CLASSES_DIR" ]]; then
    echo "[JMH] Missing compiled test classes dir: $APP_TEST_CLASSES_DIR"
    echo "[JMH] (Did :app:test run?)"
    return 1
  fi

  echo "[JMH] Generating benchmark for: $test_class_fqn"

  local tmp_classes_file
  tmp_classes_file="$(mktemp)"
  : > "$tmp_classes_file"
  echo "$test_class_fqn" >> "$tmp_classes_file"

  echo "[JMH] class-names-file content:"
  cat "$tmp_classes_file"

  if ! java -jar "$JU2JMH_CONVERTER_JAR" \
      "$APP_TEST_SRC_DIR/" \
      "$APP_TEST_CLASSES_DIR/" \
      "$JU2JMH_OUT_DIR/" \
      --class-names-file="$tmp_classes_file"; then
    echo "[JMH] Converter failed for $test_class_fqn"
    rm -f "$tmp_classes_file" 2>/dev/null || true
    return 1
  fi

  rm -f "$tmp_classes_file" 2>/dev/null || true

  # verifica compilazione modulo JMH
  if ! ./gradlew :ju2jmh:jmhJar --rerun-tasks; then
    echo "[JMH] jmhJar failed after conversion for $test_class_fqn"
    return 1
  fi

  echo "[JMH] OK: benchmark generated and jmhJar built for $test_class_fqn"
  return 0
}

merge_generated_tests() {
  local test_file="$1"
  local tests_to_regen_file="$2"
  local gen_file="${test_file%.java}.generated.java"
  local bak_file="${test_file}.bak"

  # 0) serve il generated
  if [[ ! -f "$gen_file" ]]; then
    echo "[MERGE] Missing generated file: $gen_file"
    return 1
  fi

  # 1) ripristina target se manca ma c'è backup
  if [[ ! -f "$test_file" && -f "$bak_file" ]]; then
    mv "$bak_file" "$test_file"
    echo "[MERGE] Restored backup as target: $test_file"
  fi

  # 2) se target non esiste, crea scheletro minimo
  if [[ ! -f "$test_file" ]]; then
    local pkg cls
    pkg="$(grep -m1 -E '^[[:space:]]*package[[:space:]]+' "$gen_file" | sed -E 's/^[[:space:]]*package[[:space:]]+([^;]+);.*/\1/')"
    cls="$(basename "$test_file" .java)"
    {
      [[ -n "$pkg" ]] && echo "package $pkg;"
      echo
      echo "public class $cls {"
      echo "}"
    } > "$test_file"
    echo "[MERGE] Created empty target skeleton: $test_file"
  fi

  local tmp_methods tmp_names
  tmp_methods="$(mktemp)"
  tmp_names="$(mktemp)"

  # 3) Estrai metodi di test dal generated (robusto con perl)
  perl -0777 -ne '
    while (m/^[ \t]*@(?:[A-Za-z0-9_.]*\.)?Test\b[^\n]*\n
             (?:^[ \t]*@.*\n)*            # eventuali altre annotation
             ^[ \t]*public[ \t]+void[ \t]+[A-Za-z0-9_]+[ \t]*\([^)]*\)[ \t]*\{
             .*?
             ^[ \t]*\}
          /gmsx) {
      print "$&\n\n";
    }
  ' "$gen_file" > "$tmp_methods"

  # ===== FIX A: dedup dei metodi di test nel generated per NOME =====
  # Se Chat2UnitTest genera due blocchi @Test con lo stesso nome metodo, ne teniamo uno solo.
  perl -0777 -i -pe '
    my %seen;
    my @blocks = split(/\n\s*\n/, $_);
    my @out;
    for my $b (@blocks) {
      if ($b =~ /public\s+void\s+(\w+)\s*\(/) {
        my $n = $1;
        next if $seen{$n}++;
      }
      push @out, $b;
    }
    $_ = join("\n\n", @out) . "\n";
  ' "$tmp_methods"

  # Rimuovi metodi che usano package palesemente errati generati dall'LLM
  grep -vE 'it\.unibo\.oop\.|it\.utente\.' "$tmp_methods" > "${tmp_methods}.f" \
    && mv "${tmp_methods}.f" "$tmp_methods"

  # ===== FIX C: se il generated NON produce i nomi target, rinomina =====
  # Per ogni nome target (tmp_names), se non esiste in tmp_methods,
  # rinominiamo il primo metodo disponibile a quel nome.
  while IFS= read -r need; do
    need="$(sanitize_line "$need")"
    [[ -z "$need" ]] && continue

    if ! grep -qE "public[[:space:]]+void[[:space:]]+$need[[:space:]]*\(" "$tmp_methods"; then
      first="$(grep -m1 -E 'public[[:space:]]+void[[:space:]]+[A-Za-z0-9_]+' "$tmp_methods" \
                | sed -E 's/.*void[[:space:]]+([A-Za-z0-9_]+).*/\1/')"

      if [[ -n "$first" ]]; then
        sed -i.bak -E "0,/public[[:space:]]+void[[:space:]]+$first[[:space:]]*\(/s//public void $need(/" "$tmp_methods"
        rm -f "${tmp_methods}.bak" 2>/dev/null || true
      fi
    fi
  done < "$tmp_names"

  # Nomi target da rigenerare = quelli nella coverage-matrix (tests_to_regen_file)
  # es: utente.personale.TecnicoTest.testSetName -> testSetName
  awk -F. '{print $NF}' "$tests_to_regen_file" | sed 's/\r$//' | sort -u > "$tmp_names"

  if [[ ! -s "$tmp_methods" || ! -s "$tmp_names" ]]; then
    echo "[MERGE] No @Test methods found in generated: $gen_file"
    echo "[MERGE] Debug: first 120 lines of generated:"
    sed -n '1,120p' "$gen_file" || true
    echo "[MERGE] Debug: lines with '@' or 'void':"
    grep -nE '(@|void[[:space:]]+[A-Za-z0-9_]+\s*\()' "$gen_file" | head -n 120 || true
    rm -f "$tmp_methods" "$tmp_names"
    return 1
  fi

  # 4) Prune dal target i metodi @Test con lo stesso nome (no duplicati)
  local tmp_pruned
  tmp_pruned="$(mktemp)"

  awk -v names_file="$tmp_names" '
    BEGIN{
      while((getline n < names_file)>0){
        gsub(/\r/,"",n);
        names[n]=1
      }
      close(names_file)
      inCandidate=0
      inSkip=0
      started=0
      brace=0
      methodname=""
      buf=""
    }

    function extract_name(line,   t){
      if(line ~ /^[[:space:]]*public[[:space:]]+void[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\(/){
        t=line
        sub(/.*void[[:space:]]+/,"",t)
        sub(/\(.*/,"",t)
        gsub(/[[:space:]]+/,"",t)
        return t
      }
      return ""
    }

    # start candidate on @Test
    {
      if(inSkip==0 && inCandidate==0 && $0 ~ /^[[:space:]]*@([a-zA-Z0-9_.]*\.)?Test\b/){
        inCandidate=1
        buf=$0 "\n"
        started=0
        brace=0
        methodname=""
        next
      }

      if(inCandidate==1){
        buf = buf $0 "\n"
        if(methodname=="" ){
          methodname = extract_name($0)
          if(methodname!="" && (methodname in names)){
            # skip this whole method block
            inSkip=1
            inCandidate=0
            # count braces only after first "{"
            if($0 ~ /\{/) started=1
            if(started==1){
              brace += gsub(/\{/,"{")
              brace -= gsub(/\}/,"}")
              if(brace==0){ inSkip=0 } # one-liner method (rare)
            }
            next
          }
        }

        # Not a target method -> flush candidate buffer and continue as normal
        printf "%s", buf
        inCandidate=0
        buf=""
        next
      }

      if(inSkip==1){
        if(started==0 && $0 ~ /\{/) started=1
        if(started==1){
          brace += gsub(/\{/,"{")
          brace -= gsub(/\}/,"}")
          if(brace==0){ inSkip=0 }
        }
        next
      }

      print
    }
  ' "$test_file" > "$tmp_pruned"

  mv "$tmp_pruned" "$test_file"

  # ===== FIX B: evita di INSERIRE metodi che esistono già nel target =====
  # Se un metodo esiste già e NON è tra quelli da sostituire (tmp_names),
  # lo scartiamo da tmp_methods per evitare "method already defined".
  local tmp_existing
  tmp_existing="$(mktemp)"

  grep -E '^[[:space:]]*public[[:space:]]+void[[:space:]]+[A-Za-z0-9_]+\s*\(' "$test_file" \
    | sed -E 's/.*void[[:space:]]+([A-Za-z0-9_]+).*/\1/' \
    | sort -u > "$tmp_existing"

  EXISTING="$tmp_existing" REPLACE="$tmp_names" perl -0777 -i -pe '
    use strict;
    my %existing;
    my %replace;

    open my $e, "<", $ENV{EXISTING} or die $!;
    while(<$e>){ chomp; $existing{$_}=1 if $_ ne "" }
    close $e;

    open my $r, "<", $ENV{REPLACE} or die $!;
    while(<$r>){ chomp; $replace{$_}=1 if $_ ne "" }
    close $r;

    my @blocks = split(/\n\s*\n/, $_);
    my @out;

    for my $b (@blocks){
      if($b =~ /public\s+void\s+(\w+)\s*\(/){
        my $n=$1;
        # se esiste già nel target e non è in replace => non inserirlo
        next if ($existing{$n} && !$replace{$n});
      }
      push @out, $b;
    }

    $_ = join("\n\n", @out) . "\n";
  ' "$tmp_methods"

  rm -f "$tmp_existing" 2>/dev/null || true

  # 5) Inserisci i nuovi metodi prima dell’ultima }
  local tmp_out
  tmp_out="$(mktemp)"
  awk -v addfile="$tmp_methods" '
    {lines[NR]=$0}
    END{
      last=NR
      for(i=NR;i>=1;i--){
        if(lines[i] ~ /^[[:space:]]*}[[:space:]]*$/){ last=i; break }
      }
      for(i=1;i<last;i++) print lines[i]
      print ""
      while((getline l < addfile)>0) print l
      close(addfile)
      for(i=last;i<=NR;i++) print lines[i]
    }
  ' "$test_file" > "$tmp_out"

  mv "$tmp_out" "$test_file"

  rm -f "$tmp_methods" "$tmp_names"
  rm -f "$gen_file"

  # ===== FIX import static Assert.* se servono assertNull/assertTrue/etc =====
  # Se il file usa assertNull e non ha Assert.* allora forza Assert.*.
  if grep -qE '\bassertNull\s*\(' "$test_file"; then
    if ! grep -qE 'import[[:space:]]+static[[:space:]]+org\.junit\.Assert\.\*;' "$test_file"; then
      # Se c'è un import static specifico (es. assertEquals), lo rimpiazzo con Assert.*
      if grep -qE 'import[[:space:]]+static[[:space:]]+org\.junit\.Assert\.' "$test_file"; then
        sed -i.bak -E \
          's/import[[:space:]]+static[[:space:]]+org\.junit\.Assert\.[A-Za-z0-9_]+\s*;/import static org.junit.Assert.*;/' \
          "$test_file" || true
        rm -f "${test_file}.bak" 2>/dev/null || true
      else
        awk '
          BEGIN{added=0}
          {
            print
            if($0 ~ /^import /) lastImportLine=NR
            if($0 ~ /^package /) pkgLine=NR
            lines[NR]=$0
          }
          END{
            # (non usiamo lines qui, ma teniamo pkgLine per logica)
          }
        ' "$test_file" > /dev/null

        awk '
          BEGIN{added=0; sawImport=0}
          /^import / {sawImport=1}
          {print}
          # quando finisce la zona import (prima riga non-import dopo almeno un import)
          (sawImport==1 && $0 !~ /^import / && added==0){
            print "import static org.junit.Assert.*;"
            added=1
          }
          END{
            # se non c erano import, inseriscilo dopo package (cioè lo mettiamo in testa qui)
            # ma per non rischiare import prima del package, se added==0 NON facciamo nulla:
            # in quel caso conviene lasciare stare o gestire con sed mirata.
          }
        ' "$test_file" > "${test_file}.tmp" && mv "${test_file}.tmp" "$test_file"
      fi
    fi
  fi

  echo "[MERGE] Replaced/added regenerated @Test methods into: $test_file"
  return 0
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
  echo "[BRANCH i] MODIFIED methods -> per-entry regeneration (retry max=$MAX_CHAT2UNITTEST_ATTEMPTS)"

  if [[ ! -s "$MODIFIED_METHODS_FILE" ]]; then
    echo "[BRANCH i] No modified methods. Skip."
    return 0
  fi

  echo "[BRANCH i] Input for Chat2UnitTest:"
  [[ -f "$INPUT_MODIFIED_JSON" ]] && cat "$INPUT_MODIFIED_JSON" || { echo "(missing input json)"; return 1; }

  if [[ "$RUN_CHAT2UNITTEST" != "1" ]]; then
    echo "[BRANCH i] RUN_CHAT2UNITTEST=0 -> skip regeneration."
    return 0
  fi

  # ---- helper: derive production class FQN from file path ----
  derive_prod_fqn_from_path() {
    local fp="$1"
    local norm="${fp//\\//}"
    local marker="/src/main/java/"
    [[ "$norm" == *"$marker"* ]] || return 1
    local tail="${norm#*${marker}}"
    tail="${tail%.java}"
    echo "${tail//\//.}"
  }

  # ---- iterate each entry (file) in input_modified.json ----
  mapfile -t prod_files < <(jq -r 'keys[]' "$INPUT_MODIFIED_JSON" | sed 's/\r$//')
  if [[ "${#prod_files[@]}" -eq 0 ]]; then
    echo "[BRANCH i] input_modified.json has no entries. Skip."
    return 0
  fi

  echo "[BRANCH i] Entries to process: ${#prod_files[@]}"

  for prod_fp in "${prod_files[@]}"; do
    prod_fp="$(sanitize_line "$prod_fp")"
    sep
    echo "[BRANCH i] Processing entry: $prod_fp"

    # methods for this file (safe on null)
    mapfile -t methods_for_file < <(jq -r --arg fp "$prod_fp" '.[$fp] // [] | .[]' "$INPUT_MODIFIED_JSON" | sed 's/\r$//')
    if [[ "${#methods_for_file[@]}" -eq 0 ]]; then
      echo "[BRANCH i] No methods for $prod_fp -> skip entry."
      continue
    fi

    # Build a single-entry JSON for this file
    local single_json
    single_json="$(mktemp)"
    jq -n --arg fp "$prod_fp" --slurpfile all "$INPUT_MODIFIED_JSON" \
      '{($fp): ($all[0][$fp] // [])}' > "$single_json"

    echo "[BRANCH i] Single-entry JSON:"
    cat "$single_json"

    # Build temp methods file: <ClassFQN>.<method>
    local class_fqn
    class_fqn="$(derive_prod_fqn_from_path "$prod_fp")" || {
      echo "[BRANCH i] ERROR: cannot derive class FQN from path: $prod_fp"
      rm -f "$single_json" 2>/dev/null || true
      return 1
    }

    local tmp_methods_file
    tmp_methods_file="$(mktemp)"
    : > "$tmp_methods_file"
    for m in "${methods_for_file[@]}"; do
      m="$(sanitize_line "$m")"
      [[ -z "$m" ]] && continue
      echo "${class_fqn}.${m}" >> "$tmp_methods_file"
    done

    echo "[BRANCH i] Methods (for coverage lookup):"
    cat "$tmp_methods_file"

    # 1) Lookup coverage-matrix → tests to regenerate (for THIS entry only)
    local tmp_tests_to_regen
    tmp_tests_to_regen="$(mktemp)"
    tests_covering_methods "$tmp_methods_file" > "$tmp_tests_to_regen" || true

    # Filter: keep only tests belonging to this production class
    local expected_test_class="${class_fqn}Test"   # e.g., utente.UtenteTest
    local filtered_tests
    filtered_tests="$(mktemp)"
    awk -v pref="${expected_test_class}." 'index($0, pref)==1 { print $0 }' "$tmp_tests_to_regen" > "$filtered_tests"
    mv "$filtered_tests" "$tmp_tests_to_regen"

    echo "[BRANCH i] Tests covering these methods:"
    if [[ -s "$tmp_tests_to_regen" ]]; then
      cat "$tmp_tests_to_regen"
    else
      echo "(none) -> nothing to regenerate for this entry"
      rm -f "$single_json" "$tmp_methods_file" "$tmp_tests_to_regen" 2>/dev/null || true
      continue
    fi

    # 2) Test classes to validate for this entry
    local test_classes_file
    test_classes_file="$(mktemp)"
    extract_test_classes "$tmp_tests_to_regen" > "$test_classes_file"

    echo "[BRANCH i] Test classes to validate (this entry):"
    cat "$test_classes_file"

    # 3) Prune JUnit test methods for THIS entry (bench prune is done only on success)
    echo "[BRANCH i] Pruning old JUnit test methods (this entry)..."
    java -cp "$AST_JAR" TestPruner "$tmp_tests_to_regen" "$TEST_ROOT"

    # 4) Retry loop for THIS entry
    local attempt=1
    while [[ "$attempt" -le "$MAX_CHAT2UNITTEST_ATTEMPTS" ]]; do
      sep
      echo "[BRANCH i] Entry attempt $attempt/$MAX_CHAT2UNITTEST_ATTEMPTS for $class_fqn"

      # Backup old test files involved for this entry
      unset backups
      declare -A backups=()
      while IFS= read -r cls; do
        cls="$(sanitize_line "$cls")"
        [[ -z "$cls" ]] && continue

        local tf bak
        tf="$(fqn_to_test_path "$cls")"
        if [[ -f "$tf" ]]; then
          bak="${tf}.bak"
          mv "$tf" "$bak"
          backups["$tf"]="$bak"
          echo "[BRANCH i] Moved old test file to backup: $bak"
        fi
      done < "$test_classes_file"

      # Run Chat2UnitTest ONLY for this entry
      echo "[BRANCH i] Running Chat2UnitTest (single entry)..."
      java -jar "$CHAT2UNITTEST_JAR" "$single_json" \
        -host "$CHAT2UNITTEST_HOST" \
        -mdl "$CHAT2UNITTEST_MODEL" \
        -tmp "$CHAT2UNITTEST_TEMP"

      # =========================
      # MERGE generated -> target
      # (MUST happen BEFORE guard/gradle)
      # =========================
      local merge_failed=0
      while IFS= read -r cls; do
        cls="$(sanitize_line "$cls")"
        [[ -z "$cls" ]] && continue
        local tf
        tf="$(fqn_to_test_path "$cls")"
        if ! merge_generated_tests "$tf" "$tmp_tests_to_regen"; then
          echo "[BRANCH i] Merge failed for $tf"
          merge_failed=1
        fi
      done < "$test_classes_file"

      if [[ "$merge_failed" -eq 1 ]]; then
        echo "[BRANCH i] Merge failed -> restoring backups and skipping gradle for this attempt."
        for tf in "${!backups[@]}"; do
          local bak="${backups[$tf]}"
          [[ -f "$bak" ]] && mv "$bak" "$tf"
        done
        attempt=$((attempt+1))
        continue
      fi

      # =========================
      # Guard: AFTER merge
      # =========================
      local missing=0
      while IFS= read -r cls; do
        cls="$(sanitize_line "$cls")"
        [[ -z "$cls" ]] && continue

        local tf simple expected_pkg
        tf="$(fqn_to_test_path "$cls")"
        expected_pkg="${cls%.*}"
        simple="${cls##*.}"

        if [[ ! -s "$tf" ]]; then
          echo "[BRANCH i] Missing/empty merged test file: $tf"
          missing=1
          continue
        fi

        if ! grep -qE "^[[:space:]]*package[[:space:]]+$expected_pkg[[:space:]]*;" "$tf"; then
          echo "[BRANCH i] Wrong/missing package (expected 'package $expected_pkg;'): $tf"
          missing=1
        fi

        if ! grep -qE "public[[:space:]]+class[[:space:]]+$simple\\b" "$tf"; then
          echo "[BRANCH i] Missing expected public class $simple in: $tf"
          missing=1
        fi
      done < "$test_classes_file"

      if [[ "$missing" -eq 1 ]]; then
        echo "[BRANCH i] Regeneration incomplete -> restoring backups and skipping gradle for this attempt."
        for tf in "${!backups[@]}"; do
          local bak="${backups[$tf]}"
          [[ -f "$bak" ]] && mv "$bak" "$tf"
        done
        attempt=$((attempt+1))
        continue
      fi

      # =========================
      # Guard: required test methods must exist after merge
      # =========================
      local missing_methods=0
      while IFS= read -r t; do
        t="$(sanitize_line "$t")"
        [[ -z "$t" ]] && continue

        local cls="${t%.*}"       # es: utente.personale.TecnicoTest
        local m="${t##*.}"        # es: testSetName
        local tf
        tf="$(fqn_to_test_path "$cls")"

        if [[ ! -f "$tf" ]]; then
          echo "[BRANCH i] Missing test file when checking methods: $tf"
          missing_methods=1
          continue
        fi

        # metodo esiste?
        if ! grep -qE "public[[:space:]]+void[[:space:]]+$m[[:space:]]*\(" "$tf"; then
          echo "[BRANCH i] Missing required test method '$m' in: $tf"
          missing_methods=1
          continue
        fi

        # @Test presente vicino al metodo
        if ! awk -v meth="$m" '
            {buf[NR]=$0}
            /public[[:space:]]+void[[:space:]]+/{
              if($0 ~ ("public[[:space:]]+void[[:space:]]+" meth "[[:space:]]*\\(")){
                for(i=NR-6;i<=NR;i++){
                  if(i>0 && buf[i] ~ /^[[:space:]]*@Test\b/){ found=1 }
                }
                if(found!=1){ exit 2 } else { exit 0 }
              }
            }
            END{ exit 1 }
          ' "$tf"; then
          rc=$?
          if [[ "$rc" -eq 2 ]]; then
            echo "[BRANCH i] Method '$m' exists but is missing @Test near it in: $tf"
          else
            echo "[BRANCH i] Could not confirm @Test for '$m' in: $tf"
          fi
          missing_methods=1
        fi
      done < "$tmp_tests_to_regen"

      if [[ "$missing_methods" -eq 1 ]]; then
        echo "[BRANCH i] Missing required test methods -> restoring backups and retrying."
        for tf in "${!backups[@]}"; do
          bak="${backups[$tf]}"
          [[ -f "$bak" ]] && mv "$bak" "$tf"
        done
        attempt=$((attempt+1))
        continue
      fi

      # Validate ONLY these classes
      echo "[BRANCH i] Validating regenerated tests (only affected classes for this entry)..."
      mapfile -t gradle_args < <(build_gradle_tests_args "$test_classes_file")

      if ./gradlew :app:test --rerun-tasks "${gradle_args[@]}"; then
        echo "[BRANCH i] Entry $class_fqn succeeded on attempt $attempt."

        # Now prune old benchmark methods (this entry) and regenerate JMH for OWNER test class
        echo "[BRANCH i] Pruning old benchmark methods (this entry)..."
        java -cp "$AST_JAR" BenchmarkPruner "$tmp_tests_to_regen" "$BENCH_ROOT"

        local owner_test_class="${class_fqn}Test"   # e.g., utente.UtenteTest
        if ! generate_jmh_for_testclass "$owner_test_class"; then
          echo "[BRANCH i] JMH conversion failed for $owner_test_class -> failing pipeline."
          exit 1
        fi

        # delete backups only on success
        for tf in "${!backups[@]}"; do
          local bak="${backups[$tf]}"
          [[ -f "$bak" ]] && rm -f "$bak"
        done

        break
      fi

      echo "[BRANCH i] Entry $class_fqn attempt $attempt failed."
      echo "[BRANCH i] Debug: showing merged test file(s) head (first 160 lines):"
      while IFS= read -r cls; do
        cls="$(sanitize_line "$cls")"
        [[ -z "$cls" ]] && continue
        local tf
        tf="$(fqn_to_test_path "$cls")"
        if [[ -f "$tf" ]]; then
          echo "----- $tf (first 160 lines) -----"
          sed -n '1,160p' "$tf" || true
          echo "---------------------------------"
        else
          echo "----- $tf (missing) -----"
        fi
      done < "$test_classes_file"

      # restore backups after failed attempt
      for tf in "${!backups[@]}"; do
        local bak="${backups[$tf]}"
        [[ -f "$bak" ]] && mv "$bak" "$tf"
      done

      attempt=$((attempt+1))
    done

    if [[ "$attempt" -gt "$MAX_CHAT2UNITTEST_ATTEMPTS" ]]; then
      echo "[BRANCH i] FAILED entry $class_fqn after $MAX_CHAT2UNITTEST_ATTEMPTS attempts."
      echo "[BRANCH i] Pipeline must fail and CI should NOT commit generated files."

      if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "[BRANCH i] Restoring working tree changes (tests + benches)..."
        git restore "$TEST_ROOT" "$BENCH_ROOT" 2>/dev/null || true
      fi

      rm -f "$single_json" "$tmp_methods_file" "$tmp_tests_to_regen" "$test_classes_file" 2>/dev/null || true
      exit 1
    fi

    # cleanup per-entry temp files
    rm -f "$single_json" "$tmp_methods_file" "$tmp_tests_to_regen" "$test_classes_file" 2>/dev/null || true
  done

  echo "[BRANCH i] All entries succeeded."
  return 0
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
