plugins {
    java
    id("me.champeau.jmh") version "0.7.3"
}

dependencies {
    val jUnit4Version: String by rootProject.extra

    testImplementation("junit", "junit", jUnit4Version)
    jmh("junit", "junit", jUnit4Version)

    implementation(project(":app"))

    testImplementation("org.mockito:mockito-core:3.10.0")

    // JaCoCo coerente con app
    testImplementation("org.jacoco:org.jacoco.core:0.8.12")
    testImplementation("org.jacoco:org.jacoco.report:0.8.12")

    // Jackson: evita 2.13.x (vulnerabilità) e allinea a 2.15.4
    testImplementation("com.fasterxml.jackson.core:jackson-databind:2.15.4")
    testImplementation("com.fasterxml.jackson.core:jackson-core:2.15.4")
    testImplementation("com.fasterxml.jackson.core:jackson-annotations:2.15.4")

    jmh(files("../libs/jmh-core-1.37-all.jar"))
    jmhImplementation(files("../libs/jmh-core-1.37-all.jar"))
}

configurations.all {
    exclude(group = "org.openjdk.jmh", module = "jmh-core")
}

/*tasks.jmh {
    finalizedBy(tasks.jacocoTestReport)  // Genera il report dopo aver eseguito i benchmark
}

tasks.jacocoTestReport {
    dependsOn(tasks.jmh)  // Assicurati che i benchmark siano eseguiti prima di generare il report
    reports {
        xml.required.set(true)
        html.required.set(true)
    }
}*/
