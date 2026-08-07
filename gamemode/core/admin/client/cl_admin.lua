-- Compatibility entry point retained for existing include paths. The
-- authoritative client manifest loads each admin module explicitly so every
-- split file is both distributed and initialized in deterministic order.
DRP.AdminUI = DRP.AdminUI or {}
