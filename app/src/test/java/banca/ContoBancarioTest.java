package banca;

import static org.junit.Assert.*;

import org.junit.Assert;
import org.junit.Test;

public class ContoBancarioTest {
    @Test
public void prelievo_saldoNegativo() {
        // Test case: prelievo from a negative balance
ContoBancario conto = new ContoBancario("1234", -10);
int quota = 5;
Assert.assertEquals(0, conto.prelievo(quota));
    }

    @Test
public void prelievo_saldoSufficiente() {
        // Test case: prelievo from a sufficient balance
ContoBancario conto = new ContoBancario("1234", 10);
int quota = 5;
Assert.assertEquals(1, conto.prelievo(quota));
    }

    @Test
public void prelievo_saldoNegativoSufficiente() {
        // Test case: prelievo from a negative balance that is sufficient to cover the quota
ContoBancario conto = new ContoBancario("1234", -5);
int quota = 5;
Assert.assertEquals(0, conto.prelievo(quota));
    }

    @Test
public void testPrelievo_insufficientBalance_case1() {
        // Given a new account with initial balance 0 and a quota of 100
ContoBancario account = new ContoBancario("default", 0);
int quota = 100;

        // When prelievo is called with a quota greater than the current balance
int result = account.prelievo(quota);

        // Then the method returns 0 and the balance remains unchanged (0)
assertEquals(0, result);
assertEquals(0, account.getSaldo());
    }
    @Test
public void testPrelievo_sufficientBalance_case1() {
        // Given a new account with initial balance 100 and a quota of 50
ContoBancario account = new ContoBancario("default", 100);
int quota = 50;

        // When prelievo is called with a quota less than the current balance
int result = account.prelievo(quota);

        // Then the method returns 1 and the balance decreases by the quota amount (50)
assertEquals(1, result);
assertEquals(50, account.getSaldo());
    }





}
