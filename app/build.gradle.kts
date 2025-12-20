import org.gradle.testing.jacoco.plugins.JacocoTaskExtension
import org.gradle.testing.jacoco.plugins.JacocoTaskExtension.Output
import org.gradle.api.file.DuplicatesStrategy

plugins {
    java
    jacoco
}

jacoco {
    toolVersion = "0.8.12"
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.mockito:mockito-core:3.10.0")

    // Serve SOLO perché i listener importano org.jacoco.core.*
    testImplementation("org.jacoco:org.jacoco.core:0.8.12")
    testImplementation("org.jacoco:org.jacoco.report:0.8.12")

    implementation("com.github.javaparser:javaparser-core:3.24.4")

    implementation("com.fasterxml.jackson.core:jackson-databind:2.15.4")
    implementation("com.fasterxml.jackson.core:jackson-core:2.15.4")
    implementation("com.fasterxml.jackson.core:jackson-annotations:2.15.4")
}

tasks.test {
    useJUnit()

    // NON eseguirli come test
    exclude("**/JacocoCoverageListener*")
    exclude("**/JacocoCoverageRunListener*")

    // Mostra System.out/System.err dei test (serve per vedere i tuoi [DEBUG])
    testLogging {
        showStandardStreams = true
        events("passed", "failed", "skipped", "standardOut", "standardError")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }

    extensions.configure(JacocoTaskExtension::class.java) {
        output = Output.TCP_SERVER
        address = "localhost"
        isJmx = true

        excludes = listOf(
            "**/test/**",
            "**/generated/**",
            "**/jmh/**"
        )
    }
}

tasks.jacocoTestReport {
    dependsOn(tasks.test)
    reports {
        xml.required.set(true)
        html.required.set(true)
    }
}

tasks.register<Jar>("fatJar") {
    archiveClassifier.set("all")
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE

    manifest {
        attributes["Main-Class"] = "ASTGenerator"
    }
    group = "build"
    archiveClassifier.set("all")

    from(sourceSets.main.get().output)

    dependsOn(configurations.runtimeClasspath)
    from({
        configurations.runtimeClasspath.get()
            .filter { it.name.endsWith("jar") }
            .map { zipTree(it) }
    })

    manifest {
        attributes["Main-Class"] = "ASTGenerator"
    }
}