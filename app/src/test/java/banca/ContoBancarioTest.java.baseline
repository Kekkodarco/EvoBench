package banca;

import static org.junit.Assert.*;














import org.junit.Assert;
import org.junit.Test;
import org.junit.Before;
import listener.BaseCoverageTest;

public class ContoBancarioTest  extends BaseCoverageTest {

    @Before
public void setUp() {
contobancario = new ContoBancario();
    }



private ContoBancario contobancario;


















    @Test
public void testPrelievo_saldoNegativo_case1() {
        // Given: a negative saldo
ContoBancario conta = new ContoBancario("default", -10);

        // When: the method is called with a positive quota
int result = conta.prelievo(5);

        // Then: the method returns 0
assertEquals(0, result);

        // And: the saldo remains negative
assertEquals(-10, conta.getSaldo());
    }
    @Test
public void testPrelievo_saldoSufficiente_case1() {
        // Given: a positive saldo
ContoBancario conta = new ContoBancario("default", 10);

        // When: the method is called with a smaller quota than the saldo
int result = conta.prelievo(5);

        // Then: the method returns 1
assertEquals(1, result);

        // And: the saldo decreases by the quota
assertEquals(5, conta.getSaldo());
    }







}
