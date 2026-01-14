package utente;

import static org.junit.Assert.*;
import banca.ContoBancario;
import listener.JacocoCoverageListener;
import org.junit.Before;
import org.junit.Rule;
import org.junit.Test;
import org.mockito.Mockito;

public class UtenteTest {

    private Utente utente;

    @Before
    public void setUp() {
        ContoBancario mockContoBancario = Mockito.mock(ContoBancario.class);
        utente = new Utente("John", "Doe", "123", "via mazzini", mockContoBancario);
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
    public void testGetName_case1() {
        // Arrange
        String name = "John";
        String surname = "Doe";
        String telephone = "+39 1234567890";
        String address = "Via Roma, 10";
        ContoBancario contoBancario = new ContoBancario();
        Utente utente = new Utente(name, surname, telephone, address, contoBancario);
        // Act
        String result = utente.getName();
        // Assert
        assertEquals("John", result);
    }

    @Test
    public void testSetSurname_case1() {
        // Arrange
        String name = "John";
        String surname = "Doe";
        String telephone = "+39 1234567890";
        String address = "Via Roma, 10";
        ContoBancario contoBancario = new ContoBancario();
        Utente utente = new Utente(name, surname, telephone, address, contoBancario);
        // Act
        utente.setSurname("Smith");
        // Assert
        assertEquals("Smith", utente.getSurname());
    }

    @org.openjdk.jmh.annotations.State(org.openjdk.jmh.annotations.Scope.Thread)
    public static class _Benchmark extends se.chalmers.ju2jmh.api.JU2JmhBenchmark {

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
        public void benchmark_testGetName_case1() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testGetName_case1, this.description("testGetName_case1"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testSetSurname_case1() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testSetSurname_case1, this.description("testSetSurname_case1"));
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
