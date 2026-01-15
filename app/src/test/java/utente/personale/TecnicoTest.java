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
Tecnico tecnico = new Tecnico("John", "Doe", "Engineer",1);
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





}
