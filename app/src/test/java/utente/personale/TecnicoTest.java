package utente.personale;

import static org.junit.Assert.*;





























import listener.JacocoCoverageListener;
import org.junit.Before;
import org.junit.Rule;
import org.junit.Test;
import listener.BaseCoverageTest;

public class TecnicoTest  extends BaseCoverageTest {

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







}
