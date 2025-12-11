: <<'COMMENT'
#!/bin/bash
# Configure git
git config --global user.email "atrovato@unisa.it"
git config --global user.name "AntonioTrovato"

#TODO: IL CONFRONTO TRA I BODY DEI METODI DEVE ESSERE PIU' "FUNZIONALE"??

# File paths
MODIFIED_METHODS_FILE="modified_methods.txt"
COVERAGE_MATRIX_FILE="app/coverage-matrix.json"
OUTPUT_FILE="ju2jmh/benchmark_classes_to_generate.txt"

# Read the hashes of the last two commits using git log
current_commit=$(git log --format="%H" -n 1)
previous_commit=$(git log --format="%H" -n 2 | tail -n 1)

# Make diff between the two commits
git_diff=$(git diff -U0 --minimal $previous_commit $current_commit)

echo "GIT DIFF:"

echo "$git_diff"

echo "=================================================================================="

# Initialize empty arrays to store deleted and added methods
modified_classes=()

# Read the diff string line by line
while IFS= read -r line; do
  # Check if the line starts with "diff --git"
  if [[ $line =~ ^\+++\ .*\/main\/java\/(.*\/)?([^\/]+)\.java$ ]]; then
    packages="${BASH_REMATCH[1]}"
    file_name="${BASH_REMATCH[2]}"

    if [[ -n "$packages" ]]; then
      packages="${packages%/}"
      packages="${packages}."  # add . if packages is not empty to obtain a correct path
    fi

    # Replace slashes with dots and remove .java extension
    class_name="${packages//\//.}${file_name%.java}"

    modified_classes+=("$class_name")
  fi
done <<< "$git_diff"

# Print each element of the list
for modified_class in "${modified_classes[@]}"; do
  echo "Modified class:"
  echo "$modified_class"
done

# write in a temporary file the fully qualified names of the modified classes
temp_file="modified_classes.txt"
printf "%s\n" "${modified_classes[@]}" > "$temp_file"

# run the java script
java -jar app/build/libs/app-all.jar "$temp_file"

# delete the file
rm "$temp_file"

# read and print the contents of modified_methods.txt
while IFS= read -r line; do
    echo "$line"
done < "modified_methods.txt"

# Initialize an empty list for test methods
declare -a test_methods

# Read modified methods from the file into an array
mapfile -t modified_methods < "$MODIFIED_METHODS_FILE"

