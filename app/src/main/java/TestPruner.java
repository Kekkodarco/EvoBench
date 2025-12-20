import com.github.javaparser.JavaParser;
import com.github.javaparser.ast.CompilationUnit;
import com.github.javaparser.ast.body.MethodDeclaration;

import java.io.IOException;
import java.nio.file.*;
import java.util.*;
import java.util.stream.Collectors;
//Rimuove i metodi JUnit dal file app/src/test/java/.../TestClass.java.
public class TestPruner {

    public static void main(String[] args) throws Exception {
        if (args.length < 2) {
            System.err.println("Usage: java TestPruner <tests_to_delete.txt> <testRootDir>");
            System.exit(1);
        }

        Path listFile = Paths.get(args[0]);
        Path testRoot = Paths.get(args[1]);

        List<String> lines = Files.exists(listFile) ? Files.readAllLines(listFile) : Collections.emptyList();
        Map<String, Set<String>> byClass = new LinkedHashMap<>();

        for (String raw : lines) {
            String t = sanitize(raw);
            if (t.isEmpty() || t.startsWith("#")) continue;

            int lastDot = t.lastIndexOf('.');
            if (lastDot <= 0 || lastDot == t.length() - 1) continue;

            String cls = t.substring(0, lastDot);
            String method = t.substring(lastDot + 1);

            byClass.computeIfAbsent(cls, k -> new LinkedHashSet<>()).add(method);
        }

        JavaParser parser = new JavaParser();

        for (Map.Entry<String, Set<String>> e : byClass.entrySet()) {
            String testClassFqn = e.getKey();
            Set<String> methodsToRemove = e.getValue();

            Path testFile = fqnToJavaPath(testRoot, testClassFqn);

            if (!Files.exists(testFile)) {
                System.out.println("[TestPruner] Missing file: " + testFile);
                continue;
            }

            CompilationUnit cu = parser.parse(testFile).getResult().orElse(null);
            if (cu == null) {
                System.out.println("[TestPruner] Cannot parse: " + testFile);
                continue;
            }

            int removedCount = 0;
            for (MethodDeclaration md : cu.findAll(MethodDeclaration.class)) {
                if (methodsToRemove.contains(md.getNameAsString())) {
                    md.remove();
                    removedCount++;
                }
            }

            if (removedCount == 0) {
                System.out.println("[TestPruner] Nothing removed in " + testFile);
                continue;
            }

            // Se non ci sono più metodi @Test, elimino l'intero file (pulizia)
            boolean hasAnyTest = cu.findAll(MethodDeclaration.class).stream()
                    .anyMatch(m -> m.getNameAsString().startsWith("test"));

            if (!hasAnyTest) {
                Files.deleteIfExists(testFile);
                System.out.println("[TestPruner] Deleted empty test class file: " + testFile);
            } else {
                Files.writeString(testFile, cu.toString());
                System.out.println("[TestPruner] Updated: " + testFile + " (removed " + removedCount + ")");
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
