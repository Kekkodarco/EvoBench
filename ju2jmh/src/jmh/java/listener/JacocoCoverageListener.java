package listener;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.jacoco.core.analysis.Analyzer;
import org.jacoco.core.analysis.CoverageBuilder;
import org.jacoco.core.analysis.IClassCoverage;
import org.jacoco.core.analysis.IMethodCoverage;
import org.jacoco.core.data.ExecutionData;
import org.jacoco.core.data.ExecutionDataReader;
import org.jacoco.core.data.ExecutionDataStore;
import org.jacoco.core.data.SessionInfoStore;
import org.junit.rules.TestWatcher;
import org.junit.runner.Description;
import javax.management.MBeanServerConnection;
import javax.management.ObjectName;
import java.io.*;
import java.lang.management.ManagementFactory;
import java.util.*;

public class JacocoCoverageListener extends TestWatcher {

    private static final String JACOCO_MBEAN_NAME = "org.jacoco:type=Runtime";
    private static final String COVERAGE_MATRIX_FILE = "coverage-matrix.json";
    private static volatile boolean warnedNoJacocoMBean = false;

    @Override
    protected void succeeded(Description description) {
        updateCoverageMatrix(description);
    }

    @Override
    protected void failed(Throwable e, Description description) {
        updateCoverageMatrix(description);
    }

    private void updateCoverageMatrix(Description description) {
        try {
            // Connect to the platform MBean server
            MBeanServerConnection mbsc = ManagementFactory.getPlatformMBeanServer();
            ObjectName objectName = new ObjectName(JACOCO_MBEAN_NAME);

            // If JaCoCo agent is not attached in this JVM (typical in JMH/AMBER),
            // the MBean won't exist -> avoid spamming stacktraces
            if (!mbsc.isRegistered(objectName)) {
                if (!warnedNoJacocoMBean) {
                    warnedNoJacocoMBean = true;
                    System.out.println("[JacocoCoverageListener][WARN] JaCoCo MBean not found (org.jacoco:type=Runtime). " +
                            "Coverage collection skipped for this JVM. If this happens under JMH/AMBER, " +
                            "you must attach JaCoCo agent to that JVM to collect coverage.");
                }
                return;
            }

            // Invoke the dump command with reset=true
            byte[] executionData = (byte[]) mbsc.invoke(
                    objectName,
                    "getExecutionData",
                    new Object[]{true},
                    new String[]{"boolean"}
            );

            // Parse execution data
            ExecutionDataStore executionDataStore = new ExecutionDataStore();
            SessionInfoStore sessionInfoStore = new SessionInfoStore();
            ExecutionDataReader reader = new ExecutionDataReader(new ByteArrayInputStream(executionData));
            reader.setExecutionDataVisitor(executionDataStore);
            reader.setSessionInfoVisitor(sessionInfoStore);
            reader.read();

            // Analyze covered classes to determine covered methods
            CoverageBuilder coverageBuilder = new CoverageBuilder();
            Analyzer analyzer = new Analyzer(executionDataStore, coverageBuilder);

            // Try multiple possible class output dirs depending on where we run from
            File[] candidateDirs = new File[]{
                    new File("build/classes/java/main"),
                    new File("app/build/classes/java/main"),
                    new File("build/classes/java/test"),
                    new File("app/build/classes/java/test")
            };

            File classesDir = null;
            for (File d : candidateDirs) {
                if (d.exists() && d.isDirectory()) {
                    classesDir = d;
                    break;
                }
            }

            if (classesDir == null) {
                // Not fatal: we can’t map execution data to .class files, so skip update
                System.out.println("[JacocoCoverageListener][WARN] No classesDir found among known candidates. " +
                        "Coverage matrix update skipped for: " + description.getClassName() + "." + description.getMethodName());
                return;
            }

            ArrayList<String> fullyQualifiedCurrentMethods = new ArrayList<>();

            for (ExecutionData data : executionDataStore.getContents()) {
                if (!data.hasHits()) continue;

                String className = data.getName().replace("/", ".");
                File classFile = new File(classesDir, data.getName() + ".class");

                if (classFile.exists()) {
                    try (FileInputStream classStream = new FileInputStream(classFile)) {
                        analyzer.analyzeClass(classStream, data.getName());
                    }
                }

                Set<String> coveredMethods = getCoveredMethods(coverageBuilder, className);
                ArrayList<String> coveredMethodsFullyQualified = new ArrayList<>();

                for (String method : coveredMethods) {
                    String m = method;
                    if ("<init>".equals(m)) m = getSimpleClassName(className);
                    fullyQualifiedCurrentMethods.add(className + "." + m);
                    coveredMethodsFullyQualified.add(className + "." + m);
                }

                updateCoverageMatrixFile(
                        description.getClassName() + "." + description.getMethodName(),
                        coveredMethodsFullyQualified
                );
            }

            deleteOlderCoveredMethodsFromMatrix(
                    description.getClassName() + "." + description.getMethodName(),
                    fullyQualifiedCurrentMethods
            );

        } catch (Exception e) {
            // Do NOT spam stacktraces in tight JMH loops.
            System.out.println("[JacocoCoverageListener][WARN] Coverage update failed for " +
                    description.getClassName() + "." + description.getMethodName() +
                    " -> " + e.getClass().getSimpleName() + ": " + e.getMessage());
        }
    }

