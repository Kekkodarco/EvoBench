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
        String expected = "John Doe";
        Utente utente = new Utente(expected, "Doe", "555-1234", "123 Main St.", null);
        // Act
        String actual = utente.getName();
        // Assert
        assertEquals("getName() should return the name", expected, actual);
    }
}
