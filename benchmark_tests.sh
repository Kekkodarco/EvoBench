#!/bin/bash

# Configure git
git config --global user.email "f.darco6@studenti.unisa.it"
git config --global user.name "Kekkodarco"

#TODO: JU2JMH SVUOTA LE CLASSI DI BENCHMARK NON
#TODO: INTERESSATE DAL COMMIT (SE UNA CLASSE
#TODO: DI BENCHMARK C'ERA LA SVUOTA, SE NON C'ERA
#TODO: LA CREA (OSSIA CI DEVE ESSERE LA CLASSE DI
#TODO: TEST DI UNITA') SENZA BENCHMARK

# Read the hashes of the last two commits using git log
commit_corrente=$(git log --format="%H" -n 1)
commit_precedente=$(git log --format="%H" -n 2 | tail -n 1)

# Make diff between the two commits
git_diff=$(git diff $commit_precedente $commit_corrente)

echo "GIT DIFF:"

echo "$git_diff"

echo "=================================================================================="

# Initialize an empty commit_blocks list
declare -a commit_blocks

# Initialize an empty block
block=""

# Read the diff string line by line
while IFS= read -r line; do
    # Check if the line starts with "diff --git"
    if [[ $line == "diff --git"* ]]; then
        # If yes, add the current block to commit_blocks and reset the block
        if [ -n "$block" ]; then
            commit_blocks+=("$block")
            block=""
        fi
    fi
    # Add the current line to the block
    block+="$line"$'\n'
done <<< "$git_diff"

# Add the last block to commit_blocks
if [ -n "$block" ]; then
    commit_blocks+=("$block")
fi

# Initialize empty arrays to store deleted and added methods
deleted_methods=()
added_methods=()