    public void deleteOlderCoveredMethodsFromMatrix(String testName, ArrayList<String> fullyQualifiedCurrentMethods) {
        ObjectMapper objectMapper = new ObjectMapper();
        Map<String, Set<String>> coverageMatrix = new HashMap<>();
        // Read existing coverage-matrix.json if it exists
        File coverageFile = new File(COVERAGE_MATRIX_FILE);
        if (coverageFile.exists()) {
            try {
                coverageMatrix = objectMapper.readValue(coverageFile, new TypeReference<Map<String, Set<String>>>() {
                });
            } catch (IOException e) {
                e.printStackTrace();
                System.out.println("Failed to read coverage-matrix.json");
            }
        }
        // Update the coverage matrix
        Set<String> existingMethods = coverageMatrix.computeIfAbsent(testName, k -> new HashSet<>());
        Set<String> methodsToRemove = new HashSet<>(existingMethods);
        for (String method : methodsToRemove) {
            if (!fullyQualifiedCurrentMethods.contains(method)) {
                existingMethods.remove(method);
            }
        }
        // Write the updated coverage matrix back to the file, creating the file if it doesn't exist
        try {
            if (!coverageFile.exists()) {
                coverageFile.createNewFile();
            }
            try (FileWriter fileWriter = new FileWriter(coverageFile)) {
                objectMapper.writerWithDefaultPrettyPrinter().writeValue(fileWriter, coverageMatrix);
            }
        } catch (IOException e) {
            e.printStackTrace();
            System.out.println("Failed to write coverage-matrix.json");
        }
    }

    public String getSimpleClassName(String className) {
        if (className.contains(".")) {
            return className.substring(className.lastIndexOf('.') + 1);
        }
        return className;
    }

    private Set<String> getCoveredMethods(CoverageBuilder coverageBuilder, String className) {
        // TODO: ADD PARAMETERS
        Set<String> coveredMethods = new HashSet<>();
        className = className.replace(".", "/");
        for (IClassCoverage classCoverage : coverageBuilder.getClasses()) {
            if (classCoverage.getName().equals(className)) {
                for (IMethodCoverage methodCoverage : classCoverage.getMethods()) {
                    if (methodCoverage.getInstructionCounter().getCoveredCount() > 0) {
                        // Get method name
                        String methodName = methodCoverage.getName();
                        /*String methodDescriptor = methodCoverage.getDesc(); // Get method descriptor

                        // Extract parameter types
                        String paramTypes = extractParameterTypes(methodDescriptor);
                        coveredMethods.add(methodName + "(" + paramTypes + ")"); // Add formatted method name to the set*/
                        coveredMethods.add(methodName);
                    }
                }
            }
        }
        return coveredMethods;
    }

    private void updateCoverageMatrixFile(String testName, ArrayList<String> coveredMethods) {
        ObjectMapper objectMapper = new ObjectMapper();
        Map<String, Set<String>> coverageMatrix = new HashMap<>();
        // Read existing coverage-matrix.json if it exists
        File coverageFile = new File(COVERAGE_MATRIX_FILE);
        if (coverageFile.exists()) {
            try {
                coverageMatrix = objectMapper.readValue(coverageFile, new TypeReference<Map<String, Set<String>>>() {
                });
            } catch (IOException e) {
                e.printStackTrace();
                System.out.println("Failed to read coverage-matrix.json");
            }
        }
        // Update the coverage matrix
        coverageMatrix.computeIfAbsent(testName, k -> new HashSet<>());
        for (String method : coveredMethods) {
            coverageMatrix.get(testName).add(method);
        }
        // Write the updated coverage matrix back to the file, creating the file if it doesn't exist
        try {
            if (!coverageFile.exists()) {
                coverageFile.createNewFile();
            }
            try (FileWriter fileWriter = new FileWriter(coverageFile)) {
                objectMapper.writerWithDefaultPrettyPrinter().writeValue(fileWriter, coverageMatrix);
            }
        } catch (IOException e) {
            e.printStackTrace();
            System.out.println("Failed to write coverage-matrix.json");
        }
    }

    // Method to extract parameter types from the method descriptor
    private String extractParameterTypes(String descriptor) {
        StringBuilder paramTypes = new StringBuilder();
        // The descriptor starts with '(' and ends with ')'
        if (descriptor.startsWith("(") && descriptor.contains(")")) {
            // Extract the substring between '(' and ')'
            String params = descriptor.substring(descriptor.indexOf('(') + 1, descriptor.indexOf(')'));
            // Split by ',' to get individual parameter types
            String[] paramArray = params.split(",");
            for (String param : paramArray) {
                // Clean up the parameter type and add it to the StringBuilder
                // Remove 'L' prefix and ';' suffix
                param = param.replaceAll("^L", "").replaceAll(";$", "");
                paramTypes.append(param).append(", ");
            }
            // Remove trailing comma and space if there are any parameters
            if (paramTypes.length() > 0) {
                // Remove last ", "
                paramTypes.setLength(paramTypes.length() - 2);
            }
        }
        return paramTypes.toString();
    }
}
