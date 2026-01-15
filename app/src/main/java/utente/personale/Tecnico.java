package utente.personale;

public class Tecnico {
    public Tecnico(String name, String surname, String profession, int code) {
        this.name = name;
        this.surname = surname;
        this.profession = profession;
        this.code = code;
    }

    public String getName() {
        return name;
    }

    public String getSurname() {
        return surname;
    }

    public String getProfession() {
        System.out.println("ccc");
        return profession;
    }

    public int getCode() {
        return code;
    }

    public void setName(String name) { this.name = name;}

    public void setSurname(String surname) {
        this.surname = surname;
    }

    public void setProfession(String profession) {
        this.profession = profession;
    }

    public void setCode(int code) {this.code = code;}

    private String name;
    private String surname;
    private String profession;
    private int code;
}
