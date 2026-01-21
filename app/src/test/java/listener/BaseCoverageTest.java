package listener;

import org.junit.Rule;

public abstract class BaseCoverageTest {

    @Rule
    public JacocoCoverageListener coverageListener = new JacocoCoverageListener();

}
