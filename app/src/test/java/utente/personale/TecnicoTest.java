package utente.personale;

import listener.JacocoCoverageListener;
import org.junit.Before;
import org.junit.Rule;
import org.junit.Test;
import static org.junit.Assert.assertEquals;

public class TecnicoTest {

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
    public void testGetProfession() {
        Tecnico tecnico = new Tecnico("John", "Doe", "Engineer", 1);
        assertEquals("Engineer", tecnico.getProfession());
    }

    @Test
    public void testGetCode() {
        Tecnico tecnico = new Tecnico("John", "Doe", "Engineer", 1);
        assertEquals(1, tecnico.getCode());
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

}
