import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.*;

/**
 * Utility: genera un input JSON per Chat2UnitTest a partire da un file di metodi.
 *
 * Formato atteso per ogni riga del file input:
 *   <fully.qualified.ClassName>.<methodName>
 *   oppure
 *   <fully.qualified.ClassName>.<methodName>(...)
 *
 * Output JSON:
 * {
 *   "/abs/path/to/Class.java": ["method1","method2",...],
 *   ...
 * }
 */
public class Chat2UnitTestInputBuilder {

    public static void main(String[] args) throws IOException {
        if (args.length < 3) {
            System.err.println("Usage: java Chat2UnitTestInputBuilder <methodsFile.txt> <prodRootDir> <output.json>");
            System.err.println("Example: java Chat2UnitTestInputBuilder modified_methods.txt app/src/main/java input_modified.json");
            System.exit(1);
        }

        Path methodsFile = Paths.get(args[0]);
        Path prodRootDir = Paths.get(args[1]);
        Path outputJson = Paths.get(args[2]);

        Map<String, LinkedHashSet<String>> byFile = new LinkedHashMap<>();

        List<String> lines = Files.exists(methodsFile) ? Files.readAllLines(methodsFile) : Collections.emptyList();
        for (String raw : lines) {
            String line = sanitize(raw);
            if (line.isEmpty() || line.startsWith("#")) continue;

            MethodRef ref = parseMethodRef(line);
            if (ref == null) {
                // riga non valida: la ignoriamo
                continue;
            }

            Path javaFile = prodRootDir.resolve(ref.classFqn.replace('.', '/') + ".java")
                    .toAbsolutePath()
                    .normalize();

            String javaFileKey = javaFile.toString().replace('\\', '/'); // forza slash Unix anche su Windows
            byFile.computeIfAbsent(javaFileKey, k -> new LinkedHashSet<>()).add(ref.methodName);
        }

        // Convert LinkedHashSet -> List per JSON
        Map<String, List<String>> out = new LinkedHashMap<>();
        for (Map.Entry<String, LinkedHashSet<String>> e : byFile.entrySet()) {
            out.put(e.getKey(), new ArrayList<>(e.getValue()));
        }

        ObjectMapper mapper = new ObjectMapper().enable(SerializationFeature.INDENT_OUTPUT);
        Files.createDirectories(outputJson.toAbsolutePath().getParent());
        mapper.writeValue(outputJson.toFile(), out);

        System.out.println("[OK] Written: " + outputJson.toAbsolutePath());
        System.out.println("[OK] Entries: " + out.size());
    }

    private static String sanitize(String s) {
        if (s == null) return "";
        s = s.replace("\uFEFF", "");      // BOM
        s = s.replace("\r", "").trim();   // CRLF -> LF + trim
        return s;
    }

    /**
     * Accetta:
     * - pkg.Classe.metodo
     * - pkg.Classe.metodo(...)
     */
    private static MethodRef parseMethodRef(String line) {
        int lastDot = line.lastIndexOf('.');
        if (lastDot <= 0 || lastDot == line.length() - 1) return null;

        String classFqn = line.substring(0, lastDot).trim();
        String methodPart = line.substring(lastDot + 1).trim();

        // se c'è firma, tengo solo il nome prima di '('
        int paren = methodPart.indexOf('(');
        String methodName = (paren >= 0) ? methodPart.substring(0, paren).trim() : methodPart;

        if (classFqn.isEmpty() || methodName.isEmpty()) return null;
        return new MethodRef(classFqn, methodName);
    }

    private static class MethodRef {
        final String classFqn;
        final String methodName;

        MethodRef(String classFqn, String methodName) {
            this.classFqn = classFqn;
            this.methodName = methodName;
        }
    }
}
