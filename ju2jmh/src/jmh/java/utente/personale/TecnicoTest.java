package utente.personale;

import static org.junit.Assert.*;
import listener.JacocoCoverageListener;
import org.junit.Before;
import org.junit.Rule;
import org.junit.Test;
import listener.BaseCoverageTest;

public class TecnicoTest extends BaseCoverageTest {

    @Before
    public void setUp() {
        this.tecnico = new Tecnico("John", "Doe", "Teacher", 1234);
    }

    private Tecnico tecnico;

    @Test
    public void testGetSurname_case1() {
        // Arrange
        String name = "John";
        String surname = "Doe";
        String profession = "Software Engineer";
        int code = 123456;
        Tecnico tecnico = new Tecnico(name, surname, profession, code);
        // Act
        String actualSurname = tecnico.getSurname();
        // Assert
        assertEquals("Doe", actualSurname);
    }

    @org.openjdk.jmh.annotations.State(org.openjdk.jmh.annotations.Scope.Thread)
    public static class _Benchmark extends listener.BaseCoverageTest._Benchmark {

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testGetSurname_case1() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testGetSurname_case1, this.description("testGetSurname_case1"));
        }

        @java.lang.Override
        public void before() throws java.lang.Throwable {
            super.before();
            this.implementation().setUp();
        }

        private TecnicoTest implementation;

        @java.lang.Override
        public void createImplementation() throws java.lang.Throwable {
            this.implementation = new TecnicoTest();
        }

        @java.lang.Override
        public TecnicoTest implementation() {
            return this.implementation;
        }
    }
}
