package listener;

import org.junit.Rule;

public abstract class BaseCoverageTest {

    @Rule
    public JacocoCoverageListener coverageListener = new JacocoCoverageListener();

    @org.openjdk.jmh.annotations.State(org.openjdk.jmh.annotations.Scope.Thread)
    public static abstract class _Benchmark extends se.chalmers.ju2jmh.api.JU2JmhBenchmark {

        @java.lang.Override
        public org.junit.runners.model.Statement applyRuleFields(org.junit.runners.model.Statement statement, org.junit.runner.Description description) {
            statement = this.applyRule(this.implementation().coverageListener, statement, description);
            statement = super.applyRuleFields(statement, description);
            return statement;
        }

        @java.lang.Override
        public abstract void createImplementation() throws java.lang.Throwable;

        @java.lang.Override
        public abstract BaseCoverageTest implementation();
    }
}
