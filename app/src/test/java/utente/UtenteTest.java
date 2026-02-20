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






}