# Print the commit_blocks
for commit_block in "${commit_blocks[@]}"; do
  # Extract the first line of the string
  first_line=$(echo "$commit_block" | head -n 1)
  commit_block_copy="$commit_block"

  # Check if the first line matches the pattern "diff --git path_1 path_2"
  if [[ $first_line =~ ^diff\ --git\ .*\main/java\/(.*)\/([^\/]+)\.java\ .*$ ]]; then
    packages="${BASH_REMATCH[1]}"
    file_name="${BASH_REMATCH[2]}"

    # Replace slashes with dots and remove .java extension
    class_name="${packages//\//.}.${file_name%.java}"

    echo "COMMIT BLOCK:"
    echo "$commit_block"

    # For each line of the actual block (diff for a class), beginning with deleted methods
    while IFS= read -r line; do
      string=$(echo "$line" | head -n 1)
      if [[ $string =~ \-.*\ (static\ )?[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\ ([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*\( ]]; then
        echo "Line:"
        echo "$string"
        method_name=${BASH_REMATCH[2]}
        echo "method name:"
        echo "$method_name"
        deleted_methods+=("$class_name.$method_name")
      fi
    done <<< "$commit_block"

    echo "======================================================================0"
    echo "COMMIT BLOCK COPY:"
    echo "$commit_block_copy"

    # For each line of the actual block (diff for a class), ending with added methods
    while IFS= read -r line; do
      string=$(echo "$line" | head -n 1)
      if [[ $string =~ \+.*\ (static\ )?[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\ ([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*\( ]]; then
        echo "Line:"
        echo "$string"
        method_name=${BASH_REMATCH[2]}
        echo "Method Name:"
        echo "$method_name"
        # If the method is already in deleted methods, it means it has just been modified
        if [[ " ${deleted_methods[*]} " =~  $class_name.$method_name  ]]; then
          echo "This method is already in deleted list"
          # Remove the string from the list
          deleted_methods=( "${deleted_methods[@]/$class_name.$method_name}" )
        fi
        added_methods+=("$class_name.$method_name")
      fi
    done <<< "$commit_block_copy"

    #echo "=============================================================="
  fi

done

# Run the JAR file and capture the output
gradle jmhJar
ju2jmh_listing_output=$(java -jar ./ju2jmh/build/libs/ju2jmh-jmh.jar -l)

# Make the list of existing benchmarks
existing_benchmarks=()

while IFS= read -r line; do
  benchmark=$(echo "$line" | head -n 1)
  if [[ ! $benchmark =~ ^Benchmarks: ]]; then
    existing_benchmarks+=("$benchmark")
    echo "$benchmark"
  fi
done <<< "$ju2jmh_listing_output"

# Print each element of the list
for existing_benchmark in "${existing_benchmarks[@]}"; do
  echo "Benchmark:"
  echo "$existing_benchmark"
done

# Function to transform method names
transform_method() {
  local method=$1
  local packages=$(echo $method | cut -d'.' -f1-$(( $(echo $method | tr -cd '.' | wc -c) - 1 )))
  local method_name=$(echo $method | rev | cut -d'.' -f1 | rev)
  local class=$(echo $method | rev | cut -d'.' -f2 | rev)

  # Capitalize the method name
  local capitalized_method_name="$(echo "$method_name" | sed 's/^\(.\)/\U\1/')"

  # Add class name and prefix
  local transformed_method="$packages.$class"Test"._Benchmark.benchmark_test$capitalized_method_name"

  echo $transformed_method
}

benchmark_classes_to_generate=()
pattern="^([a-z.]*)([A-Z][a-zA-Z]*)Test\b(.*)"

for deleted_method in "${deleted_methods[@]}"; do
  transformed_method=$(transform_method "$deleted_method")
  echo "Deleted: "
  echo "$deleted_method -> $transformed_method"
  # Iterate through the list of existing benchmarks
  for existing_benchmark in "${existing_benchmarks[@]}"; do
    if [[ "$transformed_method" == "$existing_benchmark" ]]; then
      if [[ $existing_benchmark =~ $pattern ]]; then
        benchmark_class_to_generate="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
        echo "Benchmark Class to Generate:"
        echo "$benchmark_class_to_generate"
        found=false
        for element in "${benchmark_classes_to_generate[@]}"; do
          if [[ "$element" == "$benchmark_class_to_generate" ]]; then
            found=true
            break
          fi
        done
        if [ "$found" = true ]; then
          echo "The class is already in the list"
          echo ""
        else
          benchmark_classes_to_generate+=("$benchmark_class_to_generate")
        fi
      fi
    fi
  done
done

for added_method in "${added_methods[@]}"; do
  transformed_method=$(transform_method "$added_method")
  echo "Added: "
  echo "$added_method -> $transformed_method"
  found=false
  for existing_benchmark in "${existing_benchmarks[@]}"; do
    if [[ "$transformed_method" == "$existing_benchmark" ]]; then
      found=true
    fi
  done
  if [ "$found" = true ]; then
    echo "The added microbenchmark already exists"
    echo ""
  else
    if [[ $transformed_method =~ $pattern ]]; then
      benchmark_class_to_generate="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
      echo "Benchmark Class to Generate:"
      echo "$benchmark_class_to_generate"
      found2=false
      for element in "${benchmark_classes_to_generate[@]}"; do
        if [[ "$element" == "$benchmark_class_to_generate" ]]; then
          found2=true
          break
        fi
      done
      if [ "$found2" = true ]; then
        echo "The class is already in list"
        echo ""
      else
        benchmark_classes_to_generate+=("$benchmark_class_to_generate")
      fi
    fi
  fi
done

# Define an associative array to keep track of unique strings
declare -A seen

# Define the new list without duplicates
definitive_benchmark_classes_to_generate=()

# Iterate through the original list
for benchmark_class_to_generate in "${benchmark_classes_to_generate[@]}"; do
  # Check if the string has been seen before
  if [[ -z "${seen[$benchmark_class_to_generate]}" ]]; then
    # If not seen before, add it to the new list and mark it as seen
    definitive_benchmark_classes_to_generate+=("$benchmark_class_to_generate")
    seen["$benchmark_class_to_generate"]=1
  fi
done

pattern="^([a-z.]*)([A-Z][a-zA-Z]*)"

# Generate an empty text file
: > ./ju2jmh/benchmark_classes_to_generate.txt

# Generate all the benchmark classes needed
for benchmark_class_to_generate in "${definitive_benchmark_classes_to_generate[@]}"; do
  echo "Benchmark Class to Generate:"
  echo "$benchmark_class_to_generate"

  benchmark_class_to_generate+="Test"
  echo "Test from which Generate the Benchmark Class:"
  echo "$benchmark_class_to_generate"

  echo "$benchmark_class_to_generate" >> ./ju2jmh/benchmark_classes_to_generate.txt
done

file="./ju2jmh/benchmark_classes_to_generate.txt"

# Check if the file exists
if [ ! -f "$file" ]; then
  echo "File not found: $file"
  exit 1
fi

echo "FILE CONTENT:"

# Read the file line by line
while IFS= read -r line; do
  echo "$line"
done < "$file"

# Make and build the benchmark classes
java -jar ./ju-to-jmh/converter-all.jar ./app/src/test/java/ ./app/build/classes/java/test/ ./ju2jmh/src/jmh/java/ --class-names-file=./ju2jmh/benchmark_classes_to_generate.txt
gradle jmhJar

java -jar ./ju2jmh/build/libs/ju2jmh-jmh.jar -l

# Show the single microbenchmarks to run
for added_method in "${added_methods[@]}"; do
  transformed_method=$(transform_method "$added_method")

  echo "Microbenchmark to Run:"
  echo "$transformed_method"
done

# Run the single microbenchmarks
for added_method in "${added_methods[@]}"; do
  transformed_method=$(transform_method "$added_method")

  java -jar ./ju2jmh/build/libs/ju2jmh-jmh.jar "$transformed_method"
done

# Add to git all the benchmark classes generated/regenerated
for benchmark_class_to_generate in "${definitive_benchmark_classes_to_generate[@]}"; do
  benchmark_class_to_generate+="Test"

  # Convert the class name to a file path
  file_path="./ju2jmh/src/jmh/java/$(echo $benchmark_class_to_generate | tr '.' '/')".java

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
