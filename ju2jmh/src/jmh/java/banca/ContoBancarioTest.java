package banca;

import static org.junit.Assert.*;
import org.junit.Assert;
import org.junit.Test;
import org.junit.Before;

public class ContoBancarioTest {

    @Before
    public void setUp() {
        contobancario = new ContoBancario();
    }

    private ContoBancario contobancario;

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

    @Test
    public void prelievo_sufficientBalance_case1() {
        // Arrange
        int quota = 100;
        int saldoIniziale = 200;
        ContoBancario conto = new ContoBancario("id", saldoIniziale);
        // Act
        int result = conto.prelievo(quota);
        // Assert
        // prelievo() returns 1 if successful
        assertEquals(1, result);
        // saldo decreased by quota
        assertEquals(saldoIniziale - quota, conto.getSaldo());
    }

    @Test
    public void prelievo_insufficientBalance_case1() {
        // Arrange
        int quota = 100;
        int saldoIniziale = 50;
        ContoBancario conto = new ContoBancario("id", saldoIniziale);
        // Act
        int result = conto.prelievo(quota);
        // Assert
        // prelievo() returns 0 if unsuccessful
        assertEquals(0, result);
        // saldo remains the same
        assertEquals(saldoIniziale, conto.getSaldo());
    }

    @Test
    public void testPrelievoSuccess_case1() {
        // Testing the successful prelievo with a sufficient balance
        int quota = 10;
        int saldoIniziale = 20;
        contobancario.setSaldo(saldoIniziale);
        assertEquals("Prelievo quota: " + quota, 1, contobancario.prelievo(quota));
        assertEquals("Saldo after prelievo", saldoIniziale - quota, contobancario.getSaldo());
    }

    @Test
    public void testPrelievoFailure_case1() {
        // Testing the unsuccessful prelievo with an insufficient balance
        int quota = 20;
        int saldoIniziale = 10;
        contobancario.setSaldo(saldoIniziale);
        assertEquals("Prelievo quota: " + quota, 0, contobancario.prelievo(quota));
        assertEquals("Saldo after prelievo", saldoIniziale, contobancario.getSaldo());
    }

    @Test
    public void testPrelievo_case1() {
        // Test prelievo with sufficient balance
        ContoBancario c = new ContoBancario("1234", 100);
        int quota = 50;
        assertEquals(1, c.prelievo(quota));
        assertEquals(50, c.getSaldo());
    }

    @Test
    public void testPrelievoWithInsufficientBalance_case1() {
        // Test prelievo with insufficient balance
        ContoBancario c = new ContoBancario("1234", 50);
        int quota = 100;
        assertEquals(0, c.prelievo(quota));
        assertEquals(50, c.getSaldo());
    }

    @org.openjdk.jmh.annotations.State(org.openjdk.jmh.annotations.Scope.Thread)
    public static class _Benchmark extends se.chalmers.ju2jmh.api.JU2JmhBenchmark {

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_prelievo_saldoNegativo() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::prelievo_saldoNegativo, this.description("prelievo_saldoNegativo"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_prelievo_saldoSufficiente() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::prelievo_saldoSufficiente, this.description("prelievo_saldoSufficiente"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_prelievo_saldoNegativoSufficiente() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::prelievo_saldoNegativoSufficiente, this.description("prelievo_saldoNegativoSufficiente"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testPrelievo_insufficientBalance_case1() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testPrelievo_insufficientBalance_case1, this.description("testPrelievo_insufficientBalance_case1"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testPrelievo_sufficientBalance_case1() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testPrelievo_sufficientBalance_case1, this.description("testPrelievo_sufficientBalance_case1"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_prelievo_sufficientBalance_case1() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::prelievo_sufficientBalance_case1, this.description("prelievo_sufficientBalance_case1"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_prelievo_insufficientBalance_case1() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::prelievo_insufficientBalance_case1, this.description("prelievo_insufficientBalance_case1"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testPrelievoSuccess_case1() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testPrelievoSuccess_case1, this.description("testPrelievoSuccess_case1"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testPrelievoFailure_case1() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testPrelievoFailure_case1, this.description("testPrelievoFailure_case1"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testPrelievo_case1() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testPrelievo_case1, this.description("testPrelievo_case1"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testPrelievoWithInsufficientBalance_case1() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testPrelievoWithInsufficientBalance_case1, this.description("testPrelievoWithInsufficientBalance_case1"));
        }

        @java.lang.Override
        public void before() throws java.lang.Throwable {
            super.before();
            this.implementation().setUp();
        }

        private ContoBancarioTest implementation;

        @java.lang.Override
        public void createImplementation() throws java.lang.Throwable {
            this.implementation = new ContoBancarioTest();
        }

        @java.lang.Override
        public ContoBancarioTest implementation() {
            return this.implementation;
        }
    }
}