# Read the coverage-matrix.json and extract test methods
# Assuming jq is installed for JSON parsing
for method in "${modified_methods[@]}"; do
    echo "Processing method: $method"
    # Use jq to find test cases that cover the current method
    test_cases=$(jq -r --arg method "$method" '
        to_entries | map(select(.value | index($method))) | .[].key
    ' "$COVERAGE_MATRIX_FILE")

    # Append found test cases to the test_methods array
    while IFS= read -r test_case; do
        test_methods+=("$test_case")
    done <<< "$test_cases"
done

# Print the list of test methods
echo "Test methods covering modified methods:"
printf '%s\n' "${test_methods[@]}"

# Extract fully qualified class names from test methods
declare -a class_names
for test_method in "${test_methods[@]}"; do
    # Extract the class name by removing the last part after the last dot
    class_name="${test_method%.*}"
    # Check if the class name is already in the class_names array
    already_present=false
    for existing_class in "${class_names[@]}"; do
        if [[ "$existing_class" == "$class_name" ]]; then
            already_present=true
            break
        fi
    done

    # Add class name if not already present
    if ! $already_present; then
        class_names+=("$class_name")
    fi
done

# Print the list of fully qualified class names
echo "Fully qualified class names:"
printf '%s\n' "${class_names[@]}"

# Write class names to the output file, create if it doesn't exist
mkdir -p "ju2jmh"  # Create directory if it doesn't exist
mkdir -p "ju2jmh/src"
mkdir -p "ju2jmh/src/java"

{
    for class_name in "${class_names[@]}"; do
        echo "$class_name"  # Write each class name on a new line
    done
} > "$OUTPUT_FILE"

echo "Class names written to $OUTPUT_FILE"

# Make and build the benchmark classes
java -jar ./ju-to-jmh/converter-all.jar ./app/src/test/java/ ./app/build/classes/java/test/ ./ju2jmh/src/jmh/java/ --class-names-file=./ju2jmh/benchmark_classes_to_generate.txt
gradle jmhJar

# List available benchmarks
java -jar ./ju2jmh/build/libs/ju2jmh-jmh.jar -l

# Initialize an empty list for benchmark methods to run
declare -a benchmarks_to_run

for method in "${test_methods[@]}"; do
    # Extract the method name (last part after the last dot)
    method_name="${method##*.}"

    # Replace the method name with "_Benchmark._benchmark_" + method name
    benchmark="${method%.*}._Benchmark.benchmark_${method_name}"

    # Add the new benchmark name to the list
    benchmarks_to_run+=("$benchmark")
done

# Loop through benchmarks_to_run and run the java command for each
for benchmark in "${benchmarks_to_run[@]}"; do
    echo "Running benchmark: $benchmark"
    java -jar ./ju2jmh/build/libs/ju2jmh-jmh.jar "$benchmark"
done

# Add to git all the benchmark classes generated/regenerated
for class_name in "${class_names[@]}"; do
  # Convert the class name to a file path
  file_path="./ju2jmh/src/jmh/java/$(echo "$class_name" | tr '.' '/')".java

  echo "Benchmark Class to Push in the Main Branch:"
  echo "$file_path"

  # Add the file to git
  git add "$file_path"
done

git add "./ju2jmh/src/jmh/java/se/chalmers/ju2jmh/api/JU2JmhBenchmark.java"

# Commit the changes
git commit -m "Adding the Created Benchmark Classes to the Repository"

# Push the changes to the main branch using the token
git remote set-url origin https://AntonioTrovato:${ACTIONS_TOKEN}@github.com/AntonioTrovato/GradleProject.git
git push origin main

echo "DONE!"
COMMENT

#!/bin/bash
# Orchestratore in modalità STUB + DRY-RUN (nessuna modifica al repo)
set -euo pipefail

# ===== Config / Percorsi =======================================================
PROD_ROOT="app/src/main/java"
TEST_ROOT="app/src/test/java"
BENCH_ROOT="ju2jmh/src/jmh/java"
COVERAGE_MATRIX_JSON="app/coverage-matrix.json"

STUB_MODIFIED_FILE="classiModificate.txt"   # FQN modificate (stub)
STUB_DELETED_FILE="classiEliminate.txt"     # FQN eliminate (stub)

# (facoltativi per fasi reali, NON usati in dry-run)
AST_JAR="app/build/libs/app-all.jar"
JMH_JAR="ju2jmh/build/libs/ju2jmh-jmh.jar"
JU2JMH_JAR="ju-to-jmh/converter-all.jar"

# ===== Utility =================================================================
sanitize_line() {
  # rimuove CRLF e spazi iniziali/finali
  local s="$1"
  s="${s%$'\r'}"
  printf "%s" "$(echo -n "$s" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
}

fqn_to_path() {
  # $1 = FQN, $2 = root path; ritorna path.java
  local fqn="$1" root="$2"
  printf "%s/%s.java" "$root" "$(echo "$fqn" | tr '.' '/')"
}

tests_covering_prod_fqn() {
  # Ritorna test FQN che coprono:
  #   - la classe esatta ($P)
  #   - un suo metodo ($P + ".")
  #   - una sua inner class ($P + "$")
  local prod_fqn="$1"
  jq -r --arg P "$prod_fqn" '
    to_entries[]
    | select(
        ([.value[]?] | any(
          . == $P
          or startswith($P + ".")
          or startswith($P + "$")
        ))
      )
    | .key
  ' "$COVERAGE_MATRIX_JSON" 2>/dev/null | sort -u
}

sep() { printf '%*s\n' "80" '' | tr ' ' '-'; }

# ===== NUOVA FUNZIONE: aggiornamento dinamico coverage ========================
update_coverage_for_modified_classes() {
  if [[ ! -s "$STUB_MODIFIED_FILE" ]]; then
    echo "[coverage] Nessun file $STUB_MODIFIED_FILE o file vuoto: skip aggiornamento coverage."
    return 0
  fi

  echo "[coverage] Aggiornamento dinamico coverage per le classi in $STUB_MODIFIED_FILE"

  local TEST_CLASSES=()

  while IFS= read -r raw; do
    prod_fqn="$(sanitize_line "$raw")"
    [[ -z "$prod_fqn" ]] && continue

    # FQN di produzione: banca.ContoBancario
    # Test associato:    banca.ContoBancarioTest
    test_fqn="${prod_fqn}Test"
    echo "[coverage] Classe prod: $prod_fqn -> test: $test_fqn"
    TEST_CLASSES+=("$test_fqn")
  done < "$STUB_MODIFIED_FILE"

  if ((${#TEST_CLASSES[@]} == 0)); then
    echo "[coverage] Nessuna test class da eseguire."
    return 0
  fi

  echo "[coverage] Lancio Gradle solo sui test generati/rigenerati..."
  local CMD=( "./gradlew" ":app:test" )
  for cls in "${TEST_CLASSES[@]}"; do
    CMD+=( "--tests" "$cls" )
  done

  echo "[coverage] Comando: ${CMD[*]}"
  "${CMD[@]}"
  local EXIT_CODE=$?

  if [ $EXIT_CODE -ne 0 ]; then
    echo "[coverage] ERRORE: alcuni test generati non compilano o falliscono. Pipeline KO."
    exit $EXIT_CODE
  fi

  echo "[coverage] Coverage aggiornata con successo per le classi modificate."
}

# ===== Parte 1: STUB "classi modificate" ======================================
printf "==============================\n"
printf "Classi modificate lette dal file:\n"
if [[ -s "$STUB_MODIFIED_FILE" ]]; then
  # stampa così com'è (ma senza CR)
  while IFS= read -r raw; do
    line="$(sanitize_line "$raw")"; [[ -z "$line" ]] && continue
    printf "%s\n" "$line"
  done < "$STUB_MODIFIED_FILE"
else
  printf "(nessun file %s: uso solo la simulazione)\n" "$STUB_MODIFIED_FILE"
  printf "com.esempio.ClassA\ncom.esempio.ClassB\n"
fi
printf "==============================\n"

printf "Simulazione Chat2UnitTest per le classi modificate:\n"
if [[ -s "$STUB_MODIFIED_FILE" ]]; then
  while IFS= read -r raw; do
    line="$(sanitize_line "$raw")"; [[ -z "$line" ]] && continue
    printf " ... [simulato] test per %s\n" "$line"
  done < "$STUB_MODIFIED_FILE"
else
  printf " ... [simulato] test per com.esempio.ClassA\n"
  printf " ... [simulato] test per com.esempio.ClassB\n"
fi
printf "==============================\n"
printf "Risultati pipeline:\n"
printf " -> Test generati [simulati]\n"
printf " -> Test generati [simulati]\n"
printf "==============================\n"
printf "Pipeline minima funzionante sulla branch feature!\n"

# >>> QUI AGGIUNGIAMO L’AGGIORNAMENTO DINAMICO DELLA COVERAGE <<<
update_coverage_for_modified_classes

# >>> questo blocco permette di effettuare la commit e la push<<<

# ===== Parte 3: Commit & Push di test + benchmark + coverage (pipeline principale) ====
echo "[git] Controllo se ci sono modifiche da committare..."

# Configura utente git (se non già configurato nel workflow)
git config user.name  "AntonioTrovato"
git config user.email "atrovato@unisa.it"

# Aggiungi:
#  - i test funzionali (src/test/java)
#  - i benchmark generati (ju2jmh/src/jmh/java)
#  - la coverage matrix aggiornata
git add app/src/test/java || true
git add ju2jmh/src/jmh/java || true
git add app/coverage-matrix.json || true

# Controlla se c'è davvero qualcosa da committare
if [[ -n "$(git status --porcelain)" ]]; then
  echo "[git] Ci sono modifiche, creo il commit..."

  git commit -m "Update tests, benchmarks and coverage matrix for modified classes" || {
    echo "[git] Commit fallito (forse nessuna modifica reale dopo tutto)."
  }

  # Se siamo in GitHub Actions, di solito hai una variabile ACTIONS_TOKEN
  # passata dal workflow (es: ${{ secrets.GITHUB_TOKEN }})
  if [[ -n "${ACTIONS_TOKEN:-}" ]]; then
    echo "[git] Imposto remote con token e faccio push..."
    git remote set-url origin "https://AntonioTrovato:${ACTIONS_TOKEN}@github.com/AntonioTrovato/GradleProject.git"
    git push origin main || {
      echo "[git] ERRORE nel push verso origin/main."
      exit 1
    }
  else
    echo "[git] ACTIONS_TOKEN non settato: salto il push (solo commit locale)."
  fi
else
  echo "[git] Nessuna modifica rilevata, niente commit/push."
fi

# ===== Parte 2: DRY-RUN gestione classi eliminate =============================
if [[ -s "$STUB_DELETED_FILE" ]]; then
  sep
  printf "DRY-RUN: gestione classi eliminate (stub: %s)\n" "$STUB_DELETED_FILE"
  if [[ ! -f "$COVERAGE_MATRIX_JSON" ]]; then
    printf "ATTENZIONE: %s non trovato: mostrerò solo i nomi classe.\n" "$COVERAGE_MATRIX_JSON" >&2
  fi

  while IFS= read -r raw; do
    prod_fqn="$(sanitize_line "$raw")"
    [[ -z "$prod_fqn" ]] && continue

    printf "\n>> Classe di produzione ELIMINATA (stub): [%s]\n" "$prod_fqn"

    if [[ -f "$COVERAGE_MATRIX_JSON" ]]; then
      mapfile -t tests < <(tests_covering_prod_fqn "$prod_fqn")
      if ((${#tests[@]}==0)); then
        printf "   (nessun test con coverage registrata su questa classe)\n"
        continue
      fi

      printf "   Test JUnit interessati:\n"
      for t in "${tests[@]}"; do
        t="$(sanitize_line "$t")"
        printf "     - %s\n" "$t"

        test_class_fqn="${t%.*}"         # pkg.TestClass
        test_method="${t##*.}"           # testMetodo
        test_method="$(sanitize_line "$test_method")"

        bench_class_fqn="${test_class_fqn}._Benchmark"
        bench_method="benchmark_${test_method}"

        test_path="$(fqn_to_path "$test_class_fqn" "$TEST_ROOT")"
        bench_path="$(fqn_to_path "$bench_class_fqn" "$BENCH_ROOT")"

        printf "       (file test)        %s\n" "$test_path"
        printf "       (classe benchmark) %s\n" "$bench_path"
        printf "       (metodo benchmark) %s\n" "$bench_method"
        printf "       [DRY-RUN] rimuoverei il METODO di test '%s' (o l'intera classe se vuota).\n" "$test_method"
        printf "       [DRY-RUN] rimuoverei il METODO benchmark '%s' in %s (o la classe se vuota).\n" "$bench_method" "$bench_class_fqn"
        printf "       [DRY-RUN] aggiornerei coverage-matrix: rimuovere chiave '%s' oppure togliere '%s' dai valori.\n" "$t" "$prod_fqn"
      done
    fi
  done < "$STUB_DELETED_FILE"

  sep
  printf "FINE DRY-RUN classi eliminate.\n"
  sep
else
  sep
  printf "DRY-RUN: nessun file %s trovato (skipping gestione eliminate).\n" "$STUB_DELETED_FILE"
  sep
fi
