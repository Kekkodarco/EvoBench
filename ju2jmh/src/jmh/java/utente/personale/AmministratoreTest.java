package utente.personale;

import static org.junit.Assert.*;
import listener.JacocoCoverageListener;
import org.junit.Before;
import org.junit.Rule;
import org.junit.Test;
import org.junit.runner.RunWith;

public class AmministratoreTest {

    @Test
    public void testGetName() {
        Amministratore amministratore = new Amministratore("John", "Doe", "HR");
        assertEquals("John", amministratore.getName());
    }

    @Test
    public void testGetSurname() {
        Amministratore amministratore = new Amministratore("John", "Doe", "HR");
        assertEquals("Doe", amministratore.getSurname());
    }

    @Test
    public void testGetDepartment() {
        Amministratore amministratore = new Amministratore("John", "Doe", "HR");
        assertEquals("HR", amministratore.getDepartment());
    }

    @Test
    public void testSetName() {
        Amministratore amministratore = new Amministratore("John", "Doe", "HR");
        amministratore.setName("Jane");
        assertEquals("Jane", amministratore.getName());
    }

    @Test
    public void testSetSurname() {
        Amministratore amministratore = new Amministratore("John", "Doe", "HR");
        amministratore.setSurname("Foe");
        assertEquals("Foe", amministratore.getSurname());
    }

    @Test
    public void testSetDepartment_case1() {
        // Arrange
        String name = "John";
        String surname = "Doe";
        String department = "IT";
        Amministratore amministratore = new Amministratore(name, surname, department);
        // Act
        amministratore.setDepartment(department);
        // Assert
        assertEquals("IT", amministratore.getDepartment());
    }

    @Test
    public void testSetDepartment_case2() {
        // Setup
        String name = "John";
        String surname = "Doe";
        String department = "IT";
        Amministratore amministratore = new Amministratore(name, surname, department);
        // Test
        amministratore.setDepartment("Sales");
        // Assertions
        assertEquals("Sales", amministratore.getDepartment());
    }

    @Test
    public void testSetDepartment_case3() {
        // Setup
        String name = "John";
        String surname = "Doe";
        String department = "IT";
        Amministratore amministratore = new Amministratore(name, surname, department);
        // Test
        amministratore.setDepartment(null);
        // Assertions
        assertNull(amministratore.getDepartment());
    }

    @Test
    public void testSetDepartment_case4() {
        // Setup
        String name = "John";
        String surname = "Doe";
        String department = "IT";
        Amministratore amministratore = new Amministratore(name, surname, department);
        // Test
        amministratore.setDepartment("");
        // Assertions
        assertEquals("", amministratore.getDepartment());
    }
}
