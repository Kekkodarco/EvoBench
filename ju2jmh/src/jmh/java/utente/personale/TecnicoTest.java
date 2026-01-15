package utente.personale;

import static org.junit.Assert.*;
import listener.JacocoCoverageListener;
import org.junit.Before;
import org.junit.Rule;
import org.junit.Test;

public class TecnicoTest {

    @Before
    public void setUp() {
        this.tecnico = new Tecnico("John", "Doe", "Teacher", 1234);
    }

    private Tecnico tecnico;

    @Test
    public void testGetName() {
        Tecnico tecnico = new Tecnico("John", "Doe", "Engineer", 1);
        assertEquals("John", tecnico.getName());
    }

    @Test
    public void testGetSurname() {
        Tecnico tecnico = new Tecnico("John", "Doe", "Engineer", 1);
        assertEquals("Doe", tecnico.getSurname());
    }

    @Test
    public void testSetSurname() {
        Tecnico tecnico = new Tecnico("John", "Doe", "Engineer", 1);
        tecnico.setSurname("Smith");
        assertEquals("Smith", tecnico.getSurname());
    }

    @Test
    public void testSetProfession() {
        Tecnico tecnico = new Tecnico("John", "Doe", "Engineer", 1);
        tecnico.setProfession("Technician");
        assertEquals("Technician", tecnico.getProfession());
    }

    @Test
    public void testSetCode() {
        Tecnico tecnico = new Tecnico("John", "Doe", "Engineer", 1);
        tecnico.setCode(2);
        assertEquals(2, tecnico.getCode());
    }

    @Test
    public void testSetName() {
        Tecnico tecnico = new Tecnico("John", "Doe", "Engineer", 1);
        tecnico.setName("Jane");
        assertEquals("Jane", tecnico.getName());
    }

    @Test
    public void testGetProfession_case1() {
        // Tests the method getProfession with a sufficient balance
        Tecnico tecnico = new Tecnico("John", "Doe", "Software Engineer", 123456);
        String expected = "Software Engineer";
        assertEquals(expected, tecnico.getProfession());
    }

    @Test
    public void testGetProfession_case2() {
        // Given a new Tecnico object with a profession set to "prof"
        Tecnico tecnico = new Tecnico("name", "surname", "prof", 123);
        assertEquals("prof", tecnico.getProfession());
    }

    @Test
    public void testGetProfession_case3() {
        // Arrange
        String expected = "Teacher";
        Tecnico tecnico = new Tecnico("John", "Doe", "Teacher", 123456);
        // Act
        String actual = tecnico.getProfession();
        // Assert
        assertEquals(expected, actual);
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
        public void benchmark_testSetSurname() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testSetSurname, this.description("testSetSurname"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testSetProfession() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testSetProfession, this.description("testSetProfession"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testSetCode() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testSetCode, this.description("testSetCode"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testSetName() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testSetName, this.description("testSetName"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testGetProfession_case1() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testGetProfession_case1, this.description("testGetProfession_case1"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testGetProfession_case2() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testGetProfession_case2, this.description("testGetProfession_case2"));
        }

        @org.openjdk.jmh.annotations.Benchmark
        public void benchmark_testGetProfession_case3() throws java.lang.Throwable {
            this.createImplementation();
            this.runBenchmark(this.implementation()::testGetProfession_case3, this.description("testGetProfession_case3"));
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
