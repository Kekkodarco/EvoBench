package utente;

import static org.junit.Assert.*;
import banca.ContoBancario;
import listener.JacocoCoverageListener;
import org.junit.Before;
import org.junit.Rule;
import org.junit.Test;
import org.mockito.Mockito;
import listener.BaseCoverageTest;

public class UtenteTest extends BaseCoverageTest {

    private Utente utente;

    @Before
    public void setUp() {
        ContoBancario mockContoBancario = Mockito.mock(ContoBancario.class);
        utente = new Utente("John", "Doe", "123", "via mazzini", mockContoBancario);
    }

    @Test
    public void testGetName_case1() {
        // Arrange
        String expected = "John";
        Utente utente = new Utente(expected, null, null, null, null);
        // Act
        String actual = utente.getName();
        // Assert
        assertEquals(expected, actual);
    }

    @Test
    public void testGetAddress_case1() {
        // Arrange
        Utente utente = new Utente("", "", "", "", null);
        // Act
        String address = utente.getAddress(0);
        // Assert
        assertEquals("", address);
    }

    @org.openjdk.jmh.annotations.State(org.openjdk.jmh.annotations.Scope.Thread)
    public static class _Benchmark extends listener.BaseCoverageTest._Benchmark {

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testGetName_case1() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testGetName_case1, this.description("testGetName_case1"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testGetAddress_case1() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testGetAddress_case1, this.description("testGetAddress_case1"));
        }

        @java.lang.Override
        public void before() throws java.lang.Throwable {
            super.before();
            this.implementation().setUp();
        }

        private UtenteTest implementation;

        @java.lang.Override
        public void createImplementation() throws java.lang.Throwable {
            this.implementation = new UtenteTest();
        }

        @java.lang.Override
        public UtenteTest implementation() {
            return this.implementation;
        }
    }
}
