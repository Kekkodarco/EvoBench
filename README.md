EvoBench – Technical Test Scenario for Incremental Benchmarking Pipeline

1. Overview

This repository represents a controlled experimental environment used to
test and validate an automated incremental pipeline for performance
benchmarking of Java applications.

The project itself is NOT the pipeline. Instead, it acts as a sandbox
Gradle project where the pipeline is executed, verified, debugged, and
refined.

The pipeline automatically: - Detects incremental code changes between
commits - Regenerates affected unit tests - Converts tests into JMH
microbenchmarks - Tracks code coverage - Executes and analyzes
benchmarks - Exports structured performance results

This repository is therefore a testing scenario used during the
internship activity for validating the full workflow.

------------------------------------------------------------------------

2. Incremental Pipeline Logic

At each commit i, the pipeline performs the following steps:

STEP 1 – Change Detection - Execute git diff between commit i and commit
(i-1) - Extract modified, added, and deleted production classes - Ignore
non-production code

STEP 2 – AST-Based Method Analysis - Send changed classes to the
ASTGenerator - Identify: * Added methods * Modified methods * Deleted
methods

STEP 3 – Test Management

For Modified Methods: - Query the Coverage-Matrix to retrieve covering
test cases - Delete outdated tests - Regenerate tests using
Chat2UnitTest - Validate generated tests through execution

For Added Methods: - Generate new test cases via Chat2UnitTest - Update
Coverage-Matrix - Validate generated tests

For Deleted Methods: - Remove associated test cases using
Coverage-Matrix mapping

Failure Condition: If at least one required test cannot be correctly
generated after 10 attempts, the pipeline fails and only the original
commit is pushed.

------------------------------------------------------------------------

3.  Test-to-Benchmark Conversion

Validated functional tests are converted into JMH microbenchmarks using
Ju2Jmh.

Naming conventions allow traceability between: - Production method -
Functional test - Generated microbenchmark

This enables performance tracking at method granularity.

------------------------------------------------------------------------

4.  Code Coverage Tracking

The project integrates JaCoCo for coverage instrumentation.

Components involved: - Gradle JaCoCo plugin - JaCoCo Agent -
JacocoCoverageListener

The Coverage-Matrix maintains a persistent mapping between: - Production
methods - Test cases - Microbenchmarks

------------------------------------------------------------------------

5.  Benchmark Execution and Analysis

Generated microbenchmarks can be analyzed using AMBER.

Outputs: - JSON result files - Performance comparison between commit
versions - Optional visualization layer

------------------------------------------------------------------------

6.  Secondary Pipeline

A secondary simplified pipeline periodically: - Executes the entire test
suite - Regenerates the full Coverage-Matrix

This ensures consistency over time and prevents drift.

------------------------------------------------------------------------

7.  Technologies

-   Java
-   Gradle
-   Git
-   JaCoCo
-   JMH
-   Chat2UnitTest
-   Ju2Jmh
-   AMBER
-   Docker
-   ngrok
-   LM Studio

------------------------------------------------------------------------

8.  Nature of the Repository

This project is a controlled toy example used to simulate realistic
software evolution scenarios.

It is designed exclusively for:

-   Experimental validation
-   Incremental analysis testing
-   Integration debugging
-   Research and internship development activities

It is not intended to represent a production system.