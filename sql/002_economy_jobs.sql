USE darkrp;

ALTER TABLE drp_players
    ADD COLUMN money BIGINT UNSIGNED NOT NULL DEFAULT 500 AFTER last_name,
    ADD COLUMN job_key VARCHAR(24) NOT NULL DEFAULT 'citizen' AFTER money;

UPDATE drp_players SET schema_version = 2 WHERE schema_version < 2;
INSERT IGNORE INTO drp_schema_migrations (version) VALUES (2);
