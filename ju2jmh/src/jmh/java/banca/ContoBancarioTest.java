package banca;

import org.junit.Before;
import org.junit.Rule;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.junit.runners.JUnit4;
import utente.Utente;
import static org.junit.Assert.*;

public class ContoBancarioTest {

    @Test
    public void testVersamento() {
        ContoBancario conto = new ContoBancario("123", 100);
        conto.versamento(50);
        assertEquals(150, conto.getSaldo());
    }

    @Test
    public void testPrelievo_SufficienteSaldo() {
        ContoBancario conto = new ContoBancario("123", 100);
        int result = conto.prelievo(50);
        assertEquals(1, result);
        assertEquals(50, conto.getSaldo());
    }

    @Test
    public void testPrelievo_InsufficienteSaldo() {
        ContoBancario conto = new ContoBancario("123", 100);
        int result = conto.prelievo(150);
        assertEquals(0, result);
        assertEquals(100, conto.getSaldo());
    }

    @Test
    public void testGetId() {
        ContoBancario conto = new ContoBancario("123", 100);
        assertEquals("123", conto.getId());
    }

    @Test
    public void testSetId() {
        ContoBancario conto = new ContoBancario("123", 100);
        conto.setId("456");
        assertEquals("456", conto.getId());
    }

    @Test
    public void testGetSaldo() {
        ContoBancario conto = new ContoBancario("123", 100);
        assertEquals(100, conto.getSaldo());
    }

    @Test
    public void testSetSaldo() {
        ContoBancario conto = new ContoBancario("123", 100);
        conto.setSaldo(200);
        assertEquals(200, conto.getSaldo());
    }

    @Test
    public void testSetSaldo2() {
        ContoBancario conto = new ContoBancario("123", 100);
        conto.setSaldo2(200);
        assertEquals(200, conto.getSaldo());
    }

    @org.openjdk.jmh.annotations.State(org.openjdk.jmh.annotations.Scope.Thread)
    public static class _Benchmark extends se.chalmers.ju2jmh.api.JU2JmhBenchmark {

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testVersamento() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testVersamento, this.description("testVersamento"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testPrelievo_SufficienteSaldo() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testPrelievo_SufficienteSaldo, this.description("testPrelievo_SufficienteSaldo"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testPrelievo_InsufficienteSaldo() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testPrelievo_InsufficienteSaldo, this.description("testPrelievo_InsufficienteSaldo"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testGetId() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testGetId, this.description("testGetId"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testSetId() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testSetId, this.description("testSetId"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testGetSaldo() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testGetSaldo, this.description("testGetSaldo"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testSetSaldo() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testSetSaldo, this.description("testSetSaldo"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testSetSaldo2() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testSetSaldo2, this.description("testSetSaldo2"));
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
