package com.appdiaglog.server

import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.bouncycastle.pqc.jcajce.provider.BouncyCastlePQCProvider
import org.springframework.boot.SpringApplication
import org.springframework.boot.autoconfigure.SpringBootApplication
import java.security.SecureRandom
import java.security.Security

/**
 * Spring Boot entry point. Registers the BouncyCastle JCE providers exactly once
 * at startup so [com.appdiaglog.server.decryption.CryptoOps] can resolve
 * "AES/GCM/NoPadding" via JDK and "KYBER" / "AESWRAPPAD" via BC.
 *
 * Provider registration is idempotent — if the host already has BC installed
 * (e.g. an FIPS environment), we don't double-register.
 *
 * If the DIAGNOSTICLOG_INGEST_TOKEN environment variable is not set, a fresh
 * 256-bit token is generated for this server session and printed to stdout so
 * that the operator (or MCP client config) can copy it immediately.
 */
@SpringBootApplication
class AppDiagLogServerApplication

fun main(args: Array<String>) {
    if (Security.getProvider(BouncyCastleProvider.PROVIDER_NAME) == null) {
        Security.addProvider(BouncyCastleProvider())
    }
    if (Security.getProvider(BouncyCastlePQCProvider.PROVIDER_NAME) == null) {
        Security.addProvider(BouncyCastlePQCProvider())
    }

    // If the operator has not pinned a token via the environment variable,
    // generate a fresh one for this session and expose it through the system
    // property so that Spring's placeholder resolution picks it up via
    //   appdiaglog.ingest-token: ${DIAGNOSTICLOG_INGEST_TOKEN:dev-only-replace-me}
    if (System.getenv("DIAGNOSTICLOG_INGEST_TOKEN").isNullOrBlank()) {
        val token = generateSessionToken()
        System.setProperty("DIAGNOSTICLOG_INGEST_TOKEN", token)
        printTokenBanner(token)
    }

    SpringApplication.run(AppDiagLogServerApplication::class.java, *args)
}

/** Generates a cryptographically random 256-bit token encoded as a 64-char hex string. */
private val secureRandom = SecureRandom()

private fun generateSessionToken(): String {
    val bytes = ByteArray(32)
    secureRandom.nextBytes(bytes)
    return bytes.joinToString("") { "%02x".format(it) }
}

private fun printTokenBanner(token: String) {
    val border = "=".repeat(64)
    println(border)
    println("  AppDiagLog — session token (generated, valid until restart)")
    println()
    println("  $token")
    println()
    println("  Set this as the Authorization header on every request:")
    println("    Authorization: Bearer $token")
    println()
    println("  To use a fixed token instead, set the environment variable:")
    println("    DIAGNOSTICLOG_INGEST_TOKEN=<your-token>")
    println(border)
}
