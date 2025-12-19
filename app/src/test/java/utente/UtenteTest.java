package utente;

import banca.ContoBancario;
import listener.JacocoCoverageListener;
import org.junit.Before;
import org.junit.Rule;
import org.junit.Test;
import org.mockito.Mockito;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;

public class UtenteTest {

    private Utente utente;

    @Before
    public void setUp() {
        ContoBancario mockContoBancario = Mockito.mock(ContoBancario.class);
        utente = new Utente("John", "Doe", "123", "via mazzini", mockContoBancario);
    }

    @Test
    public void testGetName() {
        assertEquals("John", utente.getName());
    }

    @Test
    public void testGetSurname() {
        assertEquals("Doe", utente.getSurname());
    }

    @Test
    public void testGetTelephone() {assertEquals("123", utente.getTelephone());}

    @Test
    public void testGetAddress() {assertEquals("via mazzini", utente.getAddress(1));}

    @Test
    public void testGetContoBancario() {
        assertNotNull(utente.getContoBancario());
    }

    @Test
    public void testSetName() {
        utente.setName("Smith");
        assertEquals("Smith", utente.getName());
    }

    @Test
    public void testSetSurname() {
        utente.setSurname("Smith");
        assertEquals("Smith", utente.getSurname());
    }

    @Test
    public void testSetContoBancario() {
        ContoBancario nuovoConto = Mockito.mock(ContoBancario.class);
        utente.setContoBancario(nuovoConto);
        System.out.println("modifica");
        assertEquals(nuovoConto, utente.getContoBancario());
    }
}
