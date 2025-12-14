package banca;

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
        Assert.assertEquals(1, conto.prelievo(quota));
    }
}