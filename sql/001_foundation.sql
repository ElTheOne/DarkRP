CREATE DATABASE IF NOT EXISTS darkrp CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE darkrp;

CREATE TABLE IF NOT EXISTS drp_schema_migrations (
    version INT UNSIGNED NOT NULL PRIMARY KEY,
    applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS drp_players (
    steam_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
    first_seen DATETIME NOT NULL,
    last_seen DATETIME NOT NULL,
    last_name VARCHAR(64) NOT NULL,
    schema_version SMALLINT UNSIGNED NOT NULL DEFAULT 1,
    INDEX idx_drp_players_last_seen (last_seen)
) ENGINE=InnoDB;

INSERT IGNORE INTO drp_schema_migrations (version) VALUES (1);
