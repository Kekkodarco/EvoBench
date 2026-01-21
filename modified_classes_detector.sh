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
MAX_CHAT2UNITTEST_ATTEMPTS="${MAX_CHAT2UNITTEST_ATTEMPTS:-7}"

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

capitalize_first() {
  local s="$1"
  [[ -z "$s" ]] && { echo ""; return; }
  echo "${s^}"
}
# Build REQUIRED_TESTS_FILE synthetic for ADDED:
# input:
#   test_class_fqn = utente.personale.TecnicoTest
#   methods_file   = file con metodi PROD (uno per riga): getName, setName, ...
# output:
#   stampa path del file creato (tmp)
build_required_tests_for_methods() {
  local test_class_fqn="$1"
  local methods_file="$2"

  local out
  out="$(mktemp)"
  : > "$out"

  while IFS= read -r m; do
    m="$(sanitize_line "$m")"
    [[ -z "$m" ]] && continue
    # test + capitalize_first(method)
    echo "${test_class_fqn}.test$(capitalize_first "$m")" >> "$out"
  done < "$methods_file"

  # dedup e pulizia
  sed -i.bak 's/\r$//' "$out" && rm -f "$out.bak" 2>/dev/null || true
  sort -u "$out" -o "$out"

  echo "$out"
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

ensure_test_extends_base() {
  local tf="$1"
  local base="$2"   # es: BaseCoverageTest oppure suite.BaseCoverageTest

  [[ -f "$tf" ]] || return 0

  local tmp
  tmp="$(mktemp)"

  awk -v BASE="$base" '
    BEGIN{done=0}

    # Match della dichiarazione classe:
    # public class X {
    # public class X extends Y {
    # public class X implements A,B {
    # public class X extends Y implements A,B {
    /^[[:space:]]*public[[:space:]]+class[[:space:]]+[A-Za-z0-9_]+/ && done==0 {
      line=$0

      # Se già estende BASE, non toccare
      if(line ~ ("[[:space:]]extends[[:space:]]+" BASE "([[:space:]]|\\{|implements)")) {
        print line
        done=1
        next
      }

      # Se ha extends QUALCOSA, sostituisci quella parte con extends BASE
      if(line ~ /[[:space:]]extends[[:space:]]+[A-Za-z0-9_.]+/) {
        sub(/[[:space:]]extends[[:space:]]+[A-Za-z0-9_.]+/, " extends " BASE, line)
        print line
        done=1
        next
      }

      # Se ha implements ma non extends, inserisci extends BASE prima di implements
      if(line ~ /[[:space:]]implements[[:space:]]+/) {
        sub(/[[:space:]]implements[[:space:]]+/, " extends " BASE " implements ", line)
        print line
        done=1
        next
      }

      # Altrimenti: aggiungi extends BASE prima di "{"
      if(line ~ /\{[[:space:]]*$/) {
        sub(/\{[[:space:]]*$/, " extends " BASE " {", line)
        print line
        done=1
        next
      }

      # fallback: aggiungi a fine riga
      print line " extends " BASE
      done=1
      next
    }

    { print }
  ' "$tf" > "$tmp" && mv "$tmp" "$tf"

  echo "[DBG][EXTENDS] ensured extends in $tf:"
  grep -nE "^[[:space:]]*public[[:space:]]+class[[:space:]]+" "$tf" | head -n 1 || true
}

purge_coverage_for_required_tests() {
  local required_file="$1"
  [[ -s "$required_file" ]] || return 0
  [[ -f "$COVERAGE_MATRIX_JSON" ]] || return 0

  local tmp_out
  tmp_out="$(mktemp)"

  jq --rawfile REQ "$required_file" '
    def strip_cr: gsub("\r";"");
    def req_keys:
      ($REQ | split("\n") | map(strip_cr) | map(select(length>0)) );

    def base_of($k): ($k | sub("_case[0-9]+$";""));

    reduce (req_keys[]) as $k
      (.;
        (base_of($k)) as $b
        | del(.[$k])        # del key exact
        | del(.[$b])        # del base
        | with_entries(     # keep everything EXCEPT base_caseN
            select(.key | test("^" + ($b|gsub("\\."; "\\\\.")) + "_case[0-9]+$") | not)
          )
      )
  ' "$COVERAGE_MATRIX_JSON" > "$tmp_out" && mv "$tmp_out" "$COVERAGE_MATRIX_JSON"
}

ensure_import() {
  local file="$1"
  local import_fqn="$2"   # es: org.junit.Test
  local import_line="import ${import_fqn};"

  grep -qE "^[[:space:]]*import[[:space:]]+${import_fqn//./\\.}[[:space:]]*;" "$file" && return 0

  local tmp
  tmp="$(mktemp)"

  awk -v imp="$import_line" '
    BEGIN{inserted=0; lastImport=0; pkgLine=0}

    {
      lines[NR]=$0
      if($0 ~ /^[[:space:]]*package[[:space:]]+/) pkgLine=NR
      if($0 ~ /^[[:space:]]*import[[:space:]]+/)  lastImport=NR
    }

    END{
      for(i=1;i<=NR;i++){
        print lines[i]

        if(inserted==0){
          # caso: esistono import -> dopo l ultimo import
          if(lastImport>0 && i==lastImport){
            print imp
            inserted=1
          }
          # caso: no import ma package -> dopo package
          else if(lastImport==0 && pkgLine>0 && i==pkgLine){
            print imp
            inserted=1
          }
        }
      }

      # caso: no package e no import -> in testa (ma qui siamo in END, quindi non possiamo)
      # lo gestiamo fuori, con inserted==0
    }
  ' "$file" > "$tmp"

  if ! grep -qE "^[[:space:]]*import[[:space:]]+${import_fqn//./\\.}[[:space:]]*;" "$tmp"; then
    # significa che non c erano package/import -> metti in testa
    awk -v imp="$import_line" 'BEGIN{print imp; print ""} {print}' "$file" > "$tmp"
  fi

  mv "$tmp" "$file"
}

ensure_static_import() {
  local file="$1"
  local what="$2"   # es: org.junit.Assert.*

  # 1) se già c'è, non fare nulla (ma prima dedup dopo)
  if grep -qE "^[[:space:]]*import[[:space:]]+static[[:space:]]+${what//./\\.}[[:space:]]*;" "$file"; then
    :
  else
    # inserisci dopo package o in testa
    if grep -qE '^[[:space:]]*package[[:space:]]+' "$file"; then
      awk -v imp="import static ${what};" '
        BEGIN{done=0}
        {print}
        done==0 && $0 ~ /^[[:space:]]*package[[:space:]]+/ { print ""; print imp; done=1 }
      ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    else
      awk -v imp="import static ${what};" 'BEGIN{print imp} {print}' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    fi
  fi

  # 2) rimuovi import static specifici (assertEquals, assertTrue, ecc.) se hai Assert.*
  if [[ "$what" == "org.junit.Assert.*" ]]; then
    grep -vE '^[[:space:]]*import[[:space:]]+static[[:space:]]+org\.junit\.Assert\.[A-Za-z0-9_]+[[:space:]]*;' \
      "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
  fi

  # 3) dedup righe import static identiche
  awk '
    /^[[:space:]]*import[[:space:]]+static[[:space:]]+/{
      if(seen[$0]++) next
    }
    {print}
  ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

merge_generated_tests() {
  local test_file="$1"
    echo "[DBG] pristine used: ${test_file}.pristine"
  local gen_file="${test_file%.java}.generated.java"
  local bak_file="${test_file}.pristine"

  # 0) serve il generated
  if [[ ! -f "$gen_file" ]]; then
    echo "[MERGE] Missing generated file: $gen_file"
    return 1
  fi

  # 1) ripristina target se manca ma c'è backup (NON consumare il backup)
  if [[ ! -f "$test_file" && -f "$bak_file" ]]; then
    cp -f "$bak_file" "$test_file"
    echo "[MERGE] Restored backup as target (kept .pristine): $test_file"
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

  local regen_bases
  regen_bases="$(mktemp)"

  local tmp_fields tmp_before
  tmp_fields="$(mktemp)"
  tmp_before="$(mktemp)"

    # =========================
    # NORMALIZE generated file (Windows CRLF -> LF) -> gen_norm
    # =========================
    local gen_norm
    gen_norm="$(mktemp)"
    perl -pe 's/\r$//mg' "$gen_file" > "$gen_norm"

    # =========================
    # Cleanup header rumorosi LLM ("EXTRA TEXT FROM LLM") sul NORMALIZZATO
    # =========================
    if grep -q "EXTRA TEXT FROM LLM" "$gen_norm"; then
      local tmp_clean
      tmp_clean="$(mktemp)"
      awk '
        BEGIN{skip=0}
        /EXTRA TEXT FROM LLM/{skip=1}
        (skip==1 && ($0 ~ /^import[[:space:]]+org\.junit\.Test/ || $0 ~ /^[[:space:]]*public[[:space:]]+class/)){skip=0}
        { if(skip==0) print }
      ' "$gen_norm" > "$tmp_clean"
      mv "$tmp_clean" "$gen_norm"
    fi

    # =========================
    # JUNIT5 -> JUNIT4 normalize (generale)
    # =========================
    perl -0777 -i -pe '
      s/\bimport\s+org\.junit\.jupiter\.api\.Test\s*;\s*/import org.junit.Test;\n/sg;
      s/\bimport\s+org\.junit\.jupiter\.api\.BeforeEach\s*;\s*/import org.junit.Before;\n/sg;
      s/^\s*@BeforeEach\b/@Before/mg;
      # se ci sono static Assertions di jupiter, lasciali o rimuovili (JUnit4 userà org.junit.Assert.*)
      s/\bimport\s+static\s+org\.junit\.jupiter\.api\.Assertions\.\*;\s*\n//sg;
      s/^\s*\@org\.junit\.jupiter\.api\.Test\b/@Test/mg;
      s/^\s*\@org\.junit\.jupiter\.api\.BeforeEach\b/@Before/mg;
    ' "$gen_norm"

    # Se esiste un metodo setUp() senza @Before, aggiungi @Before sopra (ROBUSTO: perl script esterno senza /e)
    local tmp_pl tmp_out

    tmp_pl="$(mktemp)"
    tmp_out="$(mktemp)"

    printf '%s\n' \
    'use strict;' \
    'use warnings;' \
    '' \
    'my $file = shift @ARGV;' \
    'open my $fh, "<", $file or die "open in: $!";' \
    'my @L = <$fh>;' \
    'close $fh;' \
    '' \
    'for (my $i=0; $i<@L; $i++) {' \
    '  my $line = $L[$i];' \
    '  # match: (indent)(public|protected|private) void setUp() {' \
    '  if ($line =~ /^([ \t]*)(public|protected|private)[ \t]+void[ \t]+setUp[ \t]*\(\)[ \t]*\{/) {' \
    '    my $ind = $1;' \
    '    my $prev = ($i>0) ? $L[$i-1] : "";' \
    '    # if previous line is not @Before (allow trailing spaces)' \
    '    if ($prev !~ /^\s*\@Before\s*$/) {' \
    '      splice(@L, $i, 0, $ind . "\@Before\n");' \
    '      $i++;' \
    '    }' \
    '  }' \
    '}' \
    '' \
    'open my $out, ">", $file or die "open out: $!";' \
    'print $out @L;' \
    'close $out;' \
    'exit 0;' > "$tmp_pl"

    perl "$tmp_pl" "$gen_norm" \
      || { echo "[MERGE][FATAL] promote setUp() -> @Before failed"; rm -f "$tmp_pl" "$tmp_out"; return 1; }

    rm -f "$tmp_pl" 2>/dev/null || true

    # =========================
    # 3) Extract @Test method blocks from gen_norm (brace-balanced)
    # =========================
    awk '
      BEGIN{ seenTest=0; inMeth=0; started=0; brace=0; buf="" }

      /^[[:space:]]*@([A-Za-z0-9_.]*\.)?Test([[:space:]]*|\(|$)/{
        if(seenTest==1){ seenTest=0; inMeth=0; started=0; brace=0; buf="" }
        seenTest=1
        buf=$0 "\n"
        next
      }

      {
        if(seenTest==1){
          buf = buf $0 "\n"

          if(inMeth==0 && $0 ~ /^[[:space:]]*(public|protected|private)?[[:space:]]*(static[[:space:]]+)?void[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\(/){
            inMeth=1
          }

          if(inMeth==1){
            if($0 ~ /\{/) started=1
            if(started==1){
              line = $0
              o = gsub(/\{/, "{", line)
              c = gsub(/\}/, "}", line)
              brace += o
              brace -= c
              if(brace==0){
                print buf
                print "/*__TEST_BLOCK__*/"
                print ""
                seenTest=0; inMeth=0; started=0; brace=0; buf=""
              }
            }
          }
          next
        }
      }
    ' "$gen_norm" > "$tmp_methods"

    # =========================
    # Normalize "Assert.assertX(...)" -> "assertX(...)" in generated tests
    # (così basta "import static org.junit.Assert.*;")
    # =========================
    perl -pi -e 's/\b(?:org\.junit\.)?Assert\.(assert[A-Za-z0-9_]*)\s*\(/$1(/g' "$tmp_methods"

    # =========================
    # Extract class fields (private/protected/public ... ;) from generated
    # =========================
    awk '
      BEGIN{inClass=0; brace=0}
      /^[[:space:]]*(public[[:space:]]+)?class[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\{/ {inClass=1}
      {
        if(inClass){
          line=$0
          brace += gsub(/\{/,"{",line)
          brace -= gsub(/\}/,"}",line)
          # prendi dichiarazioni di campo semplici: accesso + tipo + nome + ;
          if($0 ~ /^[[:space:]]*(public|protected|private)?[[:space:]]*(static[[:space:]]+)?(final[[:space:]]+)?[A-Za-z0-9_.<>\[\]]+[[:space:]]+[A-Za-z0-9_]+[[:space:]]*(=[^;]*)?;/){
            print $0
          }
          if(brace==0 && inClass==1){inClass=0}
        }
      }
    ' "$gen_norm" | sed 's/\r$//' > "$tmp_fields"

    # =========================
    # Extract @Before blocks (brace-balanced) from gen_norm
    # =========================
    awk '
      BEGIN{ seen=0; inMeth=0; started=0; brace=0; buf="" }

      /^[[:space:]]*@Before([[:space:]]*|\(|$)/{
        seen=1
        buf=$0 "\n"
        next
      }

      {
        if(seen==1){
          buf = buf $0 "\n"

          if(inMeth==0 && $0 ~ /^[[:space:]]*(public|protected|private)?[[:space:]]*(static[[:space:]]+)?void[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\(/){
            inMeth=1
          }

          if(inMeth==1){
            if($0 ~ /\{/) started=1
            if(started==1){
              line=$0
              o=gsub(/\{/,"{",line)
              c=gsub(/\}/,"}",line)
              brace += o
              brace -= c
              if(brace==0){
                print buf
                print ""
                seen=0; inMeth=0; started=0; brace=0; buf=""
              }
            }
          }
          next
        }
      }
    ' "$gen_norm" | sed 's/\r$//' > "$tmp_before"

    echo "[MERGE][DEBUG] tmp_methods RIGHT AFTER EXTRACT (first 80 lines):"
    nl -ba "$tmp_methods" | sed -n '1,80p' || true
    echo "[MERGE][DEBUG] tmp_methods method names RIGHT AFTER EXTRACT:"
    perl -ne 'print "$.:\t$1\n" if(/(?:public\s+)?void\s+([A-Za-z0-9_]+)\s*\(/);' "$tmp_methods" || true

    # =========================
    # SANITY: scarta blocchi non validi (graffe sbilanciate / senza signature)
    # =========================
    perl -0777 -i -pe '
      my @blocks = split(/\n\s*\/\*__TEST_BLOCK__\*\/;?\s*\n/, $_);
      my @out;
      for my $b (@blocks){
        next if $b !~ /(?:public|protected|private)?\s*(?:static\s+)?void\s+\w+\s*\(/;
        my $opens = () = ($b =~ /\{/g);
        my $closes = () = ($b =~ /\}/g);
        next if $opens == 0;
        next if $opens != $closes;
        push @out, $b;
      }
      $_ = join("\n/*__TEST_BLOCK__*/\n", @out) . "\n";
    ' "$tmp_methods"

    echo "[MERGE][DEBUG] tmp_methods AFTER SANITY size: $(wc -c < "$tmp_methods") bytes"
    echo "[MERGE][DEBUG] tmp_methods AFTER FILTER size: $(wc -c < "$tmp_methods") bytes"


    # (opzionale) rimuovi blocchi con package evidentemente errati generati dall’LLM
    grep -vE 'it\.unibo\.oop\.|it\.utente\.' "$tmp_methods" > "${tmp_methods}.f" \
      && mv "${tmp_methods}.f" "$tmp_methods"

      # =========================
      # UNDEF GUARD (fail-fast): blocca metodi generati che usano identificatori non dichiarati
      # - evita casi tipo: new Amministratore(name, surname, department) senza "String name=..."
      # =========================
      tmp_undef_err="$(mktemp)"
      awk '
        BEGIN{
          RS="\\/\\*__TEST_BLOCK__\\*\\/";
          bad=0;
        }
        {
          b=$0;

          # ignora blocchi vuoti/sporchi
          gsub(/\r/,"",b);
          if (b ~ /^[[:space:]]*$/) next;

          # analizza solo se contiene un metodo
          if (b !~ /[[:space:]]void[[:space:]]+[A-Za-z0-9_]+[[:space:]]*[(]/) next;

          decl_name   = (b ~ /\\b(String|int|long|double|float|boolean|char|byte|short)[[:space:]]+name\\b/);
          decl_surname= (b ~ /\\b(String|int|long|double|float|boolean|char|byte|short)[[:space:]]+surname\\b/);
          decl_dept   = (b ~ /\\b(String|int|long|double|float|boolean|char|byte|short)[[:space:]]+department\\b/);

          use_name    = (b ~ /\\bname\\b/);
          use_surname = (b ~ /\\bsurname\\b/);
          use_dept    = (b ~ /\\bdepartment\\b/);

          if (use_name && !decl_name){
            print "[UNDEF_GUARD][FATAL] identifier \"name\" used but not declared in generated test block." > "/dev/stderr";
            bad=1;
          }
          if (use_surname && !decl_surname){
            print "[UNDEF_GUARD][FATAL] identifier \"surname\" used but not declared in generated test block." > "/dev/stderr";
            bad=1;
          }
          if (use_dept && !decl_dept){
            print "[UNDEF_GUARD][FATAL] identifier \"department\" used but not declared in generated test block." > "/dev/stderr";
            bad=1;
          }

          # stampa un minimo di contesto per debug (solo se bad)
          if (bad==1){
            if (match(b, /void[[:space:]]+([A-Za-z0-9_]+)/, m)){
              print "[UNDEF_GUARD][CTX] method=" m[1] > "/dev/stderr";
            }
          }
        }
        END{
          if (bad==1) exit 2;
          exit 0;
        }
      ' "$tmp_methods" 2> "$tmp_undef_err"
      rc=$?
      if [[ $rc -ne 0 ]]; then
        echo "[MERGE][FATAL] UNDEF_GUARD failed for generated methods: $tmp_methods"
        cat "$tmp_undef_err" || true
        rm -f "$tmp_undef_err" 2>/dev/null || true
        return 1
      fi
      rm -f "$tmp_undef_err" 2>/dev/null || true

    # =========================
    # DEBUG: mostra cosa c’è dentro il generated normalizzato e cosa ho estratto
    # =========================
    echo "[MERGE][DEBUG] extracted methods signatures:"
    grep -nE '^[[:space:]]*(public|protected|private)?[[:space:]]*(static[[:space:]]+)?void[[:space:]]+' "$gen_norm" | head -n 50

    if [[ ! -s "$tmp_methods" ]]; then
      echo "[MERGE][DEBUG] extractor produced 0 @Test method blocks."
      echo "[MERGE][DEBUG] first 120 lines of normalized generated (line-numbered):"
      nl -ba "$gen_norm" | sed -n '1,120p' || true
      echo "[MERGE][DEBUG] @Test lines:"
      grep -nE '^[[:space:]]*@([A-Za-z0-9_.]*\.)?Test\b' "$gen_norm" | head -n 50 || true
    fi

  # =========================
  # FILTER (robusto): lavora su blocchi separati da una sentinel
  # =========================
  perl -0777 -i -pe '
    # forza separatore stabile tra blocchi: inserisci una sentinel tra "} \n \n @Test"
    s/\}\s*\n\s*\n\s*(@(?:[A-Za-z0-9_.]*\.)?Test\b)/}\n\n<<<SPLIT>>>\n\n$1/gm;

    my @blocks = split(/\n\s*<<<SPLIT>>>\s*\n/, $_);
    my @out;
    for my $b (@blocks){
      next if $b =~ /assertEquals\s*\([^;]*\bsetName\s*\(/; # assume return value
      push @out, $b;
    }
    $_ = join("\n/*__TEST_BLOCK__*/\n", @out) . "\n";
  ' "$tmp_methods"

  echo "[MERGE][DEBUG] tmp_methods AFTER SANITY size: $(wc -c < "$tmp_methods") bytes"
  echo "[MERGE][DEBUG] tmp_methods AFTER FILTER size: $(wc -c < "$tmp_methods") bytes"

    # ===== FIX A: dedup dei metodi di test nel generated per NOME =====
    perl -0777 -i -pe '
      my %seen;
      my @blocks = split(/\n\s*\/\*__TEST_BLOCK__\*\/;?\s*\n/, $_);
      my @out;
      for my $b (@blocks) {
        if ($b =~ /(?:public|protected|private)?\s*(?:static\s+)?void\s+(\w+)\s*\(/) {
          my $n = $1;
          next if $seen{$n}++;
        }
        push @out, $b;
      }
      $_ = join("\n/*__TEST_BLOCK__*/\n", @out) . "\n";
    ' "$tmp_methods"


  # Rimuovi metodi che usano package palesemente errati generati dall'LLM
  grep -vE 'it\.unibo\.oop\.|it\.utente\.' "$tmp_methods" > "${tmp_methods}.f" \
    && mv "${tmp_methods}.f" "$tmp_methods"

# =========================
# NORMALIZE: evita @Test duplicati nello stesso blocco
# - se un blocco contiene più @Test, tienine solo il primo
# =========================
echo "[DBG][PERL] SNROMOZS"
perl -0777 -i -pe '
  my @blocks = split(/\n\s*\/\*__TEST_BLOCK__\*\/;?\s*\n/, $_);

  for my $b (@blocks) {
    my $seen = 0;
    # rimuove eventuali @Test extra (lascia solo il primo)
    $b =~ s/^[ \t]*@(?:[A-Za-z0-9_.]*\.)?Test\b.*\n/
      $seen++ ? "" : $&/egm;
  }

  $_ = join("\n/*__TEST_BLOCK__*/\n", @blocks) . "\n";
' "$tmp_methods"

# =========================
# FILTER: drop JUnit4 tests that use @Test(expected=...)
# Reason: Chat2UnitTest spesso genera expected=... ma poi lancia AssertionError o niente -> flaky/failing
# =========================
perl -0777 -i -pe '
  my @blocks = split(/\n\s*\/\*__TEST_BLOCK__\*\/;?\s*\n/s, $_);
  @blocks = grep { $_ !~ /^\s*@Test\s*\(\s*expected\s*=/m } @blocks;
  $_ = join("\n/*__TEST_BLOCK__*/\n", @blocks) . "\n";
' "$tmp_methods"

echo "[MERGE][DEBUG] tmp_methods AFTER DROP expected= (method names):"
perl -ne 'print "$.:\t$1\n" if(/(?:public|protected|private)?\s*(?:static\s+)?void\s+([A-Za-z0-9_]+)\s*\(/);' "$tmp_methods" | head -n 80 || true

# =========================
# MERGE fields + @Before into target (GENERICO)
# IMPORTANT: va fatto PRIMA di inserire i @Test
# =========================

# 1) MERGE FIELDS (dedup): inserisce SOLO i campi mancanti nel target
#    - dedup per NOME campo
#    - inserisce subito dopo "public class X {"
if [[ -s "$tmp_fields" ]]; then
  local tmp_out_fields
  tmp_out_fields="$(mktemp)"

  awk -v fields_file="$tmp_fields" '
    BEGIN{
      # Carica campi dal generated (dedup per nome campo)
      n=0
      while((getline f < fields_file)>0){
        gsub(/\r/,"",f)
        sub(/^[ \t]+/,"",f)
        sub(/[ \t]+$/,"",f)
        if(f=="") continue

        # estrae nome campo: ultima "parola" prima di ";"
        name=f
        sub(/;.*/,"",name)
        sub(/.*[ \t]/,"",name)

        # dedup dentro tmp_fields: tieni il primo che appare
        if(!(name in fieldLine)){
          fieldLine[name]=f
          order[++n]=name
        }
      }
      close(fields_file)
    }

    {
      lines[NR]=$0

      # Riconosce campi già presenti nel target (euristica semplice: access modifier + ... + name + ;)
      if($0 ~ /^[[:space:]]*(public|protected|private)?[[:space:]]*(static[[:space:]]+)?(final[[:space:]]+)?[A-Za-z0-9_.<>\[\]]+[[:space:]]+[A-Za-z0-9_]+[[:space:]]*(=[^;]*)?;/){
        t=$0
        sub(/^[ \t]+/,"",t)
        sub(/;.*/,"",t)
        sub(/.*[ \t]/,"",t)
        existing[t]=1
      }
    }

    END{
      inserted=0
      for(i=1;i<=NR;i++){
        print lines[i]

        # Inserisci subito dopo "public class X {"
        if(inserted==0 && lines[i] ~ /^[[:space:]]*public[[:space:]]+class[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\{/){
          addCount=0
          for(j=1;j<=n;j++){
            nm=order[j]
            if(!(nm in existing)){
              print "    " fieldLine[nm]
              addCount++
            }
          }
          if(addCount>0) print ""
          inserted=1
        }
      }
    }
  ' "$test_file" > "$tmp_out_fields"

  mv "$tmp_out_fields" "$test_file"
fi

# 2) Inserisci @Before se il target NON ce l'ha già, ma il generated sì
if [[ -s "$tmp_before" ]]; then
  if ! grep -qE '^[[:space:]]*@Before\b' "$test_file"; then
    local tmp_out_before
    tmp_out_before="$(mktemp)"
    awk -v bef="$tmp_before" '
      {lines[NR]=$0}
      END{
        ins=0
        for(i=1;i<=NR;i++){
          print lines[i]
          if(ins==0 && lines[i] ~ /^[[:space:]]*public[[:space:]]+class[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\{/){
            print ""
            while((getline l < bef)>0) print l
            close(bef)
            print ""
            ins=1
          }
        }
      }
    ' "$test_file" > "$tmp_out_before"
    mv "$tmp_out_before" "$test_file"
  fi
fi

# bonifica target da junit-jupiter (se presenti)
sed -i.sedbak -E \
  's/^[[:space:]]*import[[:space:]]+org\.junit\.jupiter\.api\.Test[[:space:]]*;[[:space:]]*$/import org.junit.Test;/' \
  "$test_file" && rm -f "$test_file.sedbak"

sed -i.sedbak -E \
  's/^[[:space:]]*import[[:space:]]+org\.junit\.jupiter\.api\.BeforeEach[[:space:]]*;[[:space:]]*$/import org.junit.Before;/' \
  "$test_file" && rm -f "$test_file.sedbak"

  # bonifica target: @BeforeEach -> @Before (non basta cambiare solo l'import)
  perl -pi -e 's/^\s*@BeforeEach\b/@Before/gm' "$test_file"

# se ho @Before, assicura import org.junit.Before;
if grep -qE '^[[:space:]]*@Before\b' "$test_file"; then
  ensure_import "$test_file" "org.junit.Before"
fi

# se ho @Test, assicura import org.junit.Test;
if grep -qE '^[[:space:]]*@([A-Za-z0-9_.]*\.)?Test\b' "$test_file"; then
  ensure_import "$test_file" "org.junit.Test"
fi

    # =========================
    # REQUIRED base names (da coverage) per QUESTA test class
    # =========================
    if [[ -z "${REQUIRED_TESTS_FILE:-}" || ! -s "${REQUIRED_TESTS_FILE:-}" ]]; then
      echo "[MERGE] REQUIRED_TESTS_FILE missing/empty -> cannot enforce required names"
      rm -f "$tmp_methods" "$tmp_names"
      return 1
    fi

    # calcola FQN della test class corrente (pkg + cls)
    local pkg cls cls_fqn
    pkg="$(grep -m1 -E '^[[:space:]]*package[[:space:]]+' "$test_file" | sed -E 's/^[[:space:]]*package[[:space:]]+([^;]+);.*/\1/')"
    cls="$(basename "$test_file" .java)"
    cls_fqn="${pkg}.${cls}"
    # se pkg è vuoto, cls_fqn deve essere solo la classe (niente punto iniziale)
    if [[ -z "$pkg" ]]; then
      cls_fqn="$cls"
    fi

    # req_bases: lista dei nomi base richiesti (es: testSetName, testGetName, ...)
    local req_bases
    req_bases="$(mktemp)"
    awk -v pref="${cls_fqn}." '
      index($0,pref)==1 {
        m = substr($0, length(pref)+1)
        sub(/_case[0-9]+$/, "", m)   # <-- IMPORTANT: collassa case -> base
        print m
      }
    ' "$REQUIRED_TESTS_FILE" | sed 's/\r$//' | sort -u > "$req_bases"

    echo "[DBG] req_bases (base-collapsed):"
    nl -ba "$req_bases"

    # >>> creazione req_bases_ext <<<
    req_bases_ext="$(mktemp)"

    awk '
      {
        b=$0
        print b
        if (b ~ /^test[A-Z]/) {
          p=b
          sub(/^test/,"",p)
          p=tolower(substr(p,1,1)) substr(p,2)
          print p
        }
      }
    ' "$req_bases" | sed 's/\r$//' | sort -u > "$req_bases_ext"

# >>> creazione req_prods <<<
    req_prods="$(mktemp)"
    awk '
      {
        b=$0
        if (b ~ /^test[A-Z]/) {
          p=b
          sub(/^test/,"",p)
          p=tolower(substr(p,1,1)) substr(p,2)
          print p
        } else {
          # se già non è testX, consideralo come prod diretto (es. getProfession)
          print b
        }
      }
    ' "$req_bases" | sed 's/\r$//' | sort -u > "$req_prods"

echo "================= [DEBUG REQUIRED MAP] ================="
echo "[DEBUG] cls_fqn = '$cls_fqn'"
echo "[DEBUG] REQUIRED_TESTS_FILE = '$REQUIRED_TESTS_FILE'"

echo "[DEBUG] ---- raw REQUIRED_TESTS_FILE (filtered for this class) ----"
grep -n "^${cls_fqn}\." "$REQUIRED_TESTS_FILE" || echo "(none)"

echo "[DEBUG] ---- req_bases ----"
nl -ba "$req_bases" || echo "(empty)"

echo "[DEBUG] ---- req_bases_ext ----"
nl -ba "$req_bases_ext" || echo "(empty)"

if [[ -n "${req_prods:-}" && -f "${req_prods:-}" ]]; then
  echo "[DEBUG] ---- req_prods ----"
  nl -ba "$req_prods" || echo "(empty)"
else
  echo "[DEBUG] ---- req_prods ----"
  echo "(req_prods not set or file missing)"
fi

echo "========================================================"


        echo "[MERGE][DEBUG] cls_fqn='$cls_fqn'"
        echo "[MERGE][DEBUG] REQUIRED_TESTS_FILE='$REQUIRED_TESTS_FILE' (first 10 lines for this class):"
        grep -n "^${cls_fqn}\." "$REQUIRED_TESTS_FILE" | head -n 10 || true
        echo "[MERGE][DEBUG] req_bases content:"
        cat "$req_bases" || true

    # =========================
    # RENAME: per ogni required base B (es testSetName),
    # rinomina i test generati in B_case1, B_case2, ...
    # scegliendo prima quelli che chiamano .<prod>(
    # =========================

      echo "[MERGE][DEBUG] tmp_methods BEFORE RENAME (first 80 lines):"
      nl -ba "$tmp_methods" | sed -n '1,80p' || true

      echo "[MERGE][DEBUG] methods BEFORE rename:"
      perl -ne 'print "$.:\t$1\n" if(/(?:public|protected|private)?\s*(?:static\s+)?void\s+([A-Za-z0-9_]+)\s*\(/);' "$tmp_methods" | head -n 40 || true

echo "================ DEBUG RENAME START ================"
echo "[DBG] tmp_methods path: $tmp_methods"
echo "[DBG] tmp_methods size BEFORE rename: $(wc -c < "$tmp_methods") bytes"
echo "[DBG] Methods BEFORE rename:"
perl -ne 'print "$.:\t$1\n" if(/(?:public|protected|private)?\s*void\s+([A-Za-z0-9_]+)\s*\(/);' "$tmp_methods" || true
echo "===================================================="

    # --- FIX: SAFE RENAME to required bases ONLY when we can MATCH by prod call ---
    # req_bases: testGetName -> prod getName ; testSetSurname -> prod setSurname ; ...
    # --- GENERAL RENAME: assign each generated block to ONE required base by scoring prod-call occurrences ---
    tmp_methods_before_rename="$(mktemp)"
    cp -f "$tmp_methods" "$tmp_methods_before_rename"

    echo "[DBG][PERL] FFGE"
    REQBASES="$req_bases" perl -0777 -i -pe '
      use strict;
      use warnings;

      my $orig = $_;

      # load required bases (trim + dedup)
      my $reqfile = $ENV{REQBASES};
      open my $fh, "<", $reqfile or die "cannot open REQBASES: $!";
      my @req;
      while (my $line = <$fh>) {
        $line =~ s/\r?\n$//;
        $line =~ s/^\s+|\s+$//g;
        next if $line eq "";
        push @req, $line;
      }
      close $fh;

      my %seen;
      @req = grep { !$seen{$_}++ } @req;

      # map required base -> prod method name (testGetProfession -> getProfession)
      my %prod_of;
      for my $b (@req) {
        my $p = $b;
        $p =~ s/^test//;
        $p = lcfirst($p);
        $prod_of{$b} = $p;
      }

      # split blocks
      my @blocks = split(/\n\s*\/\*__TEST_BLOCK__\*\/;?\s*\n/s, $_);

      my %k;
      my @out;

      for my $blk (@blocks) {
        next if $blk !~ /void\s+([A-Za-z0-9_]+)\s*\(/;
        my $old = $1;

        my $best_base  = "";
        my $best_score = 0;

        for my $b (@req) {
          my $p = $prod_of{$b};
          my $score = 0;

          # SIGNAL A: il nome del test contiene il prod method (case-insensitive)
          $score += 100 if index(lc($old), lc($p)) != -1;

          # SIGNAL B: nel body c e una chiamata ".prod("
          my $hits = (() = ($blk =~ /\.\s*\Q$p\E\s*\(/g));
          $score += 10 * $hits;

          # SIGNAL C: chiamata "prod(" non qualificata (piu debole)
          my $hits2 = (() = ($blk =~ /(?:^|[^.A-Za-z0-9_])\Q$p\E\s*\(/g));
          $score += 3 * $hits2;

          if ($score > $best_score) {
            $best_score = $score;
            $best_base  = $b;
          }
        }

        # rename if any evidence found
        if ($best_score > 0 && $best_base ne "") {
          my $n = ++$k{$best_base};
          my $new = $best_base . "_case" . $n;
          $blk =~ s/void\s+\Q$old\E\s*\(/void $new(/;
        }

        push @out, $blk;
      }

      $_ = @out ? join("\n/*__TEST_BLOCK__*/\n", @out) . "\n" : $orig;
    ' "$tmp_methods"

    # guard
    if [[ "$(wc -c < "$tmp_methods")" -lt 20 ]]; then
      echo "[MERGE][FATAL] RENAME produced empty tmp_methods."
      echo "[MERGE][FATAL] BEFORE rename:"
      nl -ba "$tmp_methods_before_rename" | head -n 120 || true
      return 1
    fi

    rm -f "$tmp_methods_before_rename"

    echo "================ DEBUG RENAME END =================="
    echo "[DBG] tmp_methods size AFTER rename: $(wc -c < "$tmp_methods") bytes"
    echo "[DBG] Methods AFTER rename:"
    perl -ne 'print "$.:\t$1\n" if(/(?:public|protected|private)?\s*void\s+([A-Za-z0-9_]+)\s*\(/);' "$tmp_methods" || true
    echo "===================================================="

    # =========================
    # tieni solo blocchi con base in req_bases
    # =========================
    # STEP 3 (cleanup spazzatura): tieni solo blocchi con base in req_bases
    # FAIL-SAFE: se filtra tutto, lascia invariato
    # =========================
if false; then
  echo "[DBG][PERL] SPAZZA"
    REQBASES="$req_bases" perl -0777 -i -pe '
      my $orig = $_;

      my $reqfile = $ENV{REQBASES};
      open my $fh, "<", $reqfile or die $!;
      my %ok;
      while(my $l=<$fh>){
        $l =~ s/\r?\n$//;
        next if $l eq "";
        $ok{$l}=1;
      }
      close $fh;

      # SPLIT COERENTE (come negli altri punti)
      my @blocks = split(/\n\s*\/\*__TEST_BLOCK__\*\/;?\s*\n/s, $orig);

      if(!@blocks){
        $_ = $orig;
      } else {
        my @out;
        for my $b (@blocks){
          next if $b !~ /void\s+([A-Za-z0-9_]+)\s*\(/;
          my $m=$1;
          (my $base=$m) =~ s/_case\d+$//;
          next unless exists $ok{$base};
          push @out, $b;
        }

        if(keys %ok == 0){
          $_ = $orig;                # niente required -> non filtrare
        } else {
          $_ = join("\n/*__TEST_BLOCK__*/\n", @out) . "\n";  # required presenti -> filtra davvero
        }
      }
    ' "$tmp_methods"
fi
        # --- CANONICAL RENUMBER (stable): per ogni base, garantisci case1..caseN in ordine ---
        echo "[DBG][PERL] CANE"
        perl -i -pe '
          BEGIN { our %k; }
          if (/^\s*(?:public|protected|private)?\s*void\s+([A-Za-z0-9_]+)\s*\(/) {
            my $old = $1;
            (my $b = $old) =~ s/_case\d+$//;
            my $n = ++$k{$b};
            my $new = $b . "_case" . $n;
            s/\b\Q$old\E\b/$new/;
          }
        ' "$tmp_methods"
        # --- END CANONICAL RENUMBER ---

    # =========================
    # HARD ASSIGN BY PROD CALL (deterministico)
    # - ogni blocco viene assegnato a UNA base richiesta se contiene ".<prod>("
    # - poi rinomina in <base>_case1..N
    # =========================
    REQBASES="$req_bases" perl -0777 -i -pe '
      use strict; use warnings;

      my $reqfile = $ENV{REQBASES};
      open my $fh, "<", $reqfile or die "cannot open REQBASES: $!";
      my @bases;
      while(my $l=<$fh>){
        $l =~ s/\r?\n$//; $l =~ s/^\s+|\s+$//g;
        next if $l eq "";
        push @bases, $l;
      }
      close $fh;

      # base -> prod (testGetSurname -> getSurname)
      my %prod;
      for my $b (@bases){
        (my $p = $b) =~ s/^test//;
        $p = lcfirst($p);
        $prod{$b} = $p;
      }

      sub is_setter_base {
        my ($b) = @_;
        return ($b =~ /^testSet[A-Z]/) ? 1 : 0;
      }

      my @blocks = split(/\n\s*\/\*__TEST_BLOCK__\*\/;?\s*\n/s, $_);
      my %count;
      my @out;

      for my $blk (@blocks){
        next if $blk !~ /void\s+([A-Za-z0-9_]+)\s*\(/;

        my $best_base  = "";
        my $best_score = -1;
        my $best_is_setter = 0;

        for my $b (@bases){
          my $p = $prod{$b};

          # count occurrences of ".prod("
          my $hits = (() = ($blk =~ /\.\s*\Q$p\E\s*\(/g));

          # base score: hits * 100
          my $score = $hits * 100;

          # small bonus if method name itself contains prod (helps when calls are absent)
          if($blk =~ /void\s+([A-Za-z0-9_]+)\s*\(/){
            my $old = $1;
            $score += 10 if index(lc($old), lc($p)) != -1;
          }

          my $is_set = is_setter_base($b);

          # choose best by score; tie-break: prefer setter if both have evidence
          if($score > $best_score
             || ($score == $best_score && $score > 0 && $is_set && !$best_is_setter)){
            $best_score = $score;
            $best_base  = $b;
            $best_is_setter = $is_set;
          }
        }

        # rename only if we found evidence
        if($best_score > 0 && $best_base ne ""){
          my $n = ++$count{$best_base};
          my $new = $best_base . "_case" . $n;

          # rename FULL method name (no suffix preservation)
          $blk =~ s/(void\s+)[A-Za-z0-9_]+(\s*\()/$1$new$2/;
        }

        push @out, $blk;
      }

      $_ = join("\n/*__TEST_BLOCK__*/\n", @out) . "\n";
    ' "$tmp_methods"

    echo "[MERGE][DEBUG] methods AFTER HARD ASSIGN BY PROD CALL:"
    perl -ne 'print "$.:\t$1\n" if(/void\s+([A-Za-z0-9_]+)\s*\(/);' "$tmp_methods" | head -n 120 || true

            # --- CANONICAL RENUMBER (stable): per ogni base, garantisci case1..caseN in ordine ---
            perl -i -pe '
              BEGIN { our %k; }
              if (/^\s*(?:public|protected|private)?\s*void\s+([A-Za-z0-9_]+)\s*\(/) {
                my $old = $1;
                (my $b = $old) =~ s/_case\d+$//;
                my $n = ++$k{$b};
                my $new = $b . "_case" . $n;
                s/\b\Q$old\E\b/$new/;
              }
            ' "$tmp_methods"
            # --- END CANONICAL RENUMBER ---

    # ricostruisci tmp_names coerente con i nuovi nomi
    echo "[DBG][PERL] STEP RICOST"
    perl -0777 -ne '
      while(/(?:public|protected|private)?\s*(?:static\s+)?void\s+([A-Za-z0-9_]+)\s*\(/g){
        print "$1\n";
      }
    ' "$tmp_methods" | sed 's/\r$//' | sort -u > "$tmp_names"
    # --- END FIX ---

    sed -E 's/_case[0-9]+$//' "$tmp_names" | sed 's/\r$//' | sort -u > "$regen_bases"

    echo "[MERGE][DEBUG] methods AFTER CANONICAL RENUMBER:"
    perl -ne 'print "$.:\t$1\n" if(/(?:public|protected|private)?\s*void\s+([A-Za-z0-9_]+)\s*\(/);' "$tmp_methods" | head -n 80 || true

     echo "[MERGE][DEBUG] methods AFTER rename:"
     perl -ne 'print "$.:\t$1\n" if(/(?:public|protected|private)?\s*void\s+([A-Za-z0-9_]+)\s*\(/);' "$tmp_methods" | head -n 60 || true

    echo "[MERGE][DEBUG] tmp_names after rebuild:"
    nl -ba "$tmp_names" | head -n 50 || true

  if [[ ! -s "$tmp_methods" || ! -s "$tmp_names" ]]; then
    echo "[MERGE] No @Test methods found in generated: $gen_file"
    echo "[MERGE] Debug: first 120 lines of generated:"
    sed -n '1,120p' "$gen_file" || true
    echo "[MERGE] Debug: lines with '@' or 'void':"
    grep -nE '(@|void[[:space:]]+[A-Za-z0-9_]+\s*\()' "$gen_file" | head -n 120 || true
    rm -f "$tmp_methods" "$tmp_names"
    return 1
  fi

# Normalizza CRLF -> LF sul target per rendere affidabili awk/grep/perl
echo "[DBG][PERL] STEP CRLF"
perl -pi -e 's/\r$//mg' "$test_file"

# ripulisci i test rigenerati da annotazioni JUnit5
echo "[DBG][PERL] JUNIT5"
perl -i -ne '
  next if /^\s*\@(?:DisplayName|BeforeEach|AfterEach|Nested|ParameterizedTest|MethodSource|ValueSource|CsvSource|CsvFileSource|RepeatedTest|Tag|Tags|TestFactory|TestInstance|TestMethodOrder|Order)\b/;
  print;
' "$tmp_methods"

# remove block separators before insertion
  sed -i.bak '/\/\*__TEST_BLOCK__\*\//d' "$tmp_methods" || true
  rm -f "${tmp_methods}.bak" 2>/dev/null || true

# =========================
# STRONG DROP by BASE (anchored su @Test, robust)
# - rimuove interi blocchi @Test + metodo se il nome matcha:
#     base
#     base_*
#   dove base ∈ req_bases_ext
# - NON lascia mai @Test orfani
# =========================
tmp_drop_required="$(mktemp)"
awk -v bases_file="$req_bases_ext" -v prods_file="$req_prods" '
  BEGIN{
    while((getline b < bases_file)>0){
      gsub(/\r/,"",b); sub(/^[[:space:]]+/,"",b); sub(/[[:space:]]+$/,"",b);
      if(b!="") bases[b]=1;
    }
    close(bases_file);

    while((getline p < prods_file)>0){
      gsub(/\r/,"",p); sub(/^[[:space:]]+/,"",p); sub(/[[:space:]]+$/,"",p);
      if(p!="") prods[p]=1;
    }
    close(prods_file);

    inblk=0; buf=""; depth=0; started=0; name="";
  }

  function brace_delta(s,   t,o,c){
    t=s; o=gsub(/\{/,"{",t);
    t=s; c=gsub(/\}/,"}",t);
    return o-c;
  }

  function is_test(line){
    return (line ~ /^[[:space:]]*@([A-Za-z0-9_.]*\.)?Test([[:space:]]|\(|$)/);
  }

  function is_sig(line){
    return (line ~ /^[[:space:]]*(public|protected|private)?[[:space:]]*(static[[:space:]]+)?void[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\(/);
  }

  function extract_name(line,   t){
    t=line;
    sub(/.*void[[:space:]]+/,"",t);
    sub(/\(.*/,"",t);
    gsub(/[[:space:]]+/,"",t);
    return t;
  }

  function drop_by_base(n,   b){
    for(b in bases){
      if(n == b) return 1;
      if(index(n, b "_") == 1) return 1;   # base_*
    }
    return 0;
  }

  function drop_by_prod_name(n,   p){
    for(p in prods){
      # se il nome contiene getProfession / GetProfession
      if(index(tolower(n), tolower(p)) > 0) return 1;
    }
    return 0;
  }

  function drop_by_prod_call(block,   p, re){
    for(p in prods){
      re = "\\.\\s*" p "\\s*\\(";
      if(block ~ re) return 1;   # ".getProfession("
    }
    return 0;
  }

  function should_drop(n, block){
    if(n=="") return 0;
    if(drop_by_base(n)) return 1;
    if(drop_by_prod_name(n)) return 1;
    if(drop_by_prod_call(block)) return 1;
    return 0;
  }

  {
    line=$0;

    if(inblk==0 && is_test(line)){
      inblk=1; buf=line "\n"; depth=0; started=0; name="";
      next;
    }

    if(inblk==1){
    # se arriva un nuovo @Test e il blocco precedente non si è chiuso,
    # flushiamo il precedente (meglio non droppare a metà) e ripartiamo
    if(is_test(line)){
      if(!should_drop(name, buf)){
        printf "%s", buf;
      }
      buf = line "\n";
      depth=0; started=0; name="";
      next;
    }
      buf = buf line "\n";

      if(name=="" && is_sig(line)){
        name = extract_name(line);
      }

      d = brace_delta(line);
      depth += d;
      if(d > 0) started=1;

      # chiudi blocco quando:
      #  - abbiamo visto la signature (name != "")
      #  - e depth è tornata a 0 DOPO aver visto almeno una "{"
      if(name != "" && started && depth==0){
        if(!should_drop(name, buf)){
          printf "%s", buf;
        }
        inblk=0; buf=""; depth=0; started=0; name="";
      }
      next;
    }

    print;
  }

  END{
    if(inblk==1) printf "%s", buf;
  }
' "$test_file" > "$tmp_drop_required" && mv "$tmp_drop_required" "$test_file"

# =========================
# KILLER DROP (signature-based, indipendente da @Test)
# - elimina metodi con nome che matcha req_bases_ext (base e base_caseN)
# - elimina anche metodi il cui nome contiene un prod di req_prods (LLM naming)
# =========================
tmp_killer_drop="$(mktemp)"
awk -v bases_file="$req_bases_ext" -v prods_file="$req_prods" '
  BEGIN{
    while((getline b < bases_file)>0){
      gsub(/\r/,"",b); sub(/^[[:space:]]+/,"",b); sub(/[[:space:]]+$/,"",b);
      if(b!="") bases[b]=1;
    }
    close(bases_file);

    while((getline p < prods_file)>0){
      gsub(/\r/,"",p); sub(/^[[:space:]]+/,"",p); sub(/[[:space:]]+$/,"",p);
      if(p!="") prods[p]=1;
    }
    close(prods_file);

    skip=0; depth=0; started=0;
  }

  function brace_delta(s,   t,o,c){
    t=s; o=gsub(/\{/,"{",t);
    t=s; c=gsub(/\}/,"}",t);
    return o-c;
  }

  function sig_name(line,   t){
    if(line !~ /^[[:space:]]*(public|protected|private)?[[:space:]]*(static[[:space:]]+)?void[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\(/)
      return "";

    t = line
    sub(/.*void[[:space:]]+/,"",t)
    sub(/\(.*/,"",t)
    gsub(/[[:space:]]+/,"",t)
    return t
  }

  function should_drop_name(n,   b,p){
    if(n=="") return 0;

    # match base esatta o prefix base_ (include _caseN, _with..., ecc.)
    for(b in bases){
      if(n == b) return 1;
      if(index(n, b "_") == 1) return 1;
    }

    # se il nome contiene uno dei prod (case-insensitive)
    for(p in prods){
      if(index(tolower(n), tolower(p)) > 0) return 1;
    }
    return 0;
  }

  {
    line=$0;

    if(skip==1){
      d = brace_delta(line);
      if(d != 0){ started=1; depth += d; }
      if(started && depth==0){
        skip=0; depth=0; started=0;
      }
      next;
    }

    n = sig_name(line);
    if(n != "" && should_drop_name(n)){
      # entra in skip e consuma fino a fine metodo (brace-balance)
      skip=1; depth=0; started=0;
      d0 = brace_delta(line);
      if(d0 != 0){ started=1; depth += d0; }
      if(started && depth==0){
        skip=0; depth=0; started=0;
      }
      next;
    }

    print line;
  }
' "$test_file" > "$tmp_killer_drop" && mv "$tmp_killer_drop" "$test_file"

echo "[DBG] After KILLER DROP (signature-based):"
grep -nE "void[[:space:]]+testSetName_case1" "$test_file" || true

# =========================
# ORPHAN @Test BLOCK CLEANUP (buffered, corretto)
# =========================
tmp_orphan_block="$(mktemp)"
awk '
  function is_test(line){ return (line ~ /^[[:space:]]*@([A-Za-z0-9_.]*\.)?Test([[:space:]]|\(|$)/); }
  function is_sig(line){
    return (line ~ /^[[:space:]]*(public|protected|private)?[[:space:]]*(static[[:space:]]+)?void[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\(/);
  }

  { lines[NR]=$0 }
  END{
    i=1
    while(i<=NR){
      if(is_test(lines[i])){
        j=i+1
        while(j<=NR && lines[j] ~ /^[[:space:]]*$/) j++
        if(j<=NR && is_sig(lines[j])){
          # ok: stampa da i fino a j-1 (inclusi i blank) e poi continua normale (signature verrà stampata dal loop)
          print lines[i]
          k=i+1
          while(k<j){ print lines[k]; k++ }
          i=i+1
          continue
        } else {
          # orphan: skip from i until next @Test or signature
          i=i+1
          while(i<=NR && !is_test(lines[i]) && !is_sig(lines[i])) i++
          continue
        }
      }
      print lines[i]
      i++
    }
  }
' "$test_file" > "$tmp_orphan_block" && mv "$tmp_orphan_block" "$test_file"

echo "[DBG] Orphan @Test lines (if any):"
awk '
  {lines[NR]=$0}
  END{
    for(i=1;i<=NR;i++){
      if(lines[i] ~ /^[[:space:]]*@([A-Za-z0-9_.]*\.)?Test([[:space:]]|\(|$)[[:space:]]*$/){
        j=i+1
        while(j<=NR && lines[j] ~ /^[[:space:]]*$/) j++
        if(j>NR || lines[j] !~ /^[[:space:]]*(public|protected|private)?[[:space:]]*(static[[:space:]]+)?void[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\(/){
          print i ":" lines[i]
        }
      }
    }
  }
' "$test_file" | head -n 50 || true

# =========================
# DEDUP @Test nel TARGET (collassa duplicati consecutivi)
# - risolve casi tipo:
#     @Test
#     @Test
#     public void ...
# =========================
echo "[DBG][PERL] DEDUP TARGET"
perl -0777 -i -pe '1 while s/(\n[ \t]*@(?:[A-Za-z0-9_.]*\.)?Test\b[^\n]*\n)(\s*\n[ \t]*@(?:[A-Za-z0-9_.]*\.)?Test\b[^\n]*\n)/$1/gm;' "$test_file"

# INSERT ALWAYS
local tmp_out_ins
tmp_out_ins="$(mktemp)"

if ! awk -v addfile="$tmp_methods" '
  function count_braces(s,   t,o,c){
    t=s; o=gsub(/\{/,"{",t); t=s; c=gsub(/\}/,"}",t); return o-c;
  }
  BEGIN{depth=0; class_started=0; insert_line=-1}
  {lines[NR]=$0}
  END{
    for(i=1;i<=NR;i++){
      d=count_braces(lines[i])
      if(class_started==0){ if(d>0) class_started=1 }
      if(class_started==1){
        depth+=d
        if(depth==0){ insert_line=i; break }
      }
    }
    if(insert_line==-1){
      print "[MERGE][FATAL] Could not find class-closing brace by depth during INSERT tmp_methods." > "/dev/stderr"
      exit 2
    }
    for(i=1;i<insert_line;i++) print lines[i]
    print ""
    while((getline l < addfile)>0) print l
    close(addfile)
    print ""
    for(i=insert_line;i<=NR;i++) print lines[i]
  }
' "$test_file" > "$tmp_out_ins"; then
  echo "[MERGE][FATAL] INSERT tmp_methods awk failed."
  exit 1
fi

mv "$tmp_out_ins" "$test_file"

echo "[DBG] After INSERT tmp_methods (profession-related):"
grep -nE "void[[:space:]]+(testGetProfession|getProfession)" "$test_file" || true


      # cleanup in coda
      echo "[DBG][PERL] CLEANUP"
      perl -0777 -i -pe '1 while s/\n[ \t]*@(?:[A-Za-z0-9_.]*\.)?Test[ \t]*\n[ \t]*\z/\n/s; 1 while s/\n[ \t]*@(?:[A-Za-z0-9_.]*\.)?Test[ \t]*\z/\n/s;' "$test_file"

        # GUARD immediato: verifica che i metodi in tmp_names siano presenti nel target dopo l'inserimento
        missing=0
        while IFS= read -r m; do
          m="$(sanitize_line "$m")"
          [[ -z "$m" ]] && continue

          if ! grep -qE "^[[:space:]]*(public|protected|private)?[[:space:]]*void[[:space:]]+${m}[[:space:]]*\\(" "$test_file"; then
            echo "[MERGE][FATAL] Insert failed: method '${m}' not present RIGHT AFTER insertion."
            missing=1
          fi
        done < "$tmp_names"

        if [[ "$missing" == "1" ]]; then
          echo "[MERGE][FATAL] Tail of file for debug:"
          tail -n 200 "$test_file"
          exit 1
        fi

    # =========================
    # STRUCTURE GUARD (fail-fast): if an @Test appears while inside a method (depth>1), fail.
    # =========================
    tmp_struct_err="$(mktemp)"
    awk '
      function delta_braces(s,   t,o,c){
        t=s; o=gsub(/\{/,"{",t)
        t=s; c=gsub(/\}/,"}",t)
        return o-c
      }

      BEGIN{depth=0; class_started=0}

      {
        line=$0
        d = delta_braces(line)

        # class starts when we see first "{"
        if(class_started==0 && d>0) class_started=1
        if(class_started==1) depth += d

        if(line ~ /^[[:space:]]*@([A-Za-z0-9_.]*\.)?Test([[:space:]]|\(|$)/){
          if(depth > 1){
            print "[STRUCT_GUARD][FATAL] @Test found while inside a method (depth=" depth ") at line " NR > "/dev/stderr"
            exit 2
          }
        }
      }

      END{ exit 0 }
    ' "$test_file" 2> "$tmp_struct_err"
    rc=$?
    if [[ $rc -ne 0 ]]; then
      echo "[MERGE][FATAL] STRUCT_GUARD failed for: $test_file"
      cat "$tmp_struct_err" || true
      echo "[MERGE][FATAL] Neighborhood:"
      nl -ba "$test_file" | sed -n '1,220p' || true
      rm -f "$tmp_struct_err" 2>/dev/null || true
      return 1
    fi
    rm -f "$tmp_struct_err" 2>/dev/null || true

    # =========================
    # FINAL DEDUP @Test (paracadute definitivo)
    # - Collassa sequenze di @Test ripetuti (anche con righe vuote/spazi in mezzo)
    # =========================
    echo "[DBG][PERL] STEP DEDUP"
    perl -0777 -i -pe '
      s/(\n[ \t]*@(?:[A-Za-z0-9_.]*\.)?Test[^\n]*\n)(?:[ \t]*\n)*([ \t]*@(?:[A-Za-z0-9_.]*\.)?Test[^\n]*\n)+/$1/gm;
    ' "$test_file"

    echo "[MERGE][DEBUG] after insertion, checking for case1:"
    grep -nE "public[[:space:]]+void[[:space:]]+test[A-Za-z0-9_]+_case[0-9]+[[:space:]]*\(" "$test_file" | head -n 50 || true

  rm -f "$tmp_methods" "$tmp_names"
  rm -f "$tmp_fields" "$tmp_before"
  #rm -f "$gen_file"

    # ===== Ensure static org.junit.Assert.* if any assert* is used =====
    if grep -qE '\bassert(A|T|F|N|E)[A-Za-z0-9_]*\s*\(' "$test_file"; then
      ensure_static_import "$test_file" "org.junit.Assert.*"
    fi

echo "[MERGE][DEBUG] TARGET methods AFTER FINAL INSERT (first 50 case methods):"
echo "[DBG] Top-level assert lines (should be NONE):"

awk '
  function brace_delta(s,   t,o,c){
    t=s
    o=gsub(/\{/,"{",t)
    t=s
    c=gsub(/\}/,"}",t)
    return o-c
  }

  BEGIN{
    depth=0
    class_started=0
  }

  {
    d = brace_delta($0)

    # La classe inizia alla prima {
    if(class_started==0 && d>0){
      class_started=1
    }

    if(class_started==1){
      depth += d
    }

    # depth == 1  → siamo nel corpo della classe
    # ma NON dentro un metodo
    if(class_started==1 && depth==1 && $0 ~ /(^|[^A-Za-z0-9_])assert[A-Za-z0-9_]*[[:space:]]*\(/){
      print NR ":" $0
    }
  }
' "$test_file" | head -n 50 || true

# salva per debug e poi elimina generated (per evitare compile doppio)
  rm -f "$req_bases_ext" 2>/dev/null || true

# =========================
# FINAL ORPHAN @Test CLEANUP (ULTIMO PARACADUTE)
# Rimuove qualunque @Test non seguito da una signature valida
# =========================
tmp_orphan_final="$(mktemp)"
awk '
  { lines[NR]=$0 }
  END{
    for(i=1;i<=NR;i++){
      if(lines[i] ~ /^[[:space:]]*@([A-Za-z0-9_.]*\.)?Test([[:space:]]|\(|$)[[:space:]]*$/){
        j=i+1
        while(j<=NR && lines[j] ~ /^[[:space:]]*$/) j++
        # se EOF, altro @Test o NON una signature -> elimina
        if(j>NR) continue
        if(lines[j] ~ /^[[:space:]]*@([A-Za-z0-9_.]*\.)?Test([[:space:]]|\(|$)/) continue
        if(lines[j] !~ /^[[:space:]]*(public|protected|private)?[[:space:]]*(static[[:space:]]+)?void[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\(/) continue
      }
      print lines[i]
    }
  }
' "$test_file" > "$tmp_orphan_final" && mv "$tmp_orphan_final" "$test_file"

# =========================
# FINAL GUARD (fail-fast): do NOT trim. If structure is broken, fail attempt.
# - braces must balance (class close found)
# - no non-whitespace garbage after class-closing brace
# =========================
tmp_guard_out="$(mktemp)"
awk '
  function brace_delta(s,   t,o,c){
    t=s; o=gsub(/\{/,"{",t)
    t=s; c=gsub(/\}/,"}",t)
    return o-c
  }

  { lines[NR]=$0 }

  END{
    depth=0; class_started=0; cut=-1;

    for(i=1;i<=NR;i++){
      d = brace_delta(lines[i])

      if(class_started==0){
        if(d>0) class_started=1
      }

      if(class_started==1){
        depth += d
        if(depth==0){
          cut=i
          break
        }
      }
    }

    if(cut==-1){
      print "[FINAL_GUARD][FATAL] Cannot find class-closing brace (unbalanced braces)." > "/dev/stderr"
      exit 2
    }

    # After cut line, only whitespace allowed
    for(i=cut+1;i<=NR;i++){
      if(lines[i] !~ /^[[:space:]]*$/){
        print "[FINAL_GUARD][FATAL] Trailing garbage after class closing brace at line " cut ": line " i " => " lines[i] > "/dev/stderr"
        exit 3
      }
    }

    exit 0
  }
' "$test_file" > "$tmp_guard_out" 2> "${tmp_guard_out}.err"
guard_rc=$?

if [[ $guard_rc -ne 0 ]]; then
  echo "[MERGE][FATAL] FINAL_GUARD failed for: $test_file"
  echo "[MERGE][FATAL] Guard stderr:"
  cat "${tmp_guard_out}.err" || true
  echo "[MERGE][FATAL] Tail of file for debug:"
  tail -n 200 "$test_file" || true
  rm -f "$tmp_guard_out" "${tmp_guard_out}.err" 2>/dev/null || true
  return 1
fi

rm -f "$tmp_guard_out" "${tmp_guard_out}.err" 2>/dev/null || true

  echo "[MERGE] Replaced/added regenerated @Test methods into: $test_file"

 # =========================
 # FINAL GUARD (fail-fast)
 # - non tronca nulla
 # - fallisce se:
 #   * non trova la chiusura della classe
 #   * trova contenuto non-whitespace dopo la chiusura
 # =========================
 tmp_final_guard_err="$(mktemp)"
 awk '
   function brace_delta(s,   t,o,c){
     t=s; o=gsub(/\{/,"{",t)
     t=s; c=gsub(/\}/,"}",t)
     return o-c
   }

   { lines[NR]=$0 }

   END{
     depth=0; class_started=0; cut=-1;

     for(i=1;i<=NR;i++){
       d = brace_delta(lines[i])
       if(class_started==0 && d>0) class_started=1
       if(class_started==1){
         depth += d
         if(depth==0){
           cut=i
           break
         }
       }
     }

     if(cut==-1){
       print "[FINAL_GUARD][FATAL] Cannot find class-closing brace (unbalanced braces)." > "/dev/stderr"
       exit 2
     }

     for(i=cut+1;i<=NR;i++){
       if(lines[i] !~ /^[[:space:]]*$/){
         print "[FINAL_GUARD][FATAL] Trailing garbage after class closing brace at line " i ":" > "/dev/stderr"
         print lines[i] > "/dev/stderr"
         exit 3
       }
     }

     exit 0
   }
 ' "$test_file" 2> "$tmp_final_guard_err"
 guard_rc=$?

 if [[ $guard_rc -ne 0 ]]; then
   echo "[MERGE][FATAL] FINAL_GUARD failed for $test_file"
   cat "$tmp_final_guard_err" || true
   echo "[MERGE][FATAL] Tail of file for debug:"
   tail -n 200 "$test_file" || true
   rm -f "$tmp_final_guard_err" 2>/dev/null || true
   return 1
 fi

 rm -f "$tmp_final_guard_err" 2>/dev/null || true

  echo "[DBG] FINAL CHECK: required *_case1 present?"
  while IFS= read -r base; do
    base="$(sanitize_line "$base")"
    [[ -z "$base" ]] && continue
    if ! grep -qE "public[[:space:]]+void[[:space:]]+${base}_case1[[:space:]]*\\(" "$test_file"; then
      echo "[DBG] MISSING required case1: ${base}_case1"
    else
      grep -nE "public[[:space:]]+void[[:space:]]+${base}_case1[[:space:]]*\\(" "$test_file" | head -n 3
    fi
  done < "$req_bases"

  # cleanup temp required files (DOPO il FINAL CHECK)
    rm -f "$req_bases" 2>/dev/null || true
    rm -f "$req_bases_ext" 2>/dev/null || true
    rm -f "$regen_bases" 2>/dev/null || true
    rm -f "$req_prods" 2>/dev/null || true

    # =========================
    # GUARD: nessun metodo di test duplicato nel TARGET
    # (se succede, fallisci subito: meglio che nascondere il problema)
    # =========================
    local tmp_dups
    tmp_dups="$(mktemp)"

    awk '
      function is_sig(line){
        return (line ~ /^[[:space:]]*(public|protected|private)?[[:space:]]*(static[[:space:]]+)?void[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\(/);
      }
      function extract_name(line,   t){
        t=line
        sub(/.*void[[:space:]]+/,"",t)
        sub(/\(.*/,"",t)
        gsub(/[[:space:]]+/,"",t)
        return t
      }
      {
        if(is_sig($0)){
          n = extract_name($0)
          if(n != "") cnt[n]++
        }
      }
      END{
        for(n in cnt){
          if(cnt[n] > 1) print n "\t" cnt[n]
        }
      }
    ' "$test_file" | sort > "$tmp_dups"

    if [[ -s "$tmp_dups" ]]; then
      echo "[MERGE][FATAL] Duplicate test method names detected in TARGET:"
      cat "$tmp_dups"
      echo "[MERGE][FATAL] Showing occurrences (line numbers):"
      while IFS=$'\t' read -r n c; do
        grep -nE "^[[:space:]]*(public|protected|private)?[[:space:]]*(static[[:space:]]+)?void[[:space:]]+${n}[[:space:]]*\\(" "$test_file" || true
      done < "$tmp_dups"
      exit 1
    fi

    rm -f "$tmp_dups" 2>/dev/null || true

    ensure_import "$test_file" "listener.BaseCoverageTest"
    ensure_test_extends_base "$test_file" "BaseCoverageTest"

  return 0
}




# ===================== Step 1: Modified Classes Extractor =====================
extract_modified_classes() {
  sep
  echo "[1] Extract modified classes via git diff --name-only..."

  local files

  # =========================
  # DIFF RANGE (safe)
  # =========================
  BASE_REF="${BASE_REF:-HEAD~1}"
  TARGET_REF="${TARGET_REF:-}"

  if [[ -n "$TARGET_REF" ]]; then
    echo "[1] Using git diff range: $BASE_REF..$TARGET_REF"
    files="$(git diff --name-only "$BASE_REF..$TARGET_REF" -- app/src/main/java || true)"
  else
    echo "[1] Using git diff against: $BASE_REF (working tree)"
    files="$(git diff --name-only "$BASE_REF" -- app/src/main/java || true)"
  fi

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
    local m
    m="$(sanitize_line "$raw")"
    [[ -z "$m" ]] && continue

    jq -r --arg m "$m" '
      def norm: gsub("\r";"") | sub("\\s+$";"");
      ($m | norm) as $M
      | ($M | split(".") | .[-1]) as $short   # es: getName
      | to_entries[]
      | select(
          any(.value[]?; (. | tostring | norm) == $M)
          or
          any(.value[]?; (. | tostring | norm) | test("\\." + ($short|gsub("\\."; "\\\\.")) + "$"))
        )
      | .key
    ' "$COVERAGE_MATRIX_JSON"

  done < "$methods_file" | sort -u
}

# Ritorna i test (chiavi) che coprono un singolo metodo FQN
tests_covering_method() {
  local method_fqn="$1"
  [[ -n "$method_fqn" ]] || return 0
  jq -r --arg m "$method_fqn" '
    to_entries
    | map(select(.value | index($m)))
    | .[].key
  ' "$COVERAGE_MATRIX_JSON"
}

# Ritorna i metodi (value array) coperti da un test (chiave) FQN
methods_covered_by_test() {
  local test_fqn="$1"
  [[ -n "$test_fqn" ]] || return 0
  jq -r --arg t "$test_fqn" '.[$t][]? // empty' "$COVERAGE_MATRIX_JSON"
}

# Chiusura (fixpoint) metodi<->test sulla coverage matrix.
# Input: file con metodi FQN (uno per riga)
# Output: stampa "S_finale" = insieme metodi FQN nel cluster (dedup)
impacted_methods_closure() {
  local seed_methods_file="$1"
  [[ -s "$seed_methods_file" ]] || return 0
  [[ -f "$COVERAGE_MATRIX_JSON" ]] || { echo "[coverage] ERROR: $COVERAGE_MATRIX_JSON not found"; exit 1; }

  local S Snew Tnew
  S="$(mktemp)"; Snew="$(mktemp)"; Tnew="$(mktemp)"

  # S = seed (FQN methods)
  awk '{gsub(/\r/,""); if($0!="") print $0}' "$seed_methods_file" | sort -u > "$S"

  while :; do
    : > "$Tnew"
    : > "$Snew"

    # T = ⋃ tests_covering_method(m) per m in S
    while IFS= read -r m; do
      m="$(sanitize_line "$m")"
      [[ -z "$m" ]] && continue
      tests_covering_method "$m"
    done < "$S" | sort -u > "$Tnew"

    # S' = S ∪ ⋃ methods_covered_by_test(t) per t in T
    cat "$S" > "$Snew"
    while IFS= read -r t; do
      t="$(sanitize_line "$t")"
      [[ -z "$t" ]] && continue

      methods_covered_by_test "$t" | awk -F. '
        {
          gsub(/\r/,"");
          if(NF >= 2){
            cls = $(NF-1);
            m   = $NF;

            # constructor reported as ClassName.ClassName
            if(m == cls) next;

            # (extra safety) constructor sometimes appears as <init>
            if(m == "<init>") next;
          }
          if($0 != "") print $0;
        }
      '
    done < "$Tnew" | sort -u >> "$Snew"
    sort -u "$Snew" -o "$Snew"

    # stop se non cresce
    if cmp -s "$S" "$Snew"; then
      cat "$S"
      rm -f "$S" "$Snew" "$Tnew"
      return 0
    fi

    mv "$Snew" "$S"
  done
}

# Chiusura sui test: dato un seed di metodi, ritorna i test nel cluster (dedup)
impacted_tests_closure() {
  local seed_methods_file="$1"
  local expected_test_class="${2:-}"   # es: utente.personale.TecnicoTest (opzionale)
  [[ -s "$seed_methods_file" ]] || return 0

  local tmpS
  tmpS="$(mktemp)"
  impacted_methods_closure "$seed_methods_file" > "$tmpS"

  while IFS= read -r m; do
    m="$(sanitize_line "$m")"
    [[ -z "$m" ]] && continue
    tests_covering_method "$m"
  done < "$tmpS" | sort -u | {
    if [[ -n "$expected_test_class" ]]; then
      awk -v pref="${expected_test_class}." 'index($0,pref)==1 {print $0}'
    else
      cat
    fi
  }

  rm -f "$tmpS"
}

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

# ===================== Branch ii: DELETED =====================================
branch_deleted() {
  sep
  echo "[BRANCH ii] DELETED methods -> use coverage to find covering tests -> delete those tests + benchmarks + coverage entries"

  # Se non ci sono metodi eliminati, esci
  if [[ ! -s "$DELETED_METHODS_FILE" ]]; then
    echo "[BRANCH ii] No deleted methods. Skip."
    return 0
  fi

  # Coverage path (per questo branch va bene così)
  local COVERAGE_PATH="app/coverage-matrix.json"

  # Se la coverage non esiste, la rigenero (solo per poter fare lookup).
  # NON è "ricreare da 0" a prescindere: lo faccio solo se manca.
  if [[ ! -f "$COVERAGE_PATH" ]]; then
    echo "[BRANCH ii] coverage not found at $COVERAGE_PATH -> generating via MainTestSuite..."
    ./gradlew :app:test --tests "suite.MainTestSuite" --rerun-tasks

    if [[ ! -f "$COVERAGE_PATH" ]]; then
      echo "[BRANCH ii] ERROR: $COVERAGE_PATH was not generated!"
      exit 1
    fi
  fi

  # 1) Coverage lookup: deleted methods -> test cases that cover them
  # (Questa è la regola chiave: usiamo la coverage come “mappa inversa”)
  tests_covering_methods "$DELETED_METHODS_FILE" > "$TESTS_TO_DELETE_FILE" || true

  # Pulizia lista test: trim + remove empty
  local tmp_clean
  tmp_clean="$(mktemp)"
  awk '{$1=$1} NF' "$TESTS_TO_DELETE_FILE" > "$tmp_clean"
  mv "$tmp_clean" "$TESTS_TO_DELETE_FILE"

  echo "[BRANCH ii] Test methods to delete (from coverage-matrix):"
  if [[ -s "$TESTS_TO_DELETE_FILE" ]]; then
    cat "$TESTS_TO_DELETE_FILE"
  else
    echo "(none) -> No covering tests found in coverage. Skip."
    return 0
  fi

  # 2) Remove JUnit test methods precisely (NOT whole class)
  echo "[BRANCH ii] Pruning JUnit test methods from $TEST_ROOT ..."
  java -cp "$AST_JAR" TestPruner "$TESTS_TO_DELETE_FILE" "$TEST_ROOT"

  # 3) Remove benchmark methods precisely (benchmark_<testMethod>) from inner class _Benchmark
  echo "[BRANCH ii] Pruning benchmark methods from $BENCH_ROOT ..."
  java -cp "$AST_JAR" BenchmarkPruner "$TESTS_TO_DELETE_FILE" "$BENCH_ROOT"

  # 4) Update coverage-matrix: remove entries whose key is a deleted test method
  # Versione robusta: niente del_args enorme, niente quoting fragile.
  echo "[BRANCH ii] Updating coverage-matrix (removing deleted test entries)..."
  local tmp_cov
  tmp_cov="$(mktemp)"

  jq --rawfile keys "$TESTS_TO_DELETE_FILE" '
    ($keys | split("\n") | map(select(length>0))) as $ks
    | reduce $ks[] as $k (. ; del(.[$k]))
  ' "$COVERAGE_PATH" > "$tmp_cov" && mv "$tmp_cov" "$COVERAGE_PATH"

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

    # =========================
    # Init helpers/files for this entry
    # =========================
    local expected_test_class
    expected_test_class="${class_fqn}Test"   # e.g. utente.personale.TecnicoTest

    local tmp_tests_to_regen
    tmp_tests_to_regen="$(mktemp)"
    : > "$tmp_tests_to_regen"

    local tmp_methods_for_chat2
    tmp_methods_for_chat2="$(mktemp)"
    : > "$tmp_methods_for_chat2"

    # =========================
        # (1) Seed-only tests covering modified methods (entry-local)
        # =========================
        tmp_seed_tests="$(mktemp)"
        tests_covering_methods "$tmp_methods_file" \
          | awk -v pref="${expected_test_class}." 'index($0,pref)==1 {print $0}' \
          | sed 's/\r$//' | sort -u > "$tmp_seed_tests"

        echo "[BRANCH i] Seed tests covering modified methods:"
        cat "$tmp_seed_tests" || true

        if [[ ! -s "$tmp_seed_tests" ]]; then
          echo "(none) -> nothing to regenerate for this entry"
          rm -f "$single_json" "$tmp_methods_file" "$tmp_tests_to_regen" "$tmp_methods_for_chat2" "$tmp_seed_tests" 2>/dev/null || true
          continue
        fi

        # =========================
        # (1a) Expand via methods covered by seed tests (1-hop), EXCLUDING constructors
        #   M0 = union of methods covered by seed tests, filtered
        #   T1 = tests covering any method in M0 (entry-local)
        # =========================
        tmp_methods_from_seed="$(mktemp)"
        : > "$tmp_methods_from_seed"

        while IFS= read -r t; do
          t="$(sanitize_line "$t")"
          [[ -z "$t" ]] && continue
          methods_covered_by_test "$t"
        done < "$tmp_seed_tests" \
          | awk -F. '
              {
                gsub(/\r/,"");
                if(NF>=2){
                  cls=$(NF-1);
                  m=$NF;
                  if(m==cls) next;      # constructor Class.Class
                  if(m=="<init>") next; # constructor alt
                }
                if($0!="") print $0
              }
            ' \
          | sort -u > "$tmp_methods_from_seed"

        echo "[BRANCH i] Methods covered by seed tests (filtered, no constructors):"
        sed 's/^/ - /' "$tmp_methods_from_seed" || true

        tmp_more_tests="$(mktemp)"
        : > "$tmp_more_tests"

        while IFS= read -r m; do
          m="$(sanitize_line "$m")"
          [[ -z "$m" ]] && continue
          tests_covering_method "$m"
        done < "$tmp_methods_from_seed" \
          | awk -v pref="${expected_test_class}." 'index($0,pref)==1 {print $0}' \
          | sed 's/\r$//' | sort -u > "$tmp_more_tests"

        echo "[BRANCH i] Extra tests via 1-hop expansion:"
        cat "$tmp_more_tests" || true

        # Union: T = T0 ∪ T1
        cat "$tmp_seed_tests" "$tmp_more_tests" | sort -u > "$tmp_tests_to_regen"
        rm -f "$tmp_seed_tests" "$tmp_more_tests" "$tmp_methods_from_seed" 2>/dev/null || true

        # =========================
        # (1b) AUGMENT: se c'è testX_caseN, aggiungi anche testX base
        # =========================
        tmp_aug="$(mktemp)"
        awk '
          {
            print $0
            if (match($0, /_case[0-9]+$/)) {
              base = substr($0, 1, RSTART-1)
              print base
            }
          }
        ' "$tmp_tests_to_regen" | sed 's/\r$//' | sort -u > "$tmp_aug"
        mv "$tmp_aug" "$tmp_tests_to_regen"

        echo "[BRANCH i] Tests covering these methods (1-hop, entry-local, augmented):"
        cat "$tmp_tests_to_regen"

    echo "[BRANCH i] Tests covering these methods (closure, entry-local):"
    if [[ -s "$tmp_tests_to_regen" ]]; then
      cat "$tmp_tests_to_regen"
    else
      echo "(none) -> nothing to regenerate for this entry"
      rm -f "$single_json" "$tmp_methods_file" "$tmp_tests_to_regen" "$tmp_methods_for_chat2" 2>/dev/null || true
      continue
    fi

    # =========================
    # (2) METHODS for Chat2UnitTest: derivati SOLO dai test che rigeneri (coerenza totale)
    #     Regola: utente.XTest.testSetName_case3  -> setName
    #             utente.XTest.testGetSurname     -> getSurname
    # =========================
    while IFS= read -r full; do
      full="$(sanitize_line "$full")"
      [[ -z "$full" ]] && continue

      tmethod="${full##*.}"              # es: testSetName_case3
      base="$(echo "$tmethod" | sed -E 's/_case[0-9]+$//')"    # es: testSetName
      base="${base#test}"                # es: SetName
      [[ -z "$base" ]] && continue
      prod="$(tr '[:upper:]' '[:lower:]' <<< "${base:0:1}")${base:1}"   # setName
      echo "$prod"
    done < "$tmp_tests_to_regen" | sort -u > "$tmp_methods_for_chat2"

    echo "[BRANCH i] Methods for Chat2UnitTest (derived from tests_to_regen):"
    sed 's/^/ - /' "$tmp_methods_for_chat2"

    # =========================
    # REBUILD single_json using expanded methods (coverage-driven)
    # Sovrascrive il single_json iniziale (che conteneva solo i modified)
    # =========================
    tmp_methods_json="$(mktemp)"
    jq -R -s -c '
      split("\n")
      | map(gsub("\r$";""))
      | map(select(length>0))
      | sort
      | unique
    ' "$tmp_methods_for_chat2" > "$tmp_methods_json"

    jq -n --arg fp "$prod_fp" --slurpfile arr "$tmp_methods_json" \
      '{($fp): $arr[0]}' > "$single_json"

    rm -f "$tmp_methods_json" 2>/dev/null || true

    echo "[BRANCH i] Single-entry JSON (coverage-driven expanded):"
    cat "$single_json"

    # 2) Test classes to validate for this entry
    local test_classes_file
    test_classes_file="$(mktemp)"
    extract_test_classes "$tmp_tests_to_regen" > "$test_classes_file"

    echo "[BRANCH i] Test classes to validate (this entry):"
    cat "$test_classes_file"

    # 3) Prune JUnit test methods for THIS entry (bench prune is done only on success) (modificato momentaneamente)
    #echo "[BRANCH i] Pruning old JUnit test methods (this entry)..."
    #java -cp "$AST_JAR" TestPruner "$tmp_tests_to_regen" "$TEST_ROOT"

    # 4) Retry loop for THIS entry
    # Backup "pristine" UNA SOLA VOLTA (fuori dal retry loop)
          while IFS= read -r cls; do
            cls="$(sanitize_line "$cls")"
            [[ -z "$cls" ]] && continue

            tf="$(fqn_to_test_path "$cls")"
            bak="${tf}.pristine"

            if [[ -f "$tf" && ! -f "$bak" ]]; then
              cp -f "$tf" "$bak"
              echo "[BRANCH i] Saved pristine backup: $bak"
            fi
          done < "$test_classes_file"

          local attempt=1
          while [[ "$attempt" -le "$MAX_CHAT2UNITTEST_ATTEMPTS" ]]; do
            sep
            echo "[BRANCH i] Entry attempt $attempt/$MAX_CHAT2UNITTEST_ATTEMPTS for $class_fqn"

            # Ripristina SEMPRE il target dal pristine ad ogni attempt (riparti pulito)
            while IFS= read -r cls; do
              cls="$(sanitize_line "$cls")"
              [[ -z "$cls" ]] && continue

              tf="$(fqn_to_test_path "$cls")"
              bak_base="${tf}.baseline"
              bak_pristine="${tf}.pristine"

              if [[ -f "$bak_base" ]]; then
                cp -f "$bak_base" "$tf"
                echo "[BRANCH i] Restored baseline into target: $tf"
              elif [[ -f "$bak_pristine" ]]; then
                cp -f "$bak_pristine" "$tf"
                echo "[BRANCH i] Restored pristine backup into target: $tf"
              fi
              # --- enforce BaseCoverageTest after restore ---
              ensure_import "$tf" "listener.BaseCoverageTest"
              ensure_test_extends_base "$tf" "BaseCoverageTest"
            done < "$test_classes_file"

            # riapplica extends DOPO restore (baseline/pristine)
            while IFS= read -r cls; do
              cls="$(sanitize_line "$cls")"
              [[ -z "$cls" ]] && continue
              tf="$(fqn_to_test_path "$cls")"
              ensure_test_extends_base "$tf" "BaseCoverageTest"
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
            export REQUIRED_TESTS_FILE="$tmp_tests_to_regen"
            local merge_failed=0

            while IFS= read -r cls; do
              cls="$(sanitize_line "$cls")"
              [[ -z "$cls" ]] && continue

              local tf
              tf="$(fqn_to_test_path "$cls")"

              if ! merge_generated_tests "$tf"; then
                echo "[BRANCH i] Merge failed for $tf"
                merge_failed=1
              else
                # IMPORTANT: do not let *.generated.java be compiled by Gradle
                rm -f "${tf%.java}.generated.java" 2>/dev/null || true
              fi
            done < "$test_classes_file"

          # --- enforce BaseCoverageTest after merge (LLM può riscrivere la class header) ---
          while IFS= read -r cls; do
            cls="$(sanitize_line "$cls")"
            [[ -z "$cls" ]] && continue
            tf="$(fqn_to_test_path "$cls")"

            ensure_import "$tf" "listener.BaseCoverageTest"
            ensure_test_extends_base "$tf" "BaseCoverageTest"
          done < "$test_classes_file"

      # ==========================================================
      # BLOCCO ensure_test_extends_base
      # ==========================================================
      while IFS= read -r cls; do
        cls="$(sanitize_line "$cls")"
        [[ -z "$cls" ]] && continue
        tf="$(fqn_to_test_path "$cls")"
        ensure_test_extends_base "$tf" "BaseCoverageTest"
      done < "$test_classes_file"

      # ===== CLEANUP: rimuovi SEMPRE i .generated.java prodotti da Chat2UnitTest
      # (altrimenti Gradle compila anche quelli e hai "duplicate class")
      while IFS= read -r cls; do
        cls="$(sanitize_line "$cls")"
        [[ -z "$cls" ]] && continue
        tf="$(fqn_to_test_path "$cls")"
        rm -f "${tf%.java}.generated.java" 2>/dev/null || true
      done < "$test_classes_file"

      if [[ "$merge_failed" -eq 1 ]]; then
        echo "[BRANCH i] Merge failed -> restoring backups and skipping gradle for this attempt."
        for tf in "${!backups[@]}"; do
          local bak="${backups[$tf]}"
          [[ -f "$bak" ]] && cp -f "$bak" "$tf"
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
          [[ -f "$bak" ]] && cp -f "$bak" "$tf"
        done
        attempt=$((attempt+1))
        continue
      fi

      # =========================
      # Guard: generic sanity checks AFTER merge
      # - file exists + non-empty
      # - package/class ok (già li controlli nell’altro guard)
      # - at least one @Test
      # - no duplicate method names (prevents "already defined")
      # - (optional) test calls the modified production methods
      # =========================
      local bad=0

      while IFS= read -r cls; do
        cls="$(sanitize_line "$cls")"
        [[ -z "$cls" ]] && continue

        local tf
        tf="$(fqn_to_test_path "$cls")"

        if [[ ! -s "$tf" ]]; then
          echo "[BRANCH i] Missing/empty merged test file: $tf"
          bad=1
          continue
        fi

        # almeno un @Test
        if ! grep -qE '^[[:space:]]*@Test([[:space:]]|\(|$)' "$tf"; then
          echo "[BRANCH i] No @Test methods found in: $tf"
          bad=1
        fi

        # niente duplicati sui nomi metodo (public void nome(...))
        dups="$(grep -E '^[[:space:]]*(public|protected|private)?[[:space:]]*(static[[:space:]]+)?void[[:space:]]+[[:space:]]+[A-Za-z0-9_]+\s*\(' "$tf" \
          | sed -E 's/.*void[[:space:]]+([A-Za-z0-9_]+).*/\1/' \
          | sort | uniq -d || true)"

        if [[ -n "${dups:-}" ]]; then
          echo "[BRANCH i] Duplicate method names in $tf:"
          echo "$dups" | sed 's/^/  - /'
          bad=1
        fi

      # =========================
      # GUARD (regen-based):
      # Valida SOLO i test che risultano effettivamente rigenerati in questo file:
      # - ricava le basi da tutti i metodi "*_case1" presenti nel file di test
      # - se non c'è nemmeno un _case1 => merge non ha inserito nulla => FAIL
      # =========================

      # req_bases_local: required bases (coverage) for THIS test class
      req_bases_local="$(mktemp)"

      # calcola FQN della test class corrente (pkg + cls)
      pkg="$(grep -m1 -E '^[[:space:]]*package[[:space:]]+' "$tf" | sed -E 's/^[[:space:]]*package[[:space:]]+([^;]+);.*/\1/')"
      cls="$(basename "$tf" .java)"
      if [[ -n "$pkg" ]]; then
        cls_fqn="${pkg}.${cls}"
      else
        cls_fqn="$cls"
      fi

      # estrai basi richieste dalla coverage per questa classe
      awk -v pref="${cls_fqn}." 'index($0,pref)==1 {print substr($0, length(pref)+1)}' \
        "$REQUIRED_TESTS_FILE" | sed 's/\r$//' | sort -u > "$req_bases_local"

      # Guard (robusto): controlla SOLO ciò che esiste davvero nel file dopo merge
            # cioè le basi che hanno almeno un *_case1 nel target.
            regen_bases_local="$(mktemp)"

            grep -oE "public[[:space:]]+void[[:space:]]+[A-Za-z0-9_]+_case1[[:space:]]*\\(" "$tf" \
              | sed -E 's/.*void[[:space:]]+([A-Za-z0-9_]+)_case1.*/\1/' \
              | sort -u > "$regen_bases_local"

            if [[ ! -s "$regen_bases_local" ]]; then
              echo "[BRANCH i] No '*_case1' methods found after merge in: $tf"
              bad=1
            else
              while IFS= read -r base_method; do
                base_method="$(sanitize_line "$base_method")"
                [[ -z "$base_method" ]] && continue

                if ! grep -qE "public[[:space:]]+void[[:space:]]+${base_method}_case1[[:space:]]*\\(" "$tf"; then
                  echo "[BRANCH i] Missing regenerated test '${base_method}_case1' in: $tf"
                  bad=1
                fi
              done < "$regen_bases_local"
            fi

            rm -f "$regen_bases_local"

        # OPTIONAL: assicurati che nel test compaiano chiamate ai metodi modificati
        # (non controlla i NOMI dei test, controlla che vengano chiamati i metodi prod)
        for pm in "${methods_for_file[@]}"; do
          pm="$(sanitize_line "$pm")"
          [[ -z "$pm" ]] && continue
          if ! grep -qE "\b${pm}[[:space:]]*\(" "$tf"; then
            echo "[BRANCH i] No call to modified method '${pm}(' found in: $tf"
            bad=1
          fi
        done

        # =========================
        # CLEANUP SPazzatura:
        # rimuove @Test che chiamano metodi prod modificati (pm)
        # =========================
        local whitelist
        whitelist="$(mktemp)"
        cat "$req_bases_local" 2>/dev/null | sed 's/\r$//' | sort -u > "$whitelist"
        echo "[DBG] whitelist path: $whitelist"
        echo "[DBG] whitelist size: $(wc -l < "$whitelist")"
        nl -ba "$whitelist" | head -n 20
        # Usa la whitelist già creata sopra (adatta il nome variabile se diverso)
        WHITELIST_FILE="$whitelist"
        for pm in "${methods_for_file[@]}"; do
          pm="$(sanitize_line "$pm")"
          [[ -z "$pm" ]] && continue

          # file whitelist già creato prima (dal tuo log: "[DBG] whitelist path: ...")
          # supponiamo sia in variabile: whitelist_path
          # se nel tuo script si chiama diversamente, usa quella variabile.

          tmp_cleanup="$(mktemp)"
          awk -v WL="$whitelist" -v PM="$pm" '
            BEGIN{
              while((getline x < WL)>0){ gsub(/\r/,"",x); if(x!="") ok[x]=1 }
              close(WL)
              inBlock=0; buf=""; brace=0; started=0; name=""; keep=1; calls=0;
            }

            function is_test_anno(line){ return line ~ /^[[:space:]]*@([A-Za-z0-9_.]*\.)?Test/ }
            function is_sig(line){ return line ~ /^[[:space:]]*(public|protected|private)?[[:space:]]*(static[[:space:]]+)?void[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\(/ }

            function extract_name(line, t){
              t=line; sub(/.*void[[:space:]]+/,"",t); sub(/\(.*/,"",t); gsub(/[[:space:]]+/,"",t); return t
            }

            function base_of(n, t){
              t=n
              sub(/_case[0-9]+$/,"",t)
              return t
            }

            function brace_delta(s, t,o,c){
              t=s; o=gsub(/\{/,"{",t); t=s; c=gsub(/\}/,"}",t); return o-c
            }

            function is_whitelisted_base(b,   x, bx){
              # Caso 1: la whitelist contiene esattamente la base (raro, ma ok)
              if (b in ok) return 1

              # Caso 2: esiste almeno un case whitelisted per questa base
              for (x in ok) {
                if (index(x, b "_case") == 1) return 1
              }

              # Caso 3: fallback generico: qualunque entry whitelisted che inizi con b + "_case"
              for (x in ok) {
                if (index(x, b "_case") == 1) return 1
              }

              return 0
            }

            {
              line=$0

              if(!inBlock && is_test_anno(line)){
                inBlock=1; buf=line "\n"; brace=0; started=0; name=""; keep=1; calls=0;
                next
              }

              if(inBlock){
                buf = buf line "\n"

                if(name=="" && is_sig(line)){
                  name = extract_name(line)
                }

                if(line ~ (PM "[[:space:]]*\\(")) calls=1

                d = brace_delta(line)
                if(d != 0){ started=1; brace += d }

                if(started && brace==0){
                  b = base_of(name)

                  # drop se chiama PM e la base NON è whitelisted
                  if (name in ok) keep=1
                  else if(calls && !is_whitelisted_base(b)) keep=0

                  if(keep) printf "%s", buf

                  inBlock=0; buf=""; brace=0; started=0; name=""; keep=1; calls=0
                }
                next
              }

              print
            }
          ' "$tf" > "$tmp_cleanup" && mv "$tmp_cleanup" "$tf"
        done


        rm -f "$whitelist"
        rm -f "$req_bases_local"

      done < "$test_classes_file"

      echo "[DBG] After CLEANUP spazzatura, department case methods present?"
      echo "[DBG] Department signatures AFTER CLEANUP spazzatura:"
      grep -nE "public[[:space:]]+void[[:space:]]+test(Get|Set)Department" "$tf" || echo "(none)"
      echo "[DBG] Department calls AFTER CLEANUP spazzatura:"
      grep -n "getDepartment" "$tf" || echo "(none)"
      grep -nE "void[[:space:]]+([A-Za-z0-9_]*GetDepartment|[A-Za-z0-9_]*getDepartment|testGetDepartment|getDepartment)[A-Za-z0-9_]*_case[0-9]+[[:space:]]*\\(" "$tf" || true

      if [[ "$bad" -eq 1 ]]; then
        echo "[BRANCH i] Guard failed -> restoring backups and retrying."
        for tf in "${!backups[@]}"; do
          bak="${backups[$tf]}"
          [[ -f "$bak" ]] && cp -f "$bak" "$tf"
        done
        attempt=$((attempt+1))
        continue
      fi

      # Validate ONLY these classes
      echo "[BRANCH i] Validating regenerated tests (only affected classes for this entry)..."
      mapfile -t gradle_args < <(build_gradle_tests_args "$test_classes_file")

      echo "================ DEBUG PRE-COMPILE STRUCTURE ================"
      echo "[DBG] Entries listed in: $test_classes_file"

      while IFS= read -r entry; do
        entry="$(sanitize_line "$entry")"
        [[ -z "$entry" ]] && continue

        # entry può essere:
        # - un path .java
        # - un FQN (utente.personale.AmministratoreTest)
        # - un nome semplice (AmministratoreTest) (raro)
        if [[ "$entry" == *".java" ]]; then
          tf="$entry"
        else
          # FQN -> path sotto app/src/test/java
          tf="app/src/test/java/$(echo "$entry" | tr '.' '/')".java
        fi

        if [[ ! -f "$tf" ]]; then
          echo "----- [DBG] SKIP: cannot find file for entry='$entry' -> '$tf' -----"
          continue
        fi

        echo "----- [DBG] FILE: $tf (from entry='$entry') -----"
        echo "[DBG] Showing lines 1–200:"
        nl -ba "$tf" | sed -n '1,200p'

        echo "[DBG] Checking for consecutive @Test annotations:"
        awk '
          BEGIN{ prev_test=0 }
          /^[[:space:]]*@([A-Za-z0-9_.]*\.)?Test([[:space:]]|\(|$)/ {
            if (prev_test == 1) {
              print "DOUBLE @Test at line " NR ": " $0
            }
            prev_test=1
            next
          }
          /^[[:space:]]*$/ { next }   # righe vuote NON azzerano
          { prev_test=0 }
        ' "$tf" || true

        echo "[DBG] Checking for orphan @Test annotations:"
        awk '
          function is_sig(s){
            return (s ~ /^[[:space:]]*(public|protected|private)?[[:space:]]*(static[[:space:]]+)?void[[:space:]]+/)
          }
          { lines[NR] = $0 }
          END {
            for (i = 1; i <= NR; i++) {
              if (lines[i] ~ /^[[:space:]]*@([A-Za-z0-9_.]*\.)?Test([[:space:]]|\(|$)/) {
                j = i + 1
                while (j <= NR && lines[j] ~ /^[[:space:]]*$/) j++
                if (j > NR || !is_sig(lines[j])) print "ORPHAN @Test at line " i
              }
            }
          }
        ' "$tf" || true

        echo "[DBG] Test method signatures:"
        grep -nE '^[[:space:]]*(public|protected|private)?[[:space:]]*(static[[:space:]]+)?void[[:space:]]+test[A-Za-z0-9_]*' "$tf" || true

      done < "$test_classes_file"

      echo "============== END DEBUG PRE-COMPILE STRUCTURE =============="


      echo "================ DEBUG RIGHT BEFORE GRADLE ================"
      echo "[DBG] tf=$tf"

      echo "[DBG] Any Department-related method signatures (case tests):"
      grep -nE "void[[:space:]]+([A-Za-z0-9_]*GetDepartment|[A-Za-z0-9_]*getDepartment|testGetDepartment|getDepartment)[A-Za-z0-9_]*_case[0-9]+[[:space:]]*\\(" "$tf" \
        || echo "(none)"

      echo "[DBG] Any occurrences of getDepartment call:"
      grep -nE "\\.getDepartment[[:space:]]*\\(" "$tf" | head -n 30 || echo "(none)"

      echo "[DBG] Double @Test (consecutive) in tf:"
      awk '
        BEGIN{prev=0}
        /^[[:space:]]*@([A-Za-z0-9_.]*\.)?Test/{
          if(prev==1) print "DOUBLE @Test at line " NR ": " $0
          prev=1
          next
        }
        /^[[:space:]]*$/ { next }
        { prev=0 }
      ' "$tf" | head -n 50 || true

      echo "==========================================================="

        # =========================
        # PURGE coverage-matrix.json: rimuovi BASE + *_caseN per i test richiesti (prima di eseguire i test)
        # =========================
        echo "[DBG][COV] Keys matching required bases BEFORE purge: $(jq -r 'keys[]' "$COVERAGE_MATRIX_JSON" | grep -E "^(utente\.personale\.AmministratoreTest\.test(Get|Set)Department)(_[A-Za-z0-9]+)*(_case[0-9]+)?$" | wc -l || true)"
        echo "[DBG][COV] COVERAGE_MATRIX_JSON path = $COVERAGE_MATRIX_JSON"
        echo "[DBG][COV] Required file path = $REQUIRED_TESTS_FILE"
        echo "[DBG][COV] First 20 required keys:"
        nl -ba "$REQUIRED_TESTS_FILE" | sed -n '1,20p' || true
        purge_coverage_for_required_tests "$REQUIRED_TESTS_FILE" || true
        echo "[DBG][COV] Keys matching required bases AFTER purge:  $(jq -r 'keys[]' "$COVERAGE_MATRIX_JSON" | grep -E "^(utente\.personale\.AmministratoreTest\.test(Get|Set)Department)(_[A-Za-z0-9]+)*(_case[0-9]+)?$" | wc -l || true)"
        echo "[DBG][COV] After purge, keys still present (grep):"
        while IFS= read -r k; do
          k="$(sanitize_line "$k")"
          [[ -z "$k" ]] && continue
          grep -nF "\"$k\"" "$COVERAGE_MATRIX_JSON" && echo "STILL PRESENT: $k"
        done < "$REQUIRED_TESTS_FILE"

        echo "[DBG][COV] After purge, remaining keys for required bases:"

        # SAFE: non usare grep -vE qui, perché REQUIRED_TESTS_FILE spesso contiene SOLO _caseN
        # e grep senza match fa exit 1 => con set -e ti ammazza la pipeline.
        while IFS= read -r full; do
          full="$(sanitize_line "$full")"
          [[ -z "$full" ]] && continue

          if jq -e --arg k "$full" 'has($k)' "$COVERAGE_MATRIX_JSON" >/dev/null 2>&1; then
            echo "STILL PRESENT: $full"
          else
            echo "MISSING: $full"
          fi
        done < "$REQUIRED_TESTS_FILE"

      # ... dopo tutti i guard/cleanup che modificano i file ...
      while IFS= read -r cls; do
        cls="$(sanitize_line "$cls")"
        [[ -z "$cls" ]] && continue
        tf="$(fqn_to_test_path "$cls")"
        ensure_test_extends_base "$tf" "BaseCoverageTest"
      done < "$test_classes_file"

      echo "================ DEBUG RIGHT BEFORE GRADLE (ACTUAL CALL) ================"
      echo "[DBG][GRADLE] pwd=$(pwd)"
      echo "[DBG][GRADLE] test_classes_file=$test_classes_file"
      echo "[DBG][GRADLE] gradle_args count=${#gradle_args[@]}"
      printf "[DBG][GRADLE] gradle_args:\n"; printf '  - %q\n' "${gradle_args[@]}"
      echo "======================================================================="



      set +e
      ./gradlew :app:test --rerun-tasks "${gradle_args[@]}"
      gradle_rc=$?
      set -e

      echo "[DBG][GRADLE] gradle exit code=$gradle_rc"

      if [[ $gradle_rc -eq 0 ]]; then
        echo "[DBG][POST] pwd=$(pwd)"
        echo "[DBG][POST] coverage files:"
        ls -la coverage-matrix.json 2>/dev/null || echo "(no ./coverage-matrix.json)"
        ls -la app/coverage-matrix.json 2>/dev/null || echo "(no app/coverage-matrix.json)"
        # =======================
        # [SUCCESS BLOCK]
        # =======================
        echo "[BRANCH i] Gradle validation OK."
        echo "[BRANCH i] Entry $class_fqn succeeded on attempt $attempt."

        # IMPORTANTISSIMO: assicura extends PRIMA di salvare la baseline
        while IFS= read -r cls; do
          cls="$(sanitize_line "$cls")"
          [[ -z "$cls" ]] && continue
          tf="$(fqn_to_test_path "$cls")"
          ensure_test_extends_base "$tf" "BaseCoverageTest"
        done < "$test_classes_file"

        # Aggiorna la baseline dopo successo (NON toccare .pristine)
        # .baseline = ultimo stato buono, usato per i restore incrementali
        while IFS= read -r cls; do
          ls="$(sanitize_line "$cls")"
          [[ -z "$cls" ]] && continue
          tf="$(fqn_to_test_path "$cls")"
          bak="${tf}.baseline"
          ensure_import "$tf" "listener.BaseCoverageTest"
          ensure_test_extends_base "$tf" "BaseCoverageTest"
          cp -f "$tf" "$bak"
          echo "[BRANCH i] Updated baseline after success: $bak"
        done < "$test_classes_file"


        echo "[DBG][COV] REQUIRED_TESTS_FILE = ===================================================== '$REQUIRED_TESTS_FILE'"

        if [[ -z "$REQUIRED_TESTS_FILE" ]]; then
          echo "[DBG][COV] REQUIRED_TESTS_FILE variable is EMPTY"
        elif [[ ! -f "$REQUIRED_TESTS_FILE" ]]; then
          echo "[DBG][COV] REQUIRED_TESTS_FILE does NOT exist"
        else
          echo "[DBG][COV] REQUIRED_TESTS_FILE exists, content:"
          nl -ba "$REQUIRED_TESTS_FILE"
        fi

        # Now prune old benchmark methods (this entry) and regenerate JMH for OWNER test class
        echo "[BRANCH i] Pruning old benchmark methods (this entry)..."
        java -cp "$AST_JAR" BenchmarkPruner "$tmp_tests_to_regen" "$BENCH_ROOT"

        local owner_test_class="${class_fqn}Test"   # e.g., utente.UtenteTest
        if ! generate_jmh_for_testclass "$owner_test_class"; then
          echo "[BRANCH i] JMH conversion failed for $owner_test_class -> failing pipeline."
          exit 1
        fi

        # delete pristine only on success
        while IFS= read -r cls; do
          cls="$(sanitize_line "$cls")"
          [[ -z "$cls" ]] && continue
          tf="$(fqn_to_test_path "$cls")"
          if [[ "${CLEAN_PRISTINE:-0}" == "1" ]]; then
            rm -f "${tf}.pristine" 2>/dev/null || true
          fi
        done < "$test_classes_file"

        break
      else
        # =======================
        # [FAILURE BLOCK]
        # =======================
        echo "[BRANCH i][FATAL] Gradle validation FAILED."
        echo "[BRANCH i] Entry $class_fqn attempt $attempt failed."
        echo "[BRANCH i] Debug: showing merged test file(s) head (first 160 lines):"
        echo "[BRANCH i] Debug: showing error line neighborhood (lines 45-80):"
        sed -n '45,80p' "app/src/test/java/utente/personale/TecnicoTest.java" || true

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
          [[ -f "$bak" ]] && cp -f "$bak" "$tf"
        done

        attempt=$((attempt+1))
        continue
      fi
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
  echo "[BRANCH iii] ADDED methods -> per-entry generation + targeted gradle run (coverage update)"

  if [[ ! -s "$ADDED_METHODS_FILE" ]]; then
    echo "[BRANCH iii] No added methods. Skip."
    return 0
  fi

  [[ -f "$INPUT_ADDED_JSON" ]] || { echo "[BRANCH iii] Missing $INPUT_ADDED_JSON"; return 1; }

  if [[ "$RUN_CHAT2UNITTEST" != "1" ]]; then
    echo "[BRANCH iii] RUN_CHAT2UNITTEST=0 -> skip regeneration."
    return 0
  fi

  # ---- iterate each entry (file) in input_added.json ----
  mapfile -t prod_files < <(jq -r 'keys[]' "$INPUT_ADDED_JSON" | sed 's/\r$//')
  if [[ "${#prod_files[@]}" -eq 0 ]]; then
    echo "[BRANCH iii] input_added.json has no entries. Skip."
    return 0
  fi

  echo "[BRANCH iii] Entries to process: ${#prod_files[@]}"

  for prod_fp in "${prod_files[@]}"; do
    prod_fp="$(sanitize_line "$prod_fp")"
    sep
    echo "[BRANCH iii] Processing entry: $prod_fp"

    mapfile -t methods_for_file < <(jq -r --arg fp "$prod_fp" '.[$fp] // [] | .[]' "$INPUT_ADDED_JSON" | sed 's/\r$//')
    if [[ "${#methods_for_file[@]}" -eq 0 ]]; then
      echo "[BRANCH iii] No methods for $prod_fp -> skip entry."
      continue
    fi

    # class fqn (prod)
    local class_fqn
    class_fqn="$(derive_prod_fqn_from_path "$prod_fp")" || {
      echo "[BRANCH iii] ERROR: cannot derive class FQN from path: $prod_fp"
      return 1
    }

    local expected_test_class
    expected_test_class="${class_fqn}Test"

    # Single-entry JSON for this file (ONLY added methods, no expansion)
    local single_json
    single_json="$(mktemp)"
    jq -n --arg fp "$prod_fp" --slurpfile all "$INPUT_ADDED_JSON" \
      '{($fp): ($all[0][$fp] // [])}' > "$single_json"

    echo "[BRANCH iii] Single-entry JSON:"
    cat "$single_json"

    # Test class file
    local test_classes_file
    test_classes_file="$(mktemp)"
    : > "$test_classes_file"
    echo "$expected_test_class" > "$test_classes_file"

    # REQUIRED_TESTS_FILE (ADDED): costruiamo la lista dei base test richiesti
    # formato: <TestClassFQN>.test<CapMethod>
    local tmp_required
    tmp_required="$(mktemp)"
    : > "$tmp_required"

    for m in "${methods_for_file[@]}"; do
      m="$(sanitize_line "$m")"
      [[ -z "$m" ]] && continue
      cap="$(capitalize_first "$m")"
      echo "${expected_test_class}.test${cap}" >> "$tmp_required"
    done
    sort -u "$tmp_required" -o "$tmp_required"

    echo "[BRANCH iii] REQUIRED tests (base):"
    cat "$tmp_required"

    # Backup pristine/baseline come nel modified (safe)
    while IFS= read -r cls; do
      cls="$(sanitize_line "$cls")"
      [[ -z "$cls" ]] && continue

      tf="$(fqn_to_test_path "$cls")"
      bak="${tf}.pristine"

      if [[ -f "$tf" && ! -f "$bak" ]]; then
        cp -f "$tf" "$bak"
        echo "[BRANCH iii] Saved pristine backup: $bak"
      fi
    done < "$test_classes_file"

    local attempt=1
    while [[ "$attempt" -le "$MAX_CHAT2UNITTEST_ATTEMPTS" ]]; do
      sep
      echo "[BRANCH iii] Entry attempt $attempt/$MAX_CHAT2UNITTEST_ATTEMPTS for $class_fqn"

      # Restore baseline/pristine
      while IFS= read -r cls; do
        cls="$(sanitize_line "$cls")"
        [[ -z "$cls" ]] && continue

        tf="$(fqn_to_test_path "$cls")"
        bak_base="${tf}.baseline"
        bak_pristine="${tf}.pristine"

        if [[ -f "$bak_base" ]]; then
          cp -f "$bak_base" "$tf"
          echo "[BRANCH iii] Restored baseline into target: $tf"
        elif [[ -f "$bak_pristine" ]]; then
          cp -f "$bak_pristine" "$tf"
          echo "[BRANCH iii] Restored pristine backup into target: $tf"
        fi

        ensure_import "$tf" "listener.BaseCoverageTest"
        ensure_test_extends_base "$tf" "BaseCoverageTest"
      done < "$test_classes_file"

      # Run Chat2UnitTest for this entry
      echo "[BRANCH iii] Running Chat2UnitTest (single entry)..."
      java -jar "$CHAT2UNITTEST_JAR" "$single_json" \
        -host "$CHAT2UNITTEST_HOST" \
        -mdl "$CHAT2UNITTEST_MODEL" \
        -tmp "$CHAT2UNITTEST_TEMP"

      # Merge generated -> target
      export REQUIRED_TESTS_FILE="$tmp_required"
      local merge_failed=0

      while IFS= read -r cls; do
        cls="$(sanitize_line "$cls")"
        [[ -z "$cls" ]] && continue

        tf="$(fqn_to_test_path "$cls")"

        if ! merge_generated_tests "$tf"; then
          echo "[BRANCH iii] Merge failed for $tf"
          merge_failed=1
        else
          rm -f "${tf%.java}.generated.java" 2>/dev/null || true
        fi

        ensure_import "$tf" "listener.BaseCoverageTest"
        ensure_test_extends_base "$tf" "BaseCoverageTest"
      done < "$test_classes_file"

      if [[ "$merge_failed" -eq 1 ]]; then
        echo "[BRANCH iii] Merge failed -> retry."
        attempt=$((attempt+1))
        continue
      fi

      # Targeted gradle run: serve SOLO ad aggiornare coverage-matrix.json
      echo "[BRANCH iii] Validating + updating coverage via Gradle (only $expected_test_class)..."
      mapfile -t gradle_args < <(build_gradle_tests_args "$test_classes_file")

      set +e
      ./gradlew :app:test --rerun-tasks "${gradle_args[@]}"
      gradle_rc=$?
      set -e

      if [[ $gradle_rc -eq 0 ]]; then
        echo "[BRANCH iii] Gradle OK (coverage updated)."

        # aggiorna baseline dopo successo
        while IFS= read -r cls; do
          cls="$(sanitize_line "$cls")"
          [[ -z "$cls" ]] && continue
          tf="$(fqn_to_test_path "$cls")"
          bak="${tf}.baseline"
          ensure_import "$tf" "listener.BaseCoverageTest"
          ensure_test_extends_base "$tf" "BaseCoverageTest"
          cp -f "$tf" "$bak"
          echo "[BRANCH iii] Updated baseline after success: $bak"
        done < "$test_classes_file"

        # (optional) JMH generation per questa test class (se vuoi mantenerlo coerente col modified)
        local owner_test_class="$expected_test_class"
        if ! generate_jmh_for_testclass "$owner_test_class"; then
          echo "[BRANCH iii] JMH conversion failed for $owner_test_class -> failing pipeline."
          exit 1
        fi

        break
      else
        echo "[BRANCH iii][FATAL] Gradle FAILED for added entry $class_fqn attempt $attempt."
        attempt=$((attempt+1))
        continue
      fi
    done

    if [[ "$attempt" -gt "$MAX_CHAT2UNITTEST_ATTEMPTS" ]]; then
      echo "[BRANCH iii] FAILED entry $class_fqn after $MAX_CHAT2UNITTEST_ATTEMPTS attempts."
      exit 1
    fi

    rm -f "$single_json" "$test_classes_file" "$tmp_required" 2>/dev/null || true
  done

  echo "[BRANCH iii] All entries succeeded."
  return 0
}
# ===================== MAIN ===================================================
extract_modified_classes
run_ast
build_inputs

# 3-way branches (final structure)
branch_deleted
#branch_modified
#branch_added

sep
echo "PIPELINE STRUCTURE COMPLETED."
