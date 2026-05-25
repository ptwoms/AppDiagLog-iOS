// Backend: Spring Boot decryption + ingest + query API.
//
// Lean dependency footprint on purpose — this service handles cryptographic material
// and we keep transitive surface area small. Anything pulled in here should justify
// itself in the security review.

plugins {
    alias(libs.plugins.spring.boot)
    alias(libs.plugins.spring.dependency.management)
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.spring)
    alias(libs.plugins.kotlin.jpa)
}

group = "com.appdiaglog"
version = "0.1.0"

java {
    toolchain {
        languageVersion = JavaLanguageVersion.of(21)
    }
}

dependencies {
    // --- Spring Boot stack -------------------------------------------------
    implementation(libs.spring.boot.starter.web)
    implementation(libs.spring.boot.starter.validation)
    implementation(libs.spring.boot.starter.data.jpa)
    implementation(libs.spring.boot.starter.actuator)

    // --- Kotlin / Jackson --------------------------------------------------
    implementation(libs.kotlin.reflect)
    implementation(libs.jackson.module.kotlin)

    // --- Crypto ------------------------------------------------------------
    // BouncyCastle 1.78+ ships ML-KEM (Crystals-Kyber) inside the JCE provider.
    implementation(libs.bouncycastle.provider)
    implementation(libs.bouncycastle.pkix)

    // --- Database ----------------------------------------------------------
    // H2 for dev/CI; Postgres driver bundled so prod profile picks it up without
    // a rebuild. SQLite is loaded when `appdiaglog.storage.adapter=sqlite`.
    runtimeOnly(libs.h2)
    runtimeOnly(libs.postgresql)
    implementation(libs.sqlite.jdbc)

    // --- CSV ---------------------------------------------------------------
    implementation(libs.commons.csv)

    // --- Excel export ------------------------------------------------------
    implementation(libs.apache.poi)

    // --- Test --------------------------------------------------------------
    testImplementation(libs.spring.boot.starter.test) {
        // Vintage engine pulls JUnit 4 and a transitive Hamcrest we don't use.
        exclude(group = "org.junit.vintage")
    }
}

kotlin {
    compilerOptions {
        freeCompilerArgs.addAll("-Xjsr305=strict", "-opt-in=kotlin.RequiresOptIn")
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_21
    }
}

tasks.withType<Test> {
    useJUnitPlatform()
}
