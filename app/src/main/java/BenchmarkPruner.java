import com.github.javaparser.JavaParser;
import com.github.javaparser.ast.CompilationUnit;
import com.github.javaparser.ast.body.ClassOrInterfaceDeclaration;
import com.github.javaparser.ast.body.MethodDeclaration;

import java.nio.file.*;
import java.util.*;

//Rimuove i metodi benchmark dalla inner class _Benchmark nel file convertito ju2jmh/src/jmh/java/.../TestClass.java.

public class BenchmarkPruner {

    public static void main(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("Usage: java BenchmarkPruner <tests_to_delete.txt> <benchRootDir>");
            System.exit(1);
        }

        Path listFile = Paths.get(args[0]);
        Path benchRoot = Paths.get(args[1]);

        List<String> lines = Files.exists(listFile) ? Files.readAllLines(listFile) : Collections.emptyList();

        // Raggruppo per TestClassFqn -> set(testMethodName)
        Map<String, Set<String>> byClass = new LinkedHashMap<>();
        for (String raw : lines) {
            String t = sanitize(raw);
            if (t.isEmpty() || t.startsWith("#")) continue;

            int lastDot = t.lastIndexOf('.');
            if (lastDot <= 0 || lastDot == t.length() - 1) continue;

            String cls = t.substring(0, lastDot);          // utente.UtenteTest
            String testMethod = t.substring(lastDot + 1);  // testGetName

            byClass.computeIfAbsent(cls, k -> new LinkedHashSet<>()).add(testMethod);
        }

        JavaParser parser = new JavaParser();

        for (Map.Entry<String, Set<String>> e : byClass.entrySet()) {
            String testClassFqn = e.getKey();
            Set<String> testMethods = e.getValue();

            Path benchFile = fqnToJavaPath(benchRoot, testClassFqn); // stesso nome file del test
            if (!Files.exists(benchFile)) {
                System.out.println("[BenchmarkPruner] Missing file: " + benchFile);
                continue;
            }

            CompilationUnit cu = parser.parse(benchFile).getResult().orElse(null);
            if (cu == null) {
                System.out.println("[BenchmarkPruner] Cannot parse: " + benchFile);
                continue;
            }

            Optional<ClassOrInterfaceDeclaration> benchClassOpt = cu.findAll(ClassOrInterfaceDeclaration.class).stream()
                    .filter(c -> c.getNameAsString().equals("_Benchmark"))
                    .findFirst();

            int removed = 0;

            if (benchClassOpt.isPresent()) {
                // CASO 1: inner class _Benchmark esiste
                ClassOrInterfaceDeclaration benchClass = benchClassOpt.get();

                for (MethodDeclaration md : new ArrayList<>(benchClass.findAll(MethodDeclaration.class))) {
                    String name = md.getNameAsString();
                    for (String tName : testMethods) {
                        String expected = "benchmark_" + tName;
                        if (name.equals(expected)) {
                            md.remove();
                            removed++;
                        }
                    }
                }

                // Se _Benchmark è rimasta senza benchmark_*, la elimino
                boolean hasAnyBenchmarkLeft = benchClass.findAll(MethodDeclaration.class).stream()
                        .anyMatch(m -> m.getNameAsString().startsWith("benchmark_"));

                if (!hasAnyBenchmarkLeft) {
                    benchClass.remove();
                    System.out.println("[BenchmarkPruner] Removed empty _Benchmark class from: " + benchFile);
                } else {
                    System.out.println("[BenchmarkPruner] Updated _Benchmark in: " + benchFile +
                            " (removed " + removed + ")");
                }

            } else {
                // CASO 2: fallback — nessuna _Benchmark, rimuovo benchmark_* ovunque
                for (MethodDeclaration md : new ArrayList<>(cu.findAll(MethodDeclaration.class))) {
                    String name = md.getNameAsString();
                    for (String tName : testMethods) {
                        String expected = "benchmark_" + tName;
                        if (name.equals(expected)) {
                            md.remove();
                            removed++;
                        }
                    }
                }

                System.out.println("[BenchmarkPruner] Fallback prune in file: " + benchFile +
                        " (removed " + removed + ")");
            }

            if (removed > 0) {
                Files.writeString(benchFile, cu.toString());
            } else {
                System.out.println("[BenchmarkPruner] Nothing removed in " + benchFile);
            }
        }
    }

    private static Path fqnToJavaPath(Path root, String fqn) {
        return root.resolve(fqn.replace('.', '/') + ".java").normalize();
    }

    private static String sanitize(String s) {
        if (s == null) return "";
        s = s.replace("\uFEFF", "");
        s = s.replace("\r", "").trim();
        return s;
    }
}
