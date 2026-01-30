package utente.personale;

import static org.junit.Assert.*;
import listener.BaseCoverageTest;
import listener.JacocoCoverageListener;
import org.junit.Before;
import org.junit.Rule;
import org.junit.Test;
import org.junit.runner.RunWith;

public class AmministratoreTest extends BaseCoverageTest {

    @Test
    public void testGetName() {
        Amministratore amministratore = new Amministratore("John", "Doe", "HR");
        assertEquals("John", amministratore.getName());
    }

    @Test
    public void testGetSurname_case1() {
        // Arrange
        String expected = "Bianchi";
        Amministratore amministratore = new Amministratore("Mario", expected, "IT");
        // Act
        String actual = amministratore.getSurname();
        // Assert
        assertEquals(expected, actual);
    }

    @org.openjdk.jmh.annotations.State(org.openjdk.jmh.annotations.Scope.Thread)
    public static class _Benchmark extends listener.BaseCoverageTest._Benchmark {

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testGetName() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testGetName, this.description("testGetName"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testGetSurname_case1() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testGetSurname_case1, this.description("testGetSurname_case1"));
        }

        private AmministratoreTest implementation;

        @java.lang.Override
        public void createImplementation() throws java.lang.Throwable {
            this.implementation = new AmministratoreTest();
        }

        @java.lang.Override
        public AmministratoreTest implementation() {
            return this.implementation;
        }
    }
}
