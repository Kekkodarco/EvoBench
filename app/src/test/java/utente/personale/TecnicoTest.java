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
public void testCalcolo_case1() {
        // Test the method with a positive code value, which should set the code field to that value and return without modifying any other fields.
int expectedCode = 1234;
Tecnico tecnico = new Tecnico("John", "Doe", "Teacher", 0);
tecnico.calcolo(expectedCode);
assertEquals(expectedCode, tecnico.getCode());
    }







    @Test
public void testGetSurname_case1() {
        // Arrange
String expected = "surname";
Tecnico tecnico = new Tecnico("name", expected, "profession", 123456);

        // Act
String actual = tecnico.getSurname();

        // Assert
assertEquals(expected, actual);
    }

@Test
public void testSetSurname_case1() {
        // Arrange
String expected = "new surname";
Tecnico tecnico = new Tecnico("name", "surname", "profession", 123456);

        // Act
tecnico.setSurname(expected);

        // Assert
assertEquals(expected, tecnico.getSurname());
    }







    @Test
public void testGetName_case1() {
assertEquals("John", tecnico.getName());
    }

@Test
public void testSetName_case1() {
String newName = "Jane";
tecnico.setName(newName);
assertEquals(newName, tecnico.getName());
    }






}
