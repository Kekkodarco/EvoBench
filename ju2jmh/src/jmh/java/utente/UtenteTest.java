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
}
