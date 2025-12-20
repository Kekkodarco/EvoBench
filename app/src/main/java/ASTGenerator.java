import com.github.javaparser.JavaParser;
import com.github.javaparser.ast.CompilationUnit;
import com.github.javaparser.ast.body.MethodDeclaration;
import com.github.javaparser.ast.type.ClassOrInterfaceType;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.*;
import java.util.Set;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class ASTGenerator {
    public static void main(String[] args) {
        if (args.length != 1) {
            System.out.println("Usage: java ASTGenerator <file_with_modified_classes>");
            return;
        }

        String filePath = args[0];

        try {
            List<String> modifiedClasses = Files.readAllLines(Paths.get(filePath));
            JavaParser javaParser = new JavaParser();

            Set<String> allModified = new HashSet<>();
            Set<String> allAdded = new HashSet<>();
            Set<String> allDeleted = new HashSet<>();

            for (String rawClassName : modifiedClasses) {
                String className = rawClassName.trim();
                if (className.isEmpty()) continue;

                String filePathJava = className.replace('.', '/') + ".java";
                String currentFullPath = "./app/src/main/java/" + filePathJava;

                // Current version AST (working tree)
                List<MethodDeclaration> currentMethods =
                        createASTFromFile(javaParser, currentFullPath, "Current", className);

                // Previous version content (HEAD^)
                String previousContent = getPreviousCommitContent(filePathJava);

                if (previousContent != null) {
                    // Previous version AST (from git show)
                    List<MethodDeclaration> previousMethods =
                            createASTFromContent(javaParser, previousContent, "Previous", className);

                    // Se la classe è stata eliminata nel working tree ma esisteva prima: tutto DELETED
                    if (currentMethods.isEmpty() && !previousMethods.isEmpty()) {
                        for (MethodDeclaration pm : previousMethods) {
                            String sig = getMethodSignature(pm);
                            String methodName = extractMethodNameAndParameters(sig);
                            if (methodName != null) {
                                allDeleted.add(className + "." + methodName);
                            }
                        }
                        continue;
                    }

                    MethodDiff diff = compareMethods(className, currentMethods, previousMethods);
                    allAdded.addAll(diff.added);
                    allModified.addAll(diff.modified);
                    allDeleted.addAll(diff.deleted);

                } else {
                    // Classe nuova: tutti i metodi correnti sono ADDED
                    for (MethodDeclaration cm : currentMethods) {
                        String sig = getMethodSignature(cm);
                        String methodName = extractMethodNameAndParameters(sig);
                        if (methodName != null) {
                            allAdded.add(className + "." + methodName);
                        }
                    }
                }
            }

            // Scrittura file finali
            writeSorted("modified_methods.txt", allModified);
            writeSorted("added_methods.txt", allAdded);
            writeSorted("deleted_methods.txt", allDeleted);

            System.out.println("Modified methods: " + allModified.size());
            System.out.println("Added methods: " + allAdded.size());
            System.out.println("Deleted methods: " + allDeleted.size());

        } catch (IOException e) {
            e.printStackTrace();
        }
    }

    // ===== Utility: scrittura file ordinata =====
    private static void writeSorted(String path, Set<String> lines) throws IOException {
        List<String> out = new ArrayList<>(lines);
        Collections.sort(out);
        Files.write(Paths.get(path), out);
        System.out.println("Written " + out.size() + " lines to " + path);
    }

    // Method to create the current AST and return the methods
    private static List<MethodDeclaration> createASTFromFile(JavaParser javaParser, String filePath, String version, String className) {
        File file = new File(filePath);
        List<MethodDeclaration> methods = new ArrayList<>();
        if (file.exists()) {
            try {
                CompilationUnit cu = javaParser.parse(file).getResult().orElse(null);
                if (cu != null) {
                    System.out.println("AST for " + version + " version of class: " + className);
                    methods.addAll(cu.findAll(MethodDeclaration.class));
                } else {
                    System.out.println("Could not parse the " + version + " version file: " + filePath);
                }
            } catch (IOException e) {
                e.printStackTrace();
            }
        } else {
            System.out.println(version + " version file not found: " + filePath);
        }
        return methods;
    }

    // Method to create the previous AST and return methods
    private static List<MethodDeclaration> createASTFromContent(JavaParser javaParser, String content, String version, String className) {
        List<MethodDeclaration> methods = new ArrayList<>();
        CompilationUnit cu = javaParser.parse(content).getResult().orElse(null);
        if (cu != null) {
            System.out.println("AST for " + version + " version of class: " + className);
            methods.addAll(cu.findAll(MethodDeclaration.class));
        } else {
            System.out.println("Could not parse the " + version + " version content for class: " + className);
        }
        return methods;
    }

    private static class MethodDiff {
        final Set<String> added = new HashSet<>();
        final Set<String> modified = new HashSet<>();
        final Set<String> deleted = new HashSet<>();
    }

    // Method to compare the two versions
    private static MethodDiff compareMethods(String className,
                                             List<MethodDeclaration> currentMethods,
                                             List<MethodDeclaration> previousMethods) {

        Set<String> currentSignatures = new HashSet<>();
        Set<String> previousSignatures = new HashSet<>();

        for (MethodDeclaration m : currentMethods) currentSignatures.add(getMethodSignature(m));
        for (MethodDeclaration m : previousMethods) previousSignatures.add(getMethodSignature(m));

        // ADDED = current - previous
        Set<String> added = new HashSet<>(currentSignatures);
        added.removeAll(previousSignatures);

        // DELETED = previous - current
        Set<String> deleted = new HashSet<>(previousSignatures);
        deleted.removeAll(currentSignatures);

        // MODIFIED = same signature exists but body changed
        Set<String> modified = new HashSet<>();
        for (MethodDeclaration m : currentMethods) {
            String sig = getMethodSignature(m);
            if (previousSignatures.contains(sig) && hasMethodChanged(m, previousMethods)) {
                modified.add(sig);
            }
        }

        MethodDiff diff = new MethodDiff();

        // Converte signature -> riga FQN (classe.metodo)
        for (String sig : added) {
            String fqn = className + "." + extractMethodNameAndParameters(sig);
            diff.added.add(fqn);
        }
        for (String sig : modified) {
            String fqn = className + "." + extractMethodNameAndParameters(sig);
            diff.modified.add(fqn);
        }
        for (String sig : deleted) {
            String fqn = className + "." + extractMethodNameAndParameters(sig);
            diff.deleted.add(fqn);
        }

        return diff;
    }

    // Method to obtain the signature
    private static String getMethodSignature(MethodDeclaration method) {
        StringBuilder signature = new StringBuilder();

        // Add access modifiers, type and name
        method.getModifiers().forEach(modifier -> signature.append(modifier.getKeyword().asString()).append(" "));
        signature.append(getTypeAsString(method.getType())).append(" ");
        signature.append(method.getNameAsString()).append("(");

        // Add parameters
        method.getParameters().forEach(param -> signature.append(getTypeAsString(param.getType())).append(", "));
        if (method.getParameters().size() > 0) {
            signature.setLength(signature.length() - 2); // Remove last comma and space
        }
        signature.append(")");

        return signature.toString();
    }

    // Handle generic types
    private static String getTypeAsString(com.github.javaparser.ast.type.Type type) {
        StringBuilder typeString = new StringBuilder();

        if (type.isClassOrInterfaceType()) {
            ClassOrInterfaceType classOrInterfaceType = type.asClassOrInterfaceType();
            typeString.append(classOrInterfaceType.getNameAsString());

            classOrInterfaceType.getTypeArguments().ifPresent(typeArgs -> {
                typeString.append("<");
                typeArgs.forEach(arg -> typeString.append(getTypeAsString(arg)).append(", "));
                if (typeArgs.size() > 0) {
                    typeString.setLength(typeString.length() - 2); // Remove last comma and space
                }
                typeString.append(">");
            });
        } else {
            typeString.append(type.asString());
        }

        return typeString.toString();
    }

    // Extract method name and parameters to obtain the final signature
    private static String extractMethodNameAndParameters(String methodSignature) {
        //TODO: ADD PARAMETERS

        // Define the regexes
        String regex = "(\\w+)\\s*\\((.*?)\\)";
        Pattern pattern = Pattern.compile(regex);
        Matcher matcher = pattern.matcher(methodSignature);

        if (matcher.find()) {
            String methodName = matcher.group(1); // Method name
            String parameters = matcher.group(2); // Method parameters
            //return methodName + "(" + parameters + ")";
            return methodName;
        }

        return null; // Null if no match
    }

    // Method to verify if a method has been modified
    private static boolean hasMethodChanged(MethodDeclaration currentMethod, List<MethodDeclaration> previousMethods) {
        //TODO: COMMENTS ADDED ARE RECOGNIZED AS MODIFICATIONS, INVESTIGATE FOR OTHERS AND RESOLVE
        String currentSignature = getMethodSignature(currentMethod);
        for (MethodDeclaration previousMethod : previousMethods) {
            if (currentSignature.equals(getMethodSignature(previousMethod))) {
                // Here's were the body is compared
                return !currentMethod.getBody().equals(previousMethod.getBody());
            }
        }
        return false; // If no match, return false
    }

    // Method to get the content of a previous version file on Git
    private static String getPreviousCommitContent(String filePathJava) {
        try {
            Process process = new ProcessBuilder("git", "show", "HEAD^:" + "app/src/main/java/" + filePathJava).start();
            process.waitFor();
            if (process.exitValue() == 0) {
                return new String(process.getInputStream().readAllBytes());
            }
        } catch (IOException | InterruptedException e) {
            e.printStackTrace();
        }
        return null;
    }
}
