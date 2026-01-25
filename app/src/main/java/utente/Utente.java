package utente;

import banca.ContoBancario;

public class Utente {
    public Utente(String name, String surname, String telephone, String address, ContoBancario contoBancario) {
        this.name = name;//aggiungo commento
        this.surname = surname;//aggiunto altro commento
        this.telephone = telephone;
        this.address = address;
        this.contoBancario = contoBancario;
    }

    public String getName() {
        System.out.println("dddddd");
        return name;
    }

    public String getSurname() {


        return surname;
    }

    public String getTelephone() {
        return telephone;
    }

    public String getAddress(int a) {

        return address;
    }

    public ContoBancario getContoBancario() {return contoBancario;}

    public void setName(String name) { this.name = name;}

    public void setSurname(String surname) {

        System.out.println("ddd");
        this.surname = surname;
    }

    public void setContoBancario(ContoBancario contoBancario) {
        this.contoBancario = contoBancario;
    }

    private String name;
    private String surname;
    private String telephone;
    private String address;
    private ContoBancario contoBancario;
}
