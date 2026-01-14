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
          if($0 ~ /^[[:space:]]*(public|protected|private)[[:space:]]+[A-Za-z0-9_<>\[\]]+[[:space:]]+[A-Za-z0-9_]+[[:space:]]*;/){
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
      my @blocks = split(/\n\s*\/\*__TEST_BLOCK__\*\/\s*\n/, $_);
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
      my @blocks = split(/\n\s*\/\*__TEST_BLOCK__\*\/\s*\n/, $_);
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
perl -0777 -i -pe '
  my @blocks = split(/\n\s*\/\*__TEST_BLOCK__\*\/\s*\n/, $_);

  for my $b (@blocks) {
    my $seen = 0;
    # rimuove eventuali @Test extra (lascia solo il primo)
    $b =~ s/^[ \t]*@(?:[A-Za-z0-9_.]*\.)?Test\b.*\n/
      $seen++ ? "" : $&/egm;
  }

  $_ = join("\n/*__TEST_BLOCK__*/\n", @blocks) . "\n";
' "$tmp_methods"

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
      if($0 ~ /^[[:space:]]*(public|protected|private)[[:space:]]+[^;=]+[[:space:]]+[A-Za-z0-9_]+[[:space:]]*(=[^;]*)?;/){
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
    awk -v pref="${cls_fqn}." 'index($0,pref)==1 {print substr($0, length(pref)+1)}' \
      "$REQUIRED_TESTS_FILE" | sed 's/\r$//' | sort -u > "$req_bases"


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
perl -ne 'print "$.:\t$1\n" if(/public\s+void\s+([A-Za-z0-9_]+)\s*\(/);' "$tmp_methods" || true
echo "===================================================="

    # --- FIX: SAFE RENAME to required bases ONLY when we can MATCH by prod call ---
    # req_bases: testGetName -> prod getName ; testSetSurname -> prod setSurname ; ...
    REQBASES="$req_bases" perl -0777 -i -pe '
      my $reqfile = $ENV{REQBASES};
      open my $fh, "<", $reqfile or die "cannot open REQBASES: $!";
      my @req = ();
     while (my $line = <$fh>) {
         $line =~ s/\r?\n$//;
         next if $line eq "";
         push @req, $line;
       }
      close $fh;

      # build map: required base -> prod method (testXxx -> xxx with lcfirst)
      my %prod_of;
      for my $b (@req){
        my $p = $b;

        if($p =~ /^test/){
          $p =~ s/^test//;
          $p = lcfirst($p);
        } else {
          $p =~ s/_.*$//;
        }

        $prod_of{$b} = $p;
      }

      my @blocks = split(/\n\s*\/\*__TEST_BLOCK__\*\/\s*\n/, $_);
      my %k; # counters per base (required or fallback base)

      for my $blk (@blocks){
        next if $blk !~ /void\s+([A-Za-z0-9_]+)\s*\(/;
        my $old = $1;

        # choose target base:
        # 1) if block calls .<prod>( for some required base, map to that required base
        my $target = "";
        for my $b (@req){
          my $p = $prod_of{$b};
          if($blk =~ /\.\Q$p\E\s*\(/){
            $target = $b;
            last;
          }
        }

        # 2) else fallback to its own base (strip _caseN if any)
        if($target eq ""){
          ($target = $old) =~ s/_case\d+$//;
        }

        my $n = ++$k{$target};
        my $new = $target . "_case" . $n;

        # replace ONLY the method name in signature
        $blk =~ s/\bvoid\s+\Q$old\E\s*\(/"void $new("/e;
      }

      $_ = join("\n/*__TEST_BLOCK__*/\n", @blocks) . "\n";
    ' "$tmp_methods"

    # Build regen_bases from tmp_methods (base = name without _caseN)
    regen_bases="$(mktemp)"
    grep -oE "void[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\(" "$tmp_methods" \
      | sed -E 's/.*void[[:space:]]+([A-Za-z0-9_]+)[[:space:]]*\(.*/\1/' \
      | sed -E 's/_case[0-9]+$//' \
      | sort -u > "$regen_bases"

    echo "[MERGE][DEBUG] regen_bases content:"
    cat "$regen_bases" || true

    echo "================ DEBUG RENAME END =================="
    echo "[DBG] tmp_methods size AFTER rename: $(wc -c < "$tmp_methods") bytes"
    echo "[DBG] Methods AFTER rename:"
    perl -ne 'print "$.:\t$1\n" if(/public\s+void\s+([A-Za-z0-9_]+)\s*\(/);' "$tmp_methods" || true
    echo "===================================================="

        # --- CANONICAL RENUMBER (stable): per ogni base, garantisci case1..caseN in ordine ---
        perl -i -pe '
          BEGIN { our %k; }
          if (/^\s*public\s+void\s+([A-Za-z0-9_]+)\s*\(/) {
            my $old = $1;
            (my $b = $old) =~ s/_case\d+$//;
            my $n = ++$k{$b};
            my $new = $b . "_case" . $n;
            s/\b\Q$old\E\b/$new/;
          }
        ' "$tmp_methods"
        # --- END CANONICAL RENUMBER ---


    # ricostruisci tmp_names coerente con i nuovi nomi
    perl -0777 -ne '
      while(/(?:public|protected|private)?\s*(?:static\s+)?void\s+([A-Za-z0-9_]+)\s*\(/g){
        print "$1\n";
      }
    ' "$tmp_methods" | sed 's/\r$//' | sort -u > "$tmp_names"
    # --- END FIX ---

    # =========================
    # regen_bases: basi davvero generate (da tmp_names)
    # es: testGetName_case1 -> testGetName
    # =========================
    local regen_bases
    regen_bases="$(mktemp)"
    sed -E 's/_case[0-9]+$//' "$tmp_names" | sed 's/\r$//' | sort -u > "$regen_bases"

    echo "[MERGE][DEBUG] regen_bases (derived from generated tests):"
    cat "$regen_bases" || true

    echo "[MERGE][DEBUG] methods AFTER CANONICAL RENUMBER:"
    perl -ne 'print "$.:\t$1\n" if(/public\s+void\s+([A-Za-z0-9_]+)\s*\(/);' "$tmp_methods" | head -n 80 || true

     echo "[MERGE][DEBUG] methods AFTER rename:"
     perl -ne 'print "$.:\t$1\n" if(/public\s+void\s+([A-Za-z0-9_]+)\s*\(/);' "$tmp_methods" | head -n 60 || true

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

    # =========================
    # PRUNE per prefisso: rimuove dal target tutti i metodi che matchano ^base($|_)
    # per ogni base in req_bases
    # =========================
    local tmp_pruned_prefix
    tmp_pruned_prefix="$(mktemp)"

    awk -v bases_file="$regen_bases" '
          BEGIN{
            while((getline b < bases_file)>0){
              gsub(/\r/,"",b);
              if(b!="") bases[b]=1;
            }
            close(bases_file);

            inBlock=0; inSkip=0; seenSig=0; started=0; brace=0;
            buf=""; methodname="";
          }

          function extract_name(line,   t){
            if(line ~ /^[[:space:]]*(public|protected|private)?[[:space:]]*(static[[:space:]]+)?void[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\(/){
              t=line;
              sub(/.*void[[:space:]]+/,"",t);
              sub(/\(.*/,"",t);
              gsub(/[[:space:]]+/,"",t);
              return t;
            }
            return "";
          }

          function should_skip(n,   b){
            for(b in bases){
              if(n == b) return 1;
              if(index(n, b "_")==1) return 1;  # base_case..., base_Whatever...
            }
            return 0;
          }

          # start on @Test
          {
            if(inBlock==0 && $0 ~ /^[[:space:]]*@([A-Za-z0-9_.]*\.)?Test\b/){
              inBlock=1; buf=$0 "\n";
              inSkip=0; seenSig=0; started=0; brace=0; methodname="";
              next;
            }

            if(inBlock==1){
              buf = buf $0 "\n";

              if(seenSig==0){
                methodname = extract_name($0);
                if(methodname!=""){
                  seenSig=1;
                  if(should_skip(methodname)) inSkip=1;
                }
              }

              if(seenSig==1){
                if(started==0 && $0 ~ /\{/) started=1;
                if(started==1){
                  brace += gsub(/\{/,"{");
                  brace -= gsub(/\}/,"}");
                  if(brace==0){
                    # end method
                    if(inSkip==0) printf "%s", buf;
                    inBlock=0; buf=""; inSkip=0; seenSig=0; started=0; brace=0; methodname="";
                  }
                }
              }
              next;
            }

            print;
          }
        ' "$test_file" > "$tmp_pruned_prefix"

    mv "$tmp_pruned_prefix" "$test_file"

  # 4) Prune dal target i metodi @Test con lo stesso nome (no duplicati)
  local tmp_pruned
  tmp_pruned="$(mktemp)"

  awk -v names_file="$tmp_names" '
      BEGIN{
        while((getline n < names_file)>0){
          gsub(/\r/,"",n);
          if(n!="") names[n]=1;
        }
        close(names_file);

        inBlock=0; inSkip=0; seenSig=0; started=0; brace=0;
        buf=""; methodname="";
      }

      function extract_name(line,   t){
        if(line ~ /^[[:space:]]*(public|protected|private)?[[:space:]]*(static[[:space:]]+)?void[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\(/){
          t=line;
          sub(/.*void[[:space:]]+/,"",t);
          sub(/\(.*/,"",t);
          gsub(/[[:space:]]+/,"",t);
          return t;
        }
        return "";
      }

      {
        if(inBlock==0 && $0 ~ /^[[:space:]]*@([A-Za-z0-9_.]*\.)?Test\b/){
          inBlock=1; buf=$0 "\n";
          inSkip=0; seenSig=0; started=0; brace=0; methodname="";
          next;
        }

        if(inBlock==1){
          buf = buf $0 "\n";

          if(seenSig==0){
            methodname = extract_name($0);
            if(methodname!=""){
              seenSig=1;
              if(methodname in names) inSkip=1;  # elimina il metodo target
            }
          }

          if(seenSig==1){
            if(started==0 && $0 ~ /\{/) started=1;
            if(started==1){
              brace += gsub(/\{/,"{");
              brace -= gsub(/\}/,"}");
              if(brace==0){
                if(inSkip==0) printf "%s", buf;
                inBlock=0; buf=""; inSkip=0; seenSig=0; started=0; brace=0; methodname="";
              }
            }
          }
          next;
        }

        print;
      }
    ' "$test_file" > "$tmp_pruned"

  mv "$tmp_pruned" "$test_file"

  # remove block separators before insertion
  sed -i.bak '/\/\*__TEST_BLOCK__\*\//d' "$tmp_methods" || true
  rm -f "${tmp_methods}.bak" 2>/dev/null || true

  # =========================
  # STRONG PRUNE by required bases (annotation-aware)
  # Rimuove dal target TUTTI i metodi @Test il cui nome è:
  #   - base
  #   - base_caseN
  # =========================
  local tmp_pruned_bases
  tmp_pruned_bases="$(mktemp)"

  awk -v bases_file="$regen_bases" '
    BEGIN{
      while((getline b < bases_file)>0){
        gsub(/\r/,"",b);
        if(b!="") bases[b]=1;
      }
      close(bases_file);

      inBlock=0; buf=""; brace=0; started=0; name="";
    }

    function extract_name(line,   t){
      if(line ~ /^[[:space:]]*(public|protected|private)?[[:space:]]*(static[[:space:]]+)?void[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\(/){
        t=line;
        sub(/.*void[[:space:]]+/,"",t);
        sub(/\(.*/,"",t);
        gsub(/[[:space:]]+/,"",t);
        return t;
      }
      return "";
    }

    function matches_required(n,   b){
      for(b in bases){
        if(n == b) return 1;
        if(index(n, b "_case")==1) return 1;
      }
      return 0;
    }

    {
      # start block at @Test
      if(inBlock==0 && $0 ~ /^[[:space:]]*@([A-Za-z0-9_.]*\.)?Test\b/){
        inBlock=1; buf=$0 "\n"; brace=0; started=0; name="";
        next;
      }

      if(inBlock==1){
        buf = buf $0 "\n";

        if(name==""){
          n = extract_name($0);
          if(n!="") name=n;
        }

        if(started==0 && $0 ~ /\{/) started=1;
        if(started==1){
          line=$0;
          o=gsub(/\{/,"{",line);
          c=gsub(/\}/,"}",line);
          brace += o; brace -= c;

          if(brace==0){
            # end block: stampa solo se NON matcha required base/case
            if(name=="" || !matches_required(name)) printf "%s", buf;
            inBlock=0; buf=""; brace=0; started=0; name="";
          }
        }
        next;
      }

      print;
    }
  ' "$test_file" > "$tmp_pruned_bases"

  mv "$tmp_pruned_bases" "$test_file"

  # =========================
  # HARD FIX: se il file termina con "@Test" (orfano), rimuovilo dalla coda
  # =========================
  perl -0777 -i -pe '
    s/(\n[ \t]*@(?:[A-Za-z0-9_.]*\.)?Test[ \t]*\n[ \t]*\z)/\n/s;
    s/(\n[ \t]*@(?:[A-Za-z0-9_.]*\.)?Test[ \t]*\z)/\n/s;
  ' "$test_file"

  # =========================
  # PRE-INSERT CLEANUP: rimuovi @Test orfani nel TARGET
  # (es. "@Test" non seguito da una signature "void nome(")
  # Questo evita file che finiscono con "@Test" e manca la "}" di classe.
  # =========================
  local tmp_orphan
  tmp_orphan="$(mktemp)"
  awk '
    { lines[NR]=$0 }
    END {
      for (i=1; i<=NR; i++) {
        if (lines[i] ~ /^[[:space:]]*@([A-Za-z0-9_.]*\.)?Test\b[[:space:]]*$/) {
          j=i+1
          while (j<=NR && lines[j] ~ /^[[:space:]]*$/) j++
          # se dopo c è un altro @Test o EOF o non c è una signature di metodo -> scarta questo @Test
          if (j>NR) continue
          if (lines[j] ~ /^[[:space:]]*@([A-Za-z0-9_.]*\.)?Test\b/) continue
          if (lines[j] !~ /^[[:space:]]*(public|protected|private)?[[:space:]]*(static[[:space:]]+)?void[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\(/) continue
        }
        print lines[i]
      }
    }
  ' "$test_file" > "$tmp_orphan"
  mv "$tmp_orphan" "$test_file"

# Normalizza CRLF -> LF sul target per rendere affidabili awk/grep/perl
perl -pi -e 's/\r$//mg' "$test_file"

    # =========================
    # CLEANUP: rimuovi @Test orfani (es. "@Test" seguito da vuoto o da un altro @Test)
    # =========================
    local tmp_clean
    tmp_clean="$(mktemp)"
    awk '
      {
        lines[NR]=$0
      }
      END{
        for(i=1;i<=NR;i++){
          # se la riga è "@Test" e la prossima non è una signature, la scarto
          if(lines[i] ~ /^[[:space:]]*@([A-Za-z0-9_.]*\.)?Test\b[[:space:]]*\r?$/){
            j=i+1
            while(j<=NR && lines[j] ~ /^[[:space:]]*$/) j++
            if(j<=NR && lines[j] ~ /^[[:space:]]*@([A-Za-z0-9_.]*\.)?Test\b/) { continue }
            if(j<=NR && lines[j] !~ /^[[:space:]]*(public|protected|private)?[[:space:]]*(static[[:space:]]+)?void[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\(/) { continue }
          }
          print lines[i]
        }
      }
    ' "$test_file" > "$tmp_clean"
    mv "$tmp_clean" "$test_file"

      # =========================
      # FIX STRUCTURE (target): se un metodo precedente è rimasto aperto e arriva un nuovo @Test,
      # chiudi automaticamente le graffe fino a tornare al livello della classe.
      # Questo impedisce inserimenti "dentro" un metodo (come il tuo testSetCode()).
      # =========================
      local tmp_fix
      tmp_fix="$(mktemp)"

      awk '
        BEGIN{depth=0}

        function delta_braces(s,   t,o,c){
          t=s; o=gsub(/\{/,"{",t)
          t=s; c=gsub(/\}/,"}",t)
          return o-c
        }

        {
          line=$0

          # Se compare un @Test mentre siamo dentro un metodo (depth > 1),
          # chiudiamo fino a tornare al livello classe (depth==1).
          if(line ~ /^[[:space:]]*@([A-Za-z0-9_.]*\.)?Test\b/){
            while(depth > 1){
              print "    }"
              depth--
            }
          }

          print line
          depth += delta_braces(line)
        }

        END{
          # Se il file finisce ancora dentro un metodo, chiudi fino a livello classe
          while(depth > 1){
            print "    }"
            depth--
          }
        }
      ' "$test_file" > "$tmp_fix" && mv "$tmp_fix" "$test_file"

      # Normalizza CRLF -> LF sul target
      perl -pi -e 's/\r$//mg' "$test_file"

    # 5) Inserisci i nuovi metodi prima della "}" che chiude la CLASSE
        # (cioè una "}" standalone dopo la quale ci sono solo righe vuote)
        local tmp_out
        tmp_out="$(mktemp)"

        # =========================
        # PRE-INSERT STRUCTURE FIX (robusto e unico)
        # - normalizza CRLF
        # - rimuove @Test orfani in coda
        # - se compare un @Test mentre siamo dentro un metodo, chiude il metodo PRIMA dell'@Test
        # - assicura che il file termini con una "}" standalone (chiusura classe)
        # =========================
        perl -pi -e 's/\r$//mg' "$test_file"

        local tmp_fix_pre
        tmp_fix_pre="$(mktemp)"

        awk '
          BEGIN{depth=0}

          function delta_braces(s,   t,o,c){
            t=s; o=gsub(/\{/,"{",t)
            t=s; c=gsub(/\}/,"}",t)
            return o-c
          }

          {
            line=$0

            # Se arriva un @Test mentre siamo dentro un metodo (depth>1),
            # chiudi fino a tornare al livello classe (depth==1) PRIMA di stampare @Test.
            if(line ~ /^[[:space:]]*@([A-Za-z0-9_.]*\.)?Test\b/){
              while(depth > 1){
                print "    }"
                depth--
              }
            }

            print line
            depth += delta_braces(line)
          }

          END{
            # chiudi eventuali metodi lasciati aperti
            while(depth > 1){
              print "    }"
              depth--
            }
          }
        ' "$test_file" > "$tmp_fix_pre" && mv "$tmp_fix_pre" "$test_file"

        # Rimuovi eventuali @Test orfani in fondo (solo in coda file)
        perl -0777 -i -pe '
          1 while s/\n[ \t]*@(?:[A-Za-z0-9_.]*\.)?Test[ \t]*\n[ \t]*\z/\n/s;
          1 while s/\n[ \t]*@(?:[A-Za-z0-9_.]*\.)?Test[ \t]*\z/\n/s;
        ' "$test_file"

        # Assicura che l\'ultima riga non-vuota sia "}"
        last_nonempty="$(grep -nve "^[[:space:]]*$" "$test_file" | tail -n 1 | cut -d: -f2-)"
        if ! echo "$last_nonempty" | grep -qE "^[[:space:]]*}[[:space:]]*$"; then
          echo "}" >> "$test_file"
        fi

        # GUARD: l'ultima riga non-vuota DEVE essere una "}" standalone (chiusura classe)
        last_nonempty="$(grep -nve '^[[:space:]]*$' "$test_file" | tail -n 1 | cut -d: -f2-)"
        if ! echo "$last_nonempty" | grep -qE '^[[:space:]]*}[[:space:]]*$'; then
          echo "[MERGE][FATAL] Target test file does NOT end with a standalone '}' (class close). Refusing to insert."
          echo "[MERGE][FATAL] Last non-empty line: $last_nonempty"
          exit 1
        fi

        # =========================
        # PRUNE TARGET by regen_bases (generic):
        # remove any @Test method whose name starts with one of the bases we are about to insert
        # (base, base_caseN, base_anything)
        # =========================
        tmp_pruned_regen="$(mktemp)"
        awk -v bases_file="$regen_bases" '
          BEGIN{
            while((getline b < bases_file)>0){
              gsub(/\r/,"",b);
              if(b!="") bases[b]=1;
            }
            close(bases_file);

            inBlock=0; buf=""; brace=0; started=0; name="";
          }

          function extract_name(line,   t){
            if(line ~ /^[[:space:]]*(public|protected|private)?[[:space:]]*(static[[:space:]]+)?void[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\(/){
              t=line; sub(/.*void[[:space:]]+/,"",t); sub(/\(.*/,"",t); gsub(/[[:space:]]+/,"",t); return t;
            }
            return "";
          }

          function should_drop(n,   b){
            for(b in bases){
              if(n == b) return 1;
              if(index(n, b "_case")==1) return 1;
              if(index(n, b "_")==1) return 1;  # <-- questa è la chiave per i tuoi suff/insuff ecc
            }
            return 0;
          }

          {
            if(inBlock==0 && $0 ~ /^[[:space:]]*@([A-Za-z0-9_.]*\.)?Test\b/){
              inBlock=1; buf=$0 "\n"; brace=0; started=0; name="";
              next;
            }

            if(inBlock==1){
              buf = buf $0 "\n";

              if(name==""){
                n = extract_name($0);
                if(n!="") name=n;
              }

              if(started==0 && $0 ~ /\{/) started=1;
              if(started==1){
                line=$0;
                o=gsub(/\{/,"{",line); c=gsub(/\}/,"}",line);
                brace += o; brace -= c;

                if(brace==0){
                  if(name=="" || !should_drop(name)) printf "%s", buf;
                  inBlock=0; buf=""; brace=0; started=0; name="";
                }
              }
              next;
            }

            print;
          }
        ' "$test_file" > "$tmp_pruned_regen" && mv "$tmp_pruned_regen" "$test_file"

        awk -v addfile="$tmp_methods" '
          function count_braces(s,   t,o,c){
            t=s; o=gsub(/\{/,"{",t)
            t=s; c=gsub(/\}/,"}",t)
            return o-c
          }

          BEGIN{
            depth=0
            class_started=0
            insert_line=-1
          }

          { lines[NR]=$0 }

          END{
            # trova la chiusura della classe via depth:
            # entra quando vede la prima "{", poi quando depth torna a 0 è la "}" della classe
            for(i=1;i<=NR;i++){
              d = count_braces(lines[i])

              if(class_started==0){
                if(d>0) class_started=1
              }

              if(class_started==1){
                depth += d
                if(depth==0){
                  insert_line=i
                  break
                }
              }
            }

            if(insert_line==-1){
              print "[MERGE][FATAL] Could not find class-closing brace by depth." > "/dev/stderr"
              exit 2
            }

            for(i=1;i<insert_line;i++) print lines[i]
            print ""
            while((getline l < addfile)>0) print l
            close(addfile)
            print ""
            for(i=insert_line;i<=NR;i++) print lines[i]
          }
        ' "$test_file" > "$tmp_out" && mv "$tmp_out" "$test_file"

      # cleanup in coda
      perl -0777 -i -pe '
        1 while s/\n[ \t]*@(?:[A-Za-z0-9_.]*\.)?Test[ \t]*\n[ \t]*\z/\n/s;
        1 while s/\n[ \t]*@(?:[A-Za-z0-9_.]*\.)?Test[ \t]*\z/\n/s;
      ' "$test_file"

        # GUARD immediato (corretto): verifica solo le basi DAVVERO generate
        gen_bases="$(mktemp)"

        # ricava le basi dal tmp_names (testX_caseN -> testX)
        sed -E 's/_case[0-9]+$//' "$tmp_names" | sed 's/\r$//' | sort -u > "$gen_bases"

        missing=0
        while IFS= read -r base; do
          base="$(sanitize_line "$base")"
          [[ -z "$base" ]] && continue

          if ! grep -qE "public[[:space:]]+void[[:space:]]+${base}_case1[[:space:]]*\\(" "$test_file"; then
            echo "[MERGE][FATAL] Insert failed: ${base}_case1 not present RIGHT AFTER insertion."
            missing=1
          fi
        done < "$gen_bases"

        rm -f "$gen_bases"

        if [[ "$missing" == "1" ]]; then
          echo "[MERGE][FATAL] Tail of file for debug:"
          tail -n 200 "$test_file"
          exit 1
        fi

    # =========================
    # FIX STRUCTURE (POST-INSERT): se qualche metodo precedente è rimasto aperto,
    # chiudi le graffe prima che gli @Test inseriti risultino "dentro" un altro metodo.
    # =========================
    tmp_fix="$(mktemp)"
    awk '
      BEGIN{depth=0}

      function delta_braces(s,   t,o,c){
        t=s; o=gsub(/\{/,"{",t)
        t=s; c=gsub(/\}/,"}",t)
        return o-c
      }

      {
        line=$0

        # Se compare un @Test mentre siamo dentro un metodo (depth > 1),
        # chiudiamo fino a tornare al livello classe (depth==1).
        if(line ~ /^[[:space:]]*@([A-Za-z0-9_.]*\.)?Test\b/){
          while(depth > 1){
            print "    }"
            depth--
          }
        }

        print line
        depth += delta_braces(line)
      }

      END{
        # Se il file finisce ancora dentro un metodo, chiudi fino a livello classe
        while(depth > 1){
          print "    }"
          depth--
        }
      }
    ' "$test_file" > "$tmp_fix" && mv "$tmp_fix" "$test_file"

    # Normalizza CRLF -> LF (again)
    perl -pi -e 's/\r$//mg' "$test_file"

    # =========================
    # HARD PRUNE BASE BY SIGNATURE (robusto):
    # se esiste base_caseN, elimina SEMPRE il metodo base "base" (anche senza @Test)
    # =========================
    while IFS= read -r base; do
      base="$(sanitize_line "$base")"
      [[ -z "$base" ]] && continue

      if grep -qE "\b${base}_case[0-9]+\s*\(" "$test_file"; then
        tmp_drop="$(mktemp)"
        awk -v target="$base" '
          BEGIN{drop=0; brace=0; started=0}
          function is_sig(line){
            return (line ~ "^[[:space:]]*(public|protected|private)?[[:space:]]*(static[[:space:]]+)?void[[:space:]]+" target "[[:space:]]*\\(")
          }
          {
            if(drop==0 && is_sig($0)){
              drop=1; brace=0; started=0;
              next
            }
            if(drop==1){
              if(started==0 && $0 ~ /\{/) started=1
              if(started==1){
                line=$0
                o=gsub(/\{/,"{",line); c=gsub(/\}/,"}",line)
                brace += o; brace -= c
                if(brace==0){ drop=0; started=0 }
              }
              next
            }
            print
          }
        ' "$test_file" > "$tmp_drop" && mv "$tmp_drop" "$test_file"
      fi
    done < "$regen_bases"

    echo "[MERGE][DEBUG] check that testSetCode is closed before next @Test:"
    grep -nE "public[[:space:]]+void[[:space:]]+testSetCode|^[[:space:]]*}[[:space:]]*$|^[[:space:]]*@Test\b" "$test_file" | sed -n '1,120p'

    # =========================
    # FINAL CLEANUP: collassa @Test duplicati consecutivi (anche con righe vuote in mezzo)
    # =========================
    perl -0777 -i -pe '
      1 while s/(\n[ \t]*@(?:[A-Za-z0-9_.]*\.)?Test[ \t]*\n)(\s*\n[ \t]*@(?:[A-Za-z0-9_.]*\.)?Test[ \t]*\n)/$1/gm;
    ' "$test_file"

    echo "[MERGE][DEBUG] after insertion, checking for case1:"
    grep -nE "public[[:space:]]+void[[:space:]]+test[A-Za-z0-9_]+_case[0-9]+[[:space:]]*\(" "$test_file" | head -n 50 || true

    # =========================
    # HARD PRUNE (annotation-aware):
    # se esistono ${base}_caseN, elimina il metodo base ${base}
    # rimuovendo anche la @Test immediatamente sopra (se presente)
    # =========================
    while IFS= read -r base; do
      base="$(sanitize_line "$base")"
      [[ -z "$base" ]] && continue

      # se ho almeno un case, elimino il base
      if grep -qE "^[[:space:]]*(public|protected|private)?[[:space:]]*(static[[:space:]]+)?void[[:space:]]+[[:space:]]+${base}_case[0-9]+[[:space:]]*\(" "$test_file"; then
        local tmp_hard
        tmp_hard="$(mktemp)"
        awk -v target="$base" '
          BEGIN{
            inBlock=0; skipping=0; brace=0; started=0; name=""; buf="";
          }
          function extract_name(line,   t){
            if(line ~ /^[[:space:]]*(public|protected|private)?[[:space:]]*(static[[:space:]]+)?void[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\(/){
              t=line; sub(/.*void[[:space:]]+/,"",t); sub(/\(.*/,"",t); gsub(/[[:space:]]+/,"",t); return t;
            }
            return "";
          }
          {
            # start block at @Test
            if(inBlock==0 && $0 ~ /^[[:space:]]*@([A-Za-z0-9_.]*\.)?Test\b/){
              inBlock=1; buf=$0 "\n"; name=""; brace=0; started=0;
              next;
            }

            if(inBlock==1){
              buf = buf $0 "\n";

              if(name==""){
                n = extract_name($0);
                if(n!="") name=n;
              }

              if(started==0 && $0 ~ /\{/) started=1;
              if(started==1){
                line=$0;
                o=gsub(/\{/,"{",line);
                c=gsub(/\}/,"}",line);
                brace += o; brace -= c;

                if(brace==0){
                  # end of method block
                  if(name != target) printf "%s", buf;  # keep only if not the base
                  inBlock=0; buf=""; name=""; brace=0; started=0;
                }
              }
              next;
            }

            print;
          }
        ' "$test_file" > "$tmp_hard"
        mv "$tmp_hard" "$test_file"
      fi
    done < "$regen_bases"

  # =========================
  # FORCE-REMOVE required base tests from target
  # (generic: if we are regenerating testX, the old testX must go)
  # =========================
  while IFS= read -r base; do
    base="$(sanitize_line "$base")"
    [[ -z "$base" ]] && continue

    tmp_rm_base="$(mktemp)"
    awk -v target="$base" '
      BEGIN{inBlock=0; buf=""; brace=0; started=0; name=""}

      function extract_name(line,   t){
        if(line ~ /^[[:space:]]*(public|protected|private)?[[:space:]]*(static[[:space:]]+)?void[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\(/){
          t=line; sub(/.*void[[:space:]]+/,"",t); sub(/\(.*/,"",t); gsub(/[[:space:]]+/,"",t); return t;
        }
        return "";
      }

      {
        if(inBlock==0 && $0 ~ /^[[:space:]]*@([A-Za-z0-9_.]*\.)?Test\b/){
          inBlock=1; buf=$0 "\n"; brace=0; started=0; name="";
          next;
        }

        if(inBlock==1){
          buf = buf $0 "\n";

          if(name==""){
            n = extract_name($0);
            if(n!="") name=n;
          }

          if(started==0 && $0 ~ /\{/) started=1;
          if(started==1){
            line=$0;
            o=gsub(/\{/,"{",line);
            c=gsub(/\}/,"}",line);
            brace += o; brace -= c;

            if(brace==0){
              # end of method block
              if (name != target) printf "%s", buf
              inBlock=0; buf=""; name=""; brace=0; started=0;
            }
          }
          next;
        }

        print;
      }
    ' "$test_file" > "$tmp_rm_base" && mv "$tmp_rm_base" "$test_file"
  done < "$regen_bases"

  # =========================
  # FINAL DEDUP (annotation-aware): deduplica blocchi @Test per nome metodo
  # =========================
  tmp_dedup="$(mktemp)"
  awk '
    BEGIN{inBlock=0; buf=""; brace=0; started=0; name=""; }
    function extract_name(line,   t){
      if(line ~ /^[[:space:]]*(public|protected|private)?[[:space:]]*(static[[:space:]]+)?void[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\(/){
        t=line; sub(/.*void[[:space:]]+/,"",t); sub(/\(.*/,"",t); gsub(/[[:space:]]+/,"",t); return t
      }
      return ""
    }
    {
      if(inBlock==0 && $0 ~ /^[[:space:]]*@([A-Za-z0-9_.]*\.)?Test\b/){
        inBlock=1; buf=$0 "\n"; brace=0; started=0; name=""
        next
      }
      if(inBlock==1){
        buf = buf $0 "\n"
        if(name=="" ){ n=extract_name($0); if(n!="") name=n }
        if(started==0 && $0 ~ /\{/) started=1
        if(started==1){
          brace += gsub(/\{/,"{"); brace -= gsub(/\}/,"}")
          if(brace==0){
            if(name=="" || seen[name]++==0) printf "%s", buf
            inBlock=0; buf=""; brace=0; started=0; name=""
          }
        }
        next
      }
      print
    }
  ' "$test_file" > "$tmp_dedup"
  mv "$tmp_dedup" "$test_file"


  # =========================
  # FORCE REMOVE base test methods when cases exist
  # - se esistono base_caseN, rimuovi SEMPRE il metodo base "base"
  #   (anche se la precedente hard prune non ha matchato)
  # =========================
  while IFS= read -r base; do
    base="$(sanitize_line "$base")"
    [[ -z "$base" ]] && continue

    # se esiste almeno un case, elimina il metodo base
    if grep -qE "void[[:space:]]+${base}_case[0-9]+[[:space:]]*\(" "$test_file"; then
      tmp_force="$(mktemp)"
      awk -v target="$base" '
        BEGIN{inBlock=0; brace=0; started=0; name=""; buf=""; prevTest="";}

        function is_sig(line){
          return (line ~ /^[[:space:]]*(public|protected|private)?[[:space:]]*(static[[:space:]]+)?void[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\(/)
        }
        function extract_name(line,   t){
          t=line; sub(/.*void[[:space:]]+/,"",t); sub(/\(.*/,"",t); gsub(/[[:space:]]+/,"",t); return t
        }
        function brace_delta(s,   t,o,c){
          t=s; o=gsub(/\{/,"{",t)
          t=s; c=gsub(/\}/,"}",t)
          return o-c
        }

        {
          # cattura @Test ma NON stamparlo subito
          if(inBlock==0 && $0 ~ /^[[:space:]]*@([A-Za-z0-9_.]*\.)?Test([[:space:]]|\(|$)/){
            prevTest=$0
            next
          }

          # inizia un blocco SOLO se avevo @Test sopra
          if(inBlock==0 && prevTest!="" && is_sig($0)){
            name = extract_name($0)
            inBlock=1; buf=""
            buf = prevTest "\n"; prevTest=""
            buf = buf $0 "\n"

            brace=0; started=0
            # conta anche la riga signature (può contenere "{")
            d = brace_delta($0)
            if(d != 0){
              started=1
              brace += d
            }
            next
          }

          if(inBlock==1){
            buf = buf $0 "\n"
            if(started==0 && $0 ~ /\{/) started=1
            if(started==1){
              brace += brace_delta($0)
              if(brace==0){
                # fine metodo: stampa solo se NON è il target
                if(name != target) printf "%s", buf
                inBlock=0; buf=""; name=""; brace=0; started=0
              }
            }
            next
          }

          # se @Test non è seguito da una signature, ristampalo
          if(prevTest!=""){
            print prevTest
            prevTest=""
          }
          print
        }

        END{
          if(prevTest!="") print prevTest
        }
      ' "$test_file" > "$tmp_force" && mv "$tmp_force" "$test_file"
    fi
  done < "$regen_bases"

  rm -f "$tmp_methods" "$tmp_names"
  rm -f "$tmp_fields" "$tmp_before"
  #rm -f "$gen_file"

    # ===== Ensure static org.junit.Assert.* if any assert* is used =====
    if grep -qE '\bassert(A|T|F|N|E)[A-Za-z0-9_]*\s*\(' "$test_file"; then
      ensure_static_import "$test_file" "org.junit.Assert.*"
    fi

# =========================
# FINAL CANONICAL RENUMBER ON TARGET
# =========================
while IFS= read -r base; do
  base="$(sanitize_line "$base")"
  [[ -z "$base" ]] && continue

  BASE="$base" perl -0777 -i -pe '
    my $base = $ENV{BASE};
    my $k = 0;
    s/\bvoid\s+\Q$base\E_case\d+\s*\(/"void ".$base."_case".(++$k)."("/ge;
  ' "$test_file"
done < "$regen_bases"

echo "[MERGE][DEBUG] TARGET methods AFTER FINAL RENUMBER (first 50 case methods):"
grep -nE "public[[:space:]]+void[[:space:]]+test[A-Za-z0-9_]+_case[0-9]+[[:space:]]*\(" "$test_file" | head -n 50 || true

# salva per debug e poi elimina generated (per evitare compile doppio)
  rm -f "$req_bases"
  rm -f "$regen_bases" 2>/dev/null || true
  cp -f "$gen_file" "${gen_file}.last" 2>/dev/null || true
  rm -f "$gen_file" 2>/dev/null || true
  rm -f "$gen_norm" 2>/dev/null || true

# =========================
# FINAL ORPHAN @Test CLEANUP (ULTIMO PARACADUTE)
# Rimuove qualunque @Test non seguito da una signature valida
# =========================
tmp_orphan_final="$(mktemp)"
awk '
  { lines[NR]=$0 }
  END{
    for(i=1;i<=NR;i++){
      if(lines[i] ~ /^[[:space:]]*@([A-Za-z0-9_.]*\.)?Test\b[[:space:]]*$/){
        j=i+1
        while(j<=NR && lines[j] ~ /^[[:space:]]*$/) j++
        # se EOF, altro @Test o NON una signature -> elimina
        if(j>NR) continue
        if(lines[j] ~ /^[[:space:]]*@([A-Za-z0-9_.]*\.)?Test\b/) continue
        if(lines[j] !~ /^[[:space:]]*(public|protected|private)?[[:space:]]*(static[[:space:]]+)?void[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\(/) continue
      }
      print lines[i]
    }
  }
' "$test_file" > "$tmp_orphan_final" && mv "$tmp_orphan_final" "$test_file"

# =========================
# FINAL TRIM: keep only up to the class-closing brace (depth-based)
# Drops any trailing garbage (extra '}', orphan '@Test', etc.)
# =========================
tmp_trim_class="$(mktemp)"
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
        # consider class started once we see the first "{"
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
      # if we cannot find a class close, print as-is (better than empty)
      for(i=1;i<=NR;i++) print lines[i]
      exit
    }

    for(i=1;i<=cut;i++) print lines[i]
  }
' "$test_file" > "$tmp_trim_class" && mv "$tmp_trim_class" "$test_file"

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
              bak="${tf}.pristine"

              if [[ -f "$bak" ]]; then
                cp -f "$bak" "$tf"
                echo "[BRANCH i] Restored pristine backup into target: $tf"
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
      regen_bases="$(mktemp)"

      # prende "base" da: public void <base>_case1(
      grep -oE "public[[:space:]]+void[[:space:]]+[A-Za-z0-9_]+_case1[[:space:]]*\\(" "$tf" \
        | sed -E 's/.*void[[:space:]]+([A-Za-z0-9_]+)_case1.*/\1/' \
        | sort -u > "$regen_bases"

      if [[ ! -s "$regen_bases" ]]; then
        echo "[BRANCH i] No '*_case1' methods found after merge in: $tf"
        bad=1
      else
        # opzionale: controllo robusto "base_case1 o base" (di solito basta base_case1)
        while IFS= read -r base_method; do
          base_method="$(sanitize_line "$base_method")"
          [[ -z "$base_method" ]] && continue

          if ! grep -qE "public[[:space:]]+void[[:space:]]+(${base_method}_case1|${base_method})[[:space:]]*\\(" "$tf"; then
            echo "[BRANCH i] Missing regenerated test '${base_method}' (neither base nor _case1) in: $tf"
            bad=1
          fi
        done < "$regen_bases"
      fi

      rm -f "$regen_bases"

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
        # CLEANUP: remove legacy @Test blocks that call modified prod methods
        # but are NOT in req_bases nor regen_bases
        # (prevents accumulating old generated tests like testPrelievoSuccess_case1)
        # =========================

        # build whitelist = req_bases U regen_bases
        local whitelist
        whitelist="$(mktemp)"
        cat "$req_bases" "$regen_bases" 2>/dev/null | sed 's/\r$//' | sort -u > "$whitelist"

        for pm in "${methods_for_file[@]}"; do
          pm="$(sanitize_line "$pm")"
          [[ -z "$pm" ]] && continue

          tmp_cleanup="$(mktemp)"
          awk -v WL="$whitelist" -v PM="$pm" '
            BEGIN{
              while((getline x < WL)>0){ gsub(/\r/,"",x); if(x!="") ok[x]=1 }
              close(WL)
              in=0; buf=""; brace=0; started=0; name=""; keep=1; calls=0;
            }

            function is_test_anno(line){ return line ~ /^[[:space:]]*@([A-Za-z0-9_.]*\.)?Test\b/ }
            function is_sig(line){ return line ~ /^[[:space:]]*(public|protected|private)?[[:space:]]*(static[[:space:]]+)?void[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\(/ }
            function extract_name(line, t){
              t=line; sub(/.*void[[:space:]]+/,"",t); sub(/\(.*/,"",t); gsub(/[[:space:]]+/,"",t); return t
            }
            function brace_delta(s, t,o,c){
              t=s; o=gsub(/\{/,"{",t); t=s; c=gsub(/\}/,"}",t); return o-c
            }

            {
              line=$0

              if(!in && is_test_anno(line)){
                in=1; buf=line "\n"; brace=0; started=0; name=""; keep=1; calls=0;
                next
              }

              if(in){
                buf = buf line "\n"

                if(name=="" && is_sig(line)){
                  name = extract_name(line)
                }

                # detect call to modified prod method PM(
                if(line ~ ("\\b" PM "[[:space:]]*\\(")) calls=1

                d = brace_delta(line)
                if(d != 0){ started=1; brace += d }

                if(started && brace==0){
                  # decision: drop if calls PM and name NOT in whitelist
                  if(calls && !(name in ok)) keep=0
                  if(keep) printf "%s", buf
                  in=0; buf=""; brace=0; started=0; name=""; keep=1; calls=0
                }
                next
              }

              print
            }
          ' "$test_file" > "$tmp_cleanup" && mv "$tmp_cleanup" "$test_file"
        done

        rm -f "$whitelist"

      done < "$test_classes_file"

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

      if ./gradlew :app:test --rerun-tasks "${gradle_args[@]}"; then
        echo "[BRANCH i] Entry $class_fqn succeeded on attempt $attempt."

        # =========================
        # UPDATE coverage-matrix.json: aggiungi i nuovi test *_caseN ereditando la coverage del base
        # =========================
        while IFS= read -r tcls; do
          tcls="$(sanitize_line "$tcls")"
          [[ -z "$tcls" ]] && continue
          tf="$(fqn_to_test_path "$tcls")"
          [[ -f "$tf" ]] || continue

          # per ogni required base per questa classe, trova i case nel file e aggiungili in coverage
          while IFS= read -r full; do
            full="$(sanitize_line "$full")"
            [[ -z "$full" ]] && continue
            # full tipo: utente.UtenteTest.testSetName
            base_method="${full##*.}"
            base_key="$full"

            # trova case presenti nel file
            mapfile -t cases < <(grep -Eo "public[[:space:]]+void[[:space:]]+${base_method}_case[0-9]+[[:space:]]*\(" "$tf" \
              | sed -E "s/.*void[[:space:]]+(${base_method}_case[0-9]+).*/\1/" | sort -u)

            [[ "${#cases[@]}" -eq 0 ]] && continue

            # coverage array del base (JSON)
            base_arr="$(jq -c --arg k "$base_key" '.[$k] // empty' "$COVERAGE_MATRIX_JSON")"
            [[ -z "$base_arr" ]] && continue

            # aggiungi ciascun case come nuova chiave
            for cm in "${cases[@]}"; do
              new_key="${tcls}.${cm}"
              tmp_cov="$(mktemp)"
              jq --arg nk "$new_key" --argjson arr "$base_arr" '
                . + {($nk): $arr}
              ' "$COVERAGE_MATRIX_JSON" > "$tmp_cov" && mv "$tmp_cov" "$COVERAGE_MATRIX_JSON"
            done

          done < <(awk -v pref="${cls}." 'index($0,pref)==1 {print $0}' "$tmp_tests_to_regen")

        done < "$test_classes_file"

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
          rm -f "${tf}.pristine" 2>/dev/null || true
        done < "$test_classes_file"

        break
      fi

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
