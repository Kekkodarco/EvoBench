package suite;

import listener.JacocoCoverageRunListener;
import org.junit.Test;
import org.junit.runner.JUnitCore;
import org.junit.runner.Result;
import org.junit.runner.notification.Failure;

public class MainTestSuite {

    @Test
    public void test() {
        JUnitCore junit = new JUnitCore();
        // Add the custom run listener
        junit.addListener(new JacocoCoverageRunListener());
        // Manually run each test class to ensure the listener is active
        Result result = junit.run(banca.ContoBancarioTest.class, utente.UtenteTest.class, utente.personale.AmministratoreTest.class, utente.personale.TecnicoTest.class);
        // Print results if needed
        for (Failure failure : result.getFailures()) {
            System.out.println("Test failed: " + failure.getDescription());
        }
    }
}
