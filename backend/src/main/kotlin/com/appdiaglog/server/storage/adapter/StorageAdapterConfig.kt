package com.appdiaglog.server.storage.adapter

import com.appdiaglog.server.storage.EventRepository
import com.appdiaglog.server.storage.SessionRepository
import com.appdiaglog.server.storage.adapter.csv.CsvSessionStore
import com.appdiaglog.server.storage.adapter.jpa.JpaSessionStore
import com.appdiaglog.server.storage.adapter.sqlite.SqliteEncryptedSessionStore
import org.slf4j.LoggerFactory
import org.springframework.beans.factory.annotation.Value
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Configuration
import java.nio.file.Path

/**
 * Picks which [SessionStore] is active based on `appdiaglog.storage.adapter`.
 *
 * Values:
 *  - `jpa` (default): existing JPA path. Postgres in prod, H2 in dev.
 *  - `sqlite`: standalone encrypted SQLite file. Needs
 *      `appdiaglog.storage.sqlite.file` (absolute path) and
 *      `appdiaglog.storage.sqlite.master-key` (base64, 32 bytes).
 *  - `csv`: flat-file CSV adapter. Needs
 *      `appdiaglog.storage.csv.dir` (directory will be created on boot).
 *
 * The JPA stack is auto-configured by Spring Boot regardless of which adapter
 * is active — keeping its repositories on the classpath is harmless and lets
 * teams flip back to JPA without redeploying.
 */
@Configuration
class StorageAdapterConfig {

    private val log = LoggerFactory.getLogger(javaClass)

    @Bean
    @ConditionalOnProperty(
        prefix = "appdiaglog.storage",
        name = ["adapter"],
        havingValue = "jpa",
        matchIfMissing = true,
    )
    fun jpaSessionStore(
        sessions: SessionRepository,
        events: EventRepository,
    ): SessionStore {
        log.info("Storage adapter: JPA")
        return JpaSessionStore(sessions, events)
    }

    @Bean
    @ConditionalOnProperty(prefix = "appdiaglog.storage", name = ["adapter"], havingValue = "sqlite")
    fun sqliteSessionStore(
        @Value("\${appdiaglog.storage.sqlite.file}") file: String,
        @Value("\${appdiaglog.storage.sqlite.master-key}") masterKey: String,
    ): SessionStore {
        log.info("Storage adapter: SQLite encrypted ({})", file)
        return SqliteEncryptedSessionStore(
            jdbcUrl = "jdbc:sqlite:$file",
            masterKeyBase64 = masterKey,
        )
    }

    @Bean
    @ConditionalOnProperty(prefix = "appdiaglog.storage", name = ["adapter"], havingValue = "csv")
    fun csvSessionStore(
        @Value("\${appdiaglog.storage.csv.dir}") dir: String,
    ): SessionStore {
        log.info("Storage adapter: CSV ({})", dir)
        return CsvSessionStore(Path.of(dir))
    }
}
