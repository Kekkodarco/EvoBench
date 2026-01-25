package utente.personale;

public class Amministratore {
    public Amministratore(String name, String surname, String department) {
        this.name = name;
        this.surname = surname;
        this.department = department;
    }

    public String getName() {return this.name;}

    public String getSurname() {

        System.out.println("ddd");
        return surname;
    }

    public String getDepartment() {return department;}

    public void setName(String name) {this.name = name;}

    public void setSurname(String surname) {
        this.surname = surname;
    }

    public void setDepartment(String department) {this.department = department;}

    private String name;
    private String surname;
    private String department;
}
