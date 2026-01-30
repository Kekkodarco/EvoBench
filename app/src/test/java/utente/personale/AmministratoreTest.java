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







}
