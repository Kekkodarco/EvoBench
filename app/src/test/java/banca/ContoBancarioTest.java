Here is a JUnit test class for the `ContoBancario` class, testing the `prelievo` method:
```java
package banca;

import org.junit.Before;
import org.junit.Test;

public class ContoBancarioTest {

    private ContoBancario conto;

    @Before
    public void setUp() {
        conto = new ContoBancario("1234567890", 100);
    }

    @Test
    public void testPrelievo() {
        int quota = 50;
        assertEquals(1, conto.prelievo(quota));
        assertEquals(50, conto.getSaldo());
    }

    @Test
    public void testPrelievo2() {
        int quota = 150;
        assertEquals(0, conto.prelievo(quota));
        assertEquals(100, conto.getSaldo());
    }
}
```
The `setUp` method creates a new instance of the `ContoBancario` class with an id of "1234567890" and a saldo of 100. The two test methods, `testPrelievo` and `testPrelievo2`, are used to test the `prelievo` method with different input parameters.

The first test, `testPrelievo`, verifies that the `prelievo` method returns 1 when the prelevato amount is less than or equal to the current saldo, and that the saldo is updated correctly. The second test, `testPrelievo2`, verifies that the `prelievo` method returns 0 when the prelevato amount is greater than the current saldo, and that the saldo remains unchanged.