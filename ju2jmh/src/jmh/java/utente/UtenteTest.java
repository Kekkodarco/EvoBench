package utente;

import banca.ContoBancario;
import listener.JacocoCoverageListener;
import org.junit.Before;
import org.junit.Rule;
import org.junit.Test;
import org.mockito.Mockito;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;

public class UtenteTest {

    private Utente utente;

    @Before
    public void setUp() {
        ContoBancario mockContoBancario = Mockito.mock(ContoBancario.class);
        utente = new Utente("John", "Doe", "123", "via mazzini", mockContoBancario);
    }

    @Test
    public void testGetName() {
        assertEquals("John", utente.getName());
    }

    @Test
    public void testGetSurname() {
        assertEquals("Doe", utente.getSurname());
    }

    @Test
    public void testGetTelephone() {
        assertEquals("123", utente.getTelephone());
    }

    @Test
    public void testGetAddress() {
        assertEquals("via mazzini", utente.getAddress(1));
    }

    @Test
    public void testGetContoBancario() {
        assertNotNull(utente.getContoBancario());
    }

    @Test
    public void testSetName() {
        utente.setName("Smith");
        assertEquals("Smith", utente.getName());
    }

    @Test
    public void testSetSurname() {
        utente.setSurname("Smith");
        assertEquals("Smith", utente.getSurname());
    }

    @Test
    public void testSetContoBancario() {
        ContoBancario nuovoConto = Mockito.mock(ContoBancario.class);
        utente.setContoBancario(nuovoConto);
        assertEquals(nuovoConto, utente.getContoBancario());
    }

    @org.openjdk.jmh.annotations.State(org.openjdk.jmh.annotations.Scope.Thread)
    public static class _Benchmark extends se.chalmers.ju2jmh.api.JU2JmhBenchmark {

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testGetName() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testGetName, this.description("testGetName"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testGetSurname() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testGetSurname, this.description("testGetSurname"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testGetTelephone() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testGetTelephone, this.description("testGetTelephone"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testGetAddress() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testGetAddress, this.description("testGetAddress"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testGetContoBancario() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testGetContoBancario, this.description("testGetContoBancario"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testSetSurname() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testSetSurname, this.description("testSetSurname"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testSetContoBancario() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testSetContoBancario, this.description("testSetContoBancario"));
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
