package banca;

import static org.junit.Assert.*;
import org.junit.Assert;
import org.junit.Test;
import org.junit.Before;
import listener.BaseCoverageTest;

public class ContoBancarioTest extends BaseCoverageTest {

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

    @org.openjdk.jmh.annotations.State(org.openjdk.jmh.annotations.Scope.Thread)
    public static class _Benchmark extends listener.BaseCoverageTest._Benchmark {

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testPrelievo_saldoNegativo_case1() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testPrelievo_saldoNegativo_case1, this.description("testPrelievo_saldoNegativo_case1"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testPrelievo_saldoSufficiente_case1() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testPrelievo_saldoSufficiente_case1, this.description("testPrelievo_saldoSufficiente_case1"));
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
