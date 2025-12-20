package listener;

import org.junit.runner.Description;
import org.junit.runner.notification.Failure;
import org.junit.runner.notification.RunListener;

public class JacocoCoverageRunListener extends RunListener {

    private final JacocoCoverageListener coverageListener = new JacocoCoverageListener();

    @Override
    public void testStarted(Description description) {
        // Any setup before each test starts, if needed
        System.out.println("Starting test: " + description.getDisplayName());
    }

    @Override
    public void testFailure(Failure failure) {
        // Simulate calling `failed` from JacocoCoverageListener
        coverageListener.failed(failure.getException(), failure.getDescription());
    }

    @Override
    public void testFinished(Description description) {
        // Simulate calling `succeeded` from JacocoCoverageListener if the test passed
        System.out.println("Finished test: " + description.getDisplayName());
        coverageListener.succeeded(description);
    }
}
