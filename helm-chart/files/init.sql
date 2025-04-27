-- ✅ Connect to the default `postgres` database
\c postgres

-- ✅ Enable SSL/TLS for connection security
--ALTER SYSTEM SET ssl = on;
--ALTER SYSTEM SET ssl_cert_file = '/etc/postgresql/ssl/postgres-certs/server.crt';  -- Adjust path as needed
--ALTER SYSTEM SET ssl_key_file = '/etc/postgresql/ssl/postgres-certs/server.key';   -- Adjust path as needed

-- ✅ Create two separate databases
CREATE DATABASE admin_db OWNER admin;
--CREATE DATABASE chat_db OWNER admin;

-- ====================================
-- Switch to `admin_db` for Admin Setup
-- ====================================
\c admin_db

-- Enable cryptographic extensions (Needed for functions)
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Create admin schema
CREATE SCHEMA IF NOT EXISTS admin;
CREATE SCHEMA IF NOT EXISTS chat;

-- Secure the schemas
REVOKE ALL ON SCHEMA admin FROM PUBLIC;
GRANT USAGE ON SCHEMA admin TO admin;

-- =============================
-- 2. KEY MANAGEMENT - SIMPLIFIED FOR EPHEMERAL SYSTEMS
-- =============================

-- Create a simple key storage table
CREATE TABLE IF NOT EXISTS admin.encryption_keys (
    key_name TEXT PRIMARY KEY,
    key_value TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT now(),
    updated_at TIMESTAMP DEFAULT now()
);

-- Secure the keys table
REVOKE ALL ON admin.encryption_keys FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE ON admin.encryption_keys TO admin;

-- Function to generate a data key
CREATE OR REPLACE FUNCTION admin.generate_key() RETURNS TEXT AS $$
BEGIN
    -- Generate a random 32-byte (256-bit) key
    RETURN encode(gen_random_bytes(32), 'hex');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =============================
-- 3. ENCRYPTION/DECRYPTION FUNCTIONS
-- =============================

-- Function to encrypt data - simplified for ephemeral systems
CREATE OR REPLACE FUNCTION admin.encrypt_data(p_data TEXT, p_key_name TEXT) RETURNS BYTEA AS $$
DECLARE
    encryption_key BYTEA;
    hmac_key BYTEA;
    iv BYTEA;
    encrypted BYTEA;
    hmac BYTEA;
BEGIN
    -- Get the encryption key
    SELECT decode(key_value, 'hex') INTO encryption_key 
    FROM admin.encryption_keys 
    WHERE admin.encryption_keys.key_name = p_key_name || '_key' AND key_type = 'encryption';
    
    -- Get the HMAC key
    SELECT decode(key_value, 'hex') INTO hmac_key 
    FROM admin.encryption_keys 
    WHERE admin.encryption_keys.key_name = p_key_name || '_hmac_key' AND key_type = 'hmac';
    
    IF encryption_key IS NULL OR hmac_key IS NULL THEN
        RAISE EXCEPTION 'Encryption or HMAC key % not found', p_key_name;
    END IF;
    
    -- Generate random IV for this encryption
    iv := gen_random_bytes(16);
    
    -- Encrypt the data
    encrypted := encrypt_iv(convert_to(p_data, 'UTF8'), encryption_key, iv, 'aes-cbc');
    
    -- Generate HMAC for integrity
    hmac := hmac(iv || encrypted, hmac_key, 'sha256');
    
    -- Return HMAC + IV + encrypted data
    RETURN hmac || iv || encrypted;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to decrypt data - simplified for ephemeral systems
CREATE OR REPLACE FUNCTION admin.decrypt_data(p_encrypted_data BYTEA, p_key_name TEXT) RETURNS TEXT AS $$
DECLARE
    encryption_key BYTEA;
    hmac_key BYTEA;
    stored_hmac BYTEA;
    calculated_hmac BYTEA;
    iv BYTEA;
    data BYTEA;
    content BYTEA;
BEGIN
    -- Handle NULL input gracefully
    IF p_encrypted_data IS NULL THEN
        RETURN NULL;
    END IF;
    
    -- Get the encryption key
    SELECT decode(key_value, 'hex') INTO encryption_key 
    FROM admin.encryption_keys 
    WHERE admin.encryption_keys.key_name = p_key_name || '_key' AND key_type = 'encryption';
    
    -- Get the HMAC key
    SELECT decode(key_value, 'hex') INTO hmac_key 
    FROM admin.encryption_keys 
    WHERE admin.encryption_keys.key_name = p_key_name || '_hmac_key' AND key_type = 'hmac';
    
    IF encryption_key IS NULL OR hmac_key IS NULL THEN
        RAISE EXCEPTION 'Encryption or HMAC key % not found', p_key_name;
    END IF;
    
    -- Extract HMAC (first 32 bytes)
    stored_hmac := substring(p_encrypted_data from 1 for 32);
    
    -- Extract IV and ciphertext (everything after HMAC)
    content := substring(p_encrypted_data from 33);
    
    -- Calculate HMAC
    calculated_hmac := hmac(content, hmac_key, 'sha256');
    
    -- Verify HMAC
    IF stored_hmac != calculated_hmac THEN
        RAISE EXCEPTION 'Data integrity check failed';
    END IF;
    
    -- Extract IV (first 16 bytes of content)
    iv := substring(content from 1 for 16);
    
    -- Extract encrypted data (everything after IV)
    data := substring(content from 17);
    
    -- Decrypt and return as UTF8 text
    RETURN convert_from(decrypt_iv(data, encryption_key, iv, 'aes-cbc'), 'UTF8');
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'Decryption error: %', SQLERRM;
        RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =============================
-- 4. KEY MANAGEMENT FUNCTIONS
-- =============================

-- Function to initialize encryption keys
CREATE OR REPLACE FUNCTION admin.initialize_encryption() RETURNS VOID AS $$
DECLARE
    tables TEXT[] := ARRAY['users', 'invites', 'chats', 'messages', 'documents'];
    table_name TEXT;
BEGIN
    -- Generate encryption keys for each table
    FOREACH table_name IN ARRAY tables LOOP
        -- Encryption key
        INSERT INTO admin.encryption_keys (key_name, key_value, key_type)
        VALUES (table_name || '_key', admin.generate_key(), 'encryption')
        ON CONFLICT (key_name) DO NOTHING;
        
        -- HMAC key
        INSERT INTO admin.encryption_keys (key_name, key_value, key_type)
        VALUES (table_name || '_hmac_key', admin.generate_key(), 'hmac')
        ON CONFLICT (key_name) DO NOTHING;
    END LOOP;
    
    RAISE NOTICE 'Encryption initialized with keys for: %', array_to_string(tables, ', ');
END;
$$ LANGUAGE plpgsql;

-- Function to rotate a key
CREATE OR REPLACE FUNCTION admin.rotate_key(key_name TEXT) RETURNS VOID AS $$
DECLARE
    old_key TEXT;
    new_key TEXT;
    backup_key_name TEXT;
BEGIN
    -- Get the old key
    SELECT key_value INTO old_key 
    FROM admin.encryption_keys 
    WHERE key_name = key_name || '_key';
    
    IF old_key IS NULL THEN
        RAISE EXCEPTION 'Key % not found', key_name;
    END IF;
    
    -- Generate a new key
    new_key := admin.generate_key();
    
    -- Create backup key
    backup_key_name := key_name || '_key_' || to_char(now(), 'YYYYMMDD_HH24MI');
    INSERT INTO admin.encryption_keys (key_name, key_value)
    VALUES (backup_key_name, old_key);
    
    -- Update to new key
    UPDATE admin.encryption_keys
    SET key_value = new_key,
        updated_at = now()
    WHERE key_name = key_name || '_key';
    
    RAISE NOTICE 'Key % rotated. Old key saved as %', key_name, backup_key_name;
END;
$$ LANGUAGE plpgsql;

-- Function to export keys (for backup or migration)
CREATE OR REPLACE FUNCTION admin.export_keys() RETURNS TEXT AS $$
DECLARE
    result JSONB;
BEGIN
    SELECT jsonb_object_agg(key_name, key_value)
    INTO result
    FROM admin.encryption_keys;
    
    RETURN result::TEXT;
END;
$$ LANGUAGE plpgsql;

-- Function to import keys (for restoration or migration)
CREATE OR REPLACE FUNCTION admin.import_keys(keys_json TEXT) RETURNS VOID AS $$
DECLARE
    key_data JSONB;
    key_name TEXT;
    key_value TEXT;
BEGIN
    key_data := keys_json::JSONB;
    
    FOR key_name, key_value IN 
        SELECT * FROM jsonb_each_text(key_data)
    LOOP
        INSERT INTO admin.encryption_keys (key_name, key_value)
        VALUES (key_name, key_value)
        ON CONFLICT (key_name) DO UPDATE
        SET key_value = EXCLUDED.key_value,
            updated_at = now();
    END LOOP;
    
    RAISE NOTICE 'Imported % keys', jsonb_object_keys(key_data)::TEXT[];
END;
$$ LANGUAGE plpgsql;

-- =============================
-- 5. CREATE STORAGE TABLES FOR ENCRYPTED DATA
-- =============================

-- Create storage tables for the encrypted data
CREATE TABLE IF NOT EXISTS admin.users_encrypted (
    id UUID PRIMARY KEY,
    encrypted_full_name BYTEA,
    encrypted_email BYTEA,
    password_hash TEXT NOT NULL,
    is_admin BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT now()
);

CREATE TABLE IF NOT EXISTS admin.invites_encrypted (
    id UUID PRIMARY KEY,
    encrypted_email BYTEA,
    encrypted_token BYTEA,
    created_at TIMESTAMP DEFAULT now(),
    expires_at TIMESTAMP NOT NULL,
    access_role TEXT 
);

CREATE TABLE IF NOT EXISTS chat.chats_encrypted (
    chat_id VARCHAR PRIMARY KEY,
    user_id VARCHAR,
    encrypted_name BYTEA,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS chat.messages_encrypted (
    message_id VARCHAR PRIMARY KEY,
    chat_id VARCHAR REFERENCES chat.chats_encrypted(chat_id),
    encrypted_content BYTEA,
    is_user BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Document storage table for encrypted file contents
CREATE TABLE IF NOT EXISTS chat.documents_encrypted (
    document_id VARCHAR PRIMARY KEY,
    chat_id VARCHAR REFERENCES chat.chats_encrypted(chat_id),
    encrypted_filename BYTEA NOT NULL,
    encrypted_content BYTEA NOT NULL,
    mime_type VARCHAR(255),
    file_size BIGINT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Add the password reset token table
CREATE TABLE IF NOT EXISTS admin.password_reset_tokens (
    id SERIAL PRIMARY KEY, -- Using SERIAL for auto-incrementing integer PK
    user_id UUID REFERENCES admin.users_encrypted(id) ON DELETE CASCADE, -- Link to users table, cascade delete
    token TEXT UNIQUE NOT NULL, -- The reset token itself
    expires_at TIMESTAMP NOT NULL -- When the token becomes invalid
);

-- =============================
-- 6. IMPLEMENT ROW-LEVEL SECURITY
-- =============================

-- Enable row-level security
ALTER TABLE admin.users_encrypted ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin.invites_encrypted ENABLE ROW LEVEL SECURITY;
ALTER TABLE chat.chats_encrypted ENABLE ROW LEVEL SECURITY;
ALTER TABLE chat.messages_encrypted ENABLE ROW LEVEL SECURITY;
ALTER TABLE chat.documents_encrypted ENABLE ROW LEVEL SECURITY;

-- Create a function to get the current user ID from session context
CREATE OR REPLACE FUNCTION admin.get_current_user_id() RETURNS UUID AS $$
BEGIN
    -- In a real application, retrieve from session context
    -- For this example, we'll try to get it from a session variable
    BEGIN
        RETURN current_setting('app.current_user_id')::UUID;
    EXCEPTION WHEN OTHERS THEN
        -- Default fallback for tests or admin operations
        RETURN NULL;
    END;
END;
$$ LANGUAGE plpgsql;

-- Create RLS policies
CREATE POLICY admin_users_policy ON admin.users_encrypted
    USING (is_admin = TRUE OR id = admin.get_current_user_id());

CREATE POLICY admin_invites_policy ON admin.invites_encrypted
    USING (EXISTS (SELECT 1 FROM admin.users_encrypted 
                  WHERE id = admin.get_current_user_id() AND is_admin = TRUE));

CREATE POLICY chat_chats_policy ON chat.chats_encrypted
    USING (user_id = admin.get_current_user_id()::TEXT OR 
          EXISTS (SELECT 1 FROM admin.users_encrypted 
                 WHERE id = admin.get_current_user_id() AND is_admin = TRUE));

CREATE POLICY chat_messages_policy ON chat.messages_encrypted
    USING (EXISTS (SELECT 1 FROM chat.chats_encrypted 
                  WHERE chat_id = chat.messages_encrypted.chat_id 
                  AND (user_id = admin.get_current_user_id()::TEXT OR 
                      EXISTS (SELECT 1 FROM admin.users_encrypted 
                             WHERE id = admin.get_current_user_id() AND is_admin = TRUE))));

-- Add policy for documents to ensure they can only be accessed by the chat owner or an admin
CREATE POLICY chat_documents_policy ON chat.documents_encrypted
    USING (EXISTS (SELECT 1 FROM chat.chats_encrypted 
                  WHERE chat_id = chat.documents_encrypted.chat_id 
                  AND (user_id = admin.get_current_user_id()::TEXT OR 
                      EXISTS (SELECT 1 FROM admin.users_encrypted 
                             WHERE id = admin.get_current_user_id() AND is_admin = TRUE))));

-- =============================
-- 7. REPLACE ORIGINAL TABLES WITH SECURE VIEWS
-- =============================

-- First, rename original tables to _original (temporary, will be dropped)
ALTER TABLE IF EXISTS admin.users RENAME TO users_original;
ALTER TABLE IF EXISTS admin.invites RENAME TO invites_original;
ALTER TABLE IF EXISTS chat.chats RENAME TO chats_original;
ALTER TABLE IF EXISTS chat.messages RENAME TO messages_original;

-- Create secure views with original table names
CREATE OR REPLACE VIEW admin.users AS
SELECT 
    id,
    admin.decrypt_data(encrypted_full_name, 'users') AS full_name,
    admin.decrypt_data(encrypted_email, 'users') AS email,
    password_hash,
    is_admin,
    created_at
FROM admin.users_encrypted;

CREATE OR REPLACE VIEW admin.invites AS
SELECT 
    id,
    admin.decrypt_data(encrypted_email, 'invites') AS email,
    admin.decrypt_data(encrypted_token, 'invites') AS token,
    created_at,
    expires_at,
    access_role
FROM admin.invites_encrypted;

CREATE OR REPLACE VIEW chat.chats AS
SELECT 
    chat_id,
    user_id,
    admin.decrypt_data(encrypted_name, 'chats') AS name,
    created_at,
    updated_at
FROM chat.chats_encrypted;

CREATE OR REPLACE VIEW chat.messages AS
SELECT 
    message_id,
    chat_id,
    admin.decrypt_data(encrypted_content, 'messages') AS content,
    is_user,
    created_at
FROM chat.messages_encrypted;

-- Create secure view for documents
CREATE OR REPLACE VIEW chat.documents AS
SELECT 
    document_id,
    chat_id,
    admin.decrypt_data(encrypted_filename, 'documents') AS filename,
    admin.decrypt_data(encrypted_content, 'documents') AS content,
    mime_type,
    file_size,
    created_at,
    updated_at
FROM chat.documents_encrypted;

-- =============================
-- 8. CREATE RULES FOR INSERT/UPDATE/DELETE OPERATIONS
-- =============================

-- Rules for admin.users view
CREATE OR REPLACE RULE users_insert AS
ON INSERT TO admin.users
DO INSTEAD
INSERT INTO admin.users_encrypted (
    id, 
    encrypted_full_name, 
    encrypted_email, 
    password_hash, 
    is_admin, 
    created_at
) VALUES (
    COALESCE(NEW.id, gen_random_uuid()),
    admin.encrypt_data(NEW.full_name, 'users'),
    admin.encrypt_data(NEW.email, 'users'),
    NEW.password_hash,
    NEW.is_admin,
    COALESCE(NEW.created_at, now())
) RETURNING 
    id,
    admin.decrypt_data(encrypted_full_name, 'users') AS full_name,
    admin.decrypt_data(encrypted_email, 'users') AS email,
    password_hash,
    is_admin,
    created_at;

CREATE OR REPLACE RULE users_update AS
ON UPDATE TO admin.users
DO INSTEAD
UPDATE admin.users_encrypted SET
    encrypted_full_name = CASE 
        WHEN NEW.full_name IS NOT NULL THEN admin.encrypt_data(NEW.full_name, 'users')
        ELSE encrypted_full_name
    END,
    encrypted_email = CASE 
        WHEN NEW.email IS NOT NULL THEN admin.encrypt_data(NEW.email, 'users')
        ELSE encrypted_email
    END,
    password_hash = NEW.password_hash,
    is_admin = NEW.is_admin
WHERE id = OLD.id;

CREATE OR REPLACE RULE users_delete AS
ON DELETE TO admin.users
DO INSTEAD
DELETE FROM admin.users_encrypted
WHERE id = OLD.id;

-- Rules for admin.invites view
CREATE OR REPLACE RULE invites_insert AS
ON INSERT TO admin.invites
DO INSTEAD
INSERT INTO admin.invites_encrypted (
    id,
    encrypted_email,
    encrypted_token,
    created_at,
    expires_at,
    access_role
) VALUES (
    COALESCE(NEW.id, gen_random_uuid()),
    admin.encrypt_data(NEW.email, 'invites'),
    admin.encrypt_data(NEW.token, 'invites'),
    COALESCE(NEW.created_at, now()),
    NEW.expires_at,
    NEW.access_role
) RETURNING
    id,
    admin.decrypt_data(encrypted_email, 'invites') AS email,
    admin.decrypt_data(encrypted_token, 'invites') AS token,
    created_at,
    expires_at,
    access_role;

CREATE OR REPLACE RULE invites_update AS
ON UPDATE TO admin.invites
DO INSTEAD
UPDATE admin.invites_encrypted SET
    encrypted_email = CASE 
        WHEN NEW.email IS NOT NULL THEN admin.encrypt_data(NEW.email, 'invites')
        ELSE encrypted_email
    END,
    encrypted_token = CASE 
        WHEN NEW.token IS NOT NULL THEN admin.encrypt_data(NEW.token, 'invites')
        ELSE encrypted_token
    END,
    expires_at = NEW.expires_at,
    access_role = NEW.access_role
WHERE id = OLD.id;

CREATE OR REPLACE RULE invites_delete AS
ON DELETE TO admin.invites
DO INSTEAD
DELETE FROM admin.invites_encrypted
WHERE id = OLD.id;

-- Rules for chat.chats view
CREATE OR REPLACE RULE chats_insert AS
ON INSERT TO chat.chats
DO INSTEAD
INSERT INTO chat.chats_encrypted (
    chat_id,
    user_id,
    encrypted_name,
    created_at,
    updated_at
) VALUES (
    NEW.chat_id,
    NEW.user_id,
    admin.encrypt_data(NEW.name, 'chats'),
    COALESCE(NEW.created_at, CURRENT_TIMESTAMP),
    COALESCE(NEW.updated_at, CURRENT_TIMESTAMP)
) RETURNING
    chat_id,
    user_id,
    admin.decrypt_data(encrypted_name, 'chats') AS name,
    created_at,
    updated_at;

CREATE OR REPLACE RULE chats_update AS
ON UPDATE TO chat.chats
DO INSTEAD
UPDATE chat.chats_encrypted SET
    user_id = NEW.user_id,
    encrypted_name = CASE 
        WHEN NEW.name IS NOT NULL THEN admin.encrypt_data(NEW.name, 'chats')
        ELSE encrypted_name
    END,
    updated_at = CURRENT_TIMESTAMP
WHERE chat_id = OLD.chat_id;

CREATE OR REPLACE RULE chats_delete AS
ON DELETE TO chat.chats
DO INSTEAD
DELETE FROM chat.chats_encrypted
WHERE chat_id = OLD.chat_id;

-- Rules for chat.messages view
CREATE OR REPLACE RULE messages_insert AS
ON INSERT TO chat.messages
DO INSTEAD
INSERT INTO chat.messages_encrypted (
    message_id,
    chat_id,
    encrypted_content,
    is_user,
    created_at
) VALUES (
    NEW.message_id,
    NEW.chat_id,
    admin.encrypt_data(NEW.content, 'messages'),
    NEW.is_user,
    COALESCE(NEW.created_at, CURRENT_TIMESTAMP)
) RETURNING
    message_id,
    chat_id,
    admin.decrypt_data(encrypted_content, 'messages') AS content,
    is_user,
    created_at;

CREATE OR REPLACE RULE messages_update AS
ON UPDATE TO chat.messages
DO INSTEAD
UPDATE chat.messages_encrypted SET
    chat_id = NEW.chat_id,
    encrypted_content = CASE 
        WHEN NEW.content IS NOT NULL THEN admin.encrypt_data(NEW.content, 'messages')
        ELSE encrypted_content
    END,
    is_user = NEW.is_user
WHERE message_id = OLD.message_id;

CREATE OR REPLACE RULE messages_delete AS
ON DELETE TO chat.messages
DO INSTEAD
DELETE FROM chat.messages_encrypted
WHERE message_id = OLD.message_id;

-- Rules for chat.documents view
CREATE OR REPLACE RULE documents_insert AS
ON INSERT TO chat.documents
DO INSTEAD
INSERT INTO chat.documents_encrypted (
    document_id,
    chat_id,
    encrypted_filename,
    encrypted_content,
    mime_type,
    file_size,
    created_at,
    updated_at
) VALUES (
    NEW.document_id,
    NEW.chat_id,
    admin.encrypt_data(NEW.filename, 'documents'),
    admin.encrypt_data(NEW.content, 'documents'),
    NEW.mime_type,
    NEW.file_size,
    COALESCE(NEW.created_at, CURRENT_TIMESTAMP),
    COALESCE(NEW.updated_at, CURRENT_TIMESTAMP)
) RETURNING
    document_id,
    chat_id,
    admin.decrypt_data(encrypted_filename, 'documents') AS filename,
    admin.decrypt_data(encrypted_content, 'documents') AS content,
    mime_type,
    file_size,
    created_at,
    updated_at;

CREATE OR REPLACE RULE documents_update AS
ON UPDATE TO chat.documents
DO INSTEAD
UPDATE chat.documents_encrypted SET
    chat_id = NEW.chat_id,
    encrypted_filename = CASE 
        WHEN NEW.filename IS NOT NULL THEN admin.encrypt_data(NEW.filename, 'documents')
        ELSE encrypted_filename
    END,
    encrypted_content = CASE 
        WHEN NEW.content IS NOT NULL THEN admin.encrypt_data(NEW.content, 'documents')
        ELSE encrypted_content
    END,
    mime_type = NEW.mime_type,
    file_size = NEW.file_size,
    updated_at = CURRENT_TIMESTAMP
WHERE document_id = OLD.document_id;

CREATE OR REPLACE RULE documents_delete AS
ON DELETE TO chat.documents
DO INSTEAD
DELETE FROM chat.documents_encrypted
WHERE document_id = OLD.document_id;

-- ====================================
-- 9. SIMPLIFIED MIGRATION FUNCTION
-- ====================================

-- Function to migrate existing data to encrypted tables
CREATE OR REPLACE FUNCTION admin.migrate_to_encrypted() RETURNS VOID AS $$
DECLARE
    r RECORD;
    success_count INT := 0;
    error_count INT := 0;
BEGIN
    -- Check if encryption has been initialized
    IF NOT EXISTS (SELECT 1 FROM admin.encryption_keys WHERE key_name LIKE '%\_key') THEN
        RAISE EXCEPTION 'Encryption not initialized. Run admin.initialize_encryption() first.';
    END IF;
    
    -- Migrate users
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'admin' AND table_name = 'users_original') THEN
        FOR r IN SELECT * FROM admin.users_original LOOP
            BEGIN
                INSERT INTO admin.users_encrypted (
                    id, encrypted_full_name, encrypted_email, password_hash, is_admin, created_at
                ) VALUES (
                    r.id,
                    admin.encrypt_data(r.full_name, 'users'),
                    admin.encrypt_data(r.email, 'users'),
                    r.password_hash,
                    r.is_admin,
                    r.created_at
                );
                success_count := success_count + 1;
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING 'Error migrating user %: %', r.id, SQLERRM;
                error_count := error_count + 1;
            END;
        END LOOP;
        
        -- Drop original table
        DROP TABLE admin.users_original;
    END IF;
    
    -- Migrate invites
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'admin' AND table_name = 'invites_original') THEN
        FOR r IN SELECT * FROM admin.invites_original LOOP
            BEGIN
                INSERT INTO admin.invites_encrypted (
                    id, encrypted_email, encrypted_token, created_at, expires_at, access_role
                ) VALUES (
                    r.id,
                    admin.encrypt_data(r.email, 'invites'),
                    admin.encrypt_data(r.token, 'invites'),
                    r.created_at,
                    r.expires_at,
                    r.access_role
                );
                success_count := success_count + 1;
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING 'Error migrating invite %: %', r.id, SQLERRM;
                error_count := error_count + 1;
            END;
        END LOOP;
        
        -- Drop original table
        DROP TABLE admin.invites_original;
    END IF;
    
    -- Migrate chats
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'chat' AND table_name = 'chats_original') THEN
        FOR r IN SELECT * FROM chat.chats_original LOOP
            BEGIN
                INSERT INTO chat.chats_encrypted (
                    chat_id, user_id, encrypted_name, created_at, updated_at
                ) VALUES (
                    r.chat_id,
                    r.user_id,
                    admin.encrypt_data(r.name, 'chats'),
                    r.created_at,
                    r.updated_at
                );
                success_count := success_count + 1;
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING 'Error migrating chat %: %', r.chat_id, SQLERRM;
                error_count := error_count + 1;
            END;
        END LOOP;
        
        -- Drop original table
        DROP TABLE chat.chats_original;
    END IF;
    
    -- Migrate messages
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'chat' AND table_name = 'messages_original') THEN
        FOR r IN SELECT * FROM chat.messages_original LOOP
            BEGIN
                INSERT INTO chat.messages_encrypted (
                    message_id, chat_id, encrypted_content, is_user, created_at
                ) VALUES (
                    r.message_id,
                    r.chat_id,
                    admin.encrypt_data(r.content, 'messages'),
                    r.is_user,
                    r.created_at
                );
                success_count := success_count + 1;
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING 'Error migrating message %: %', r.message_id, SQLERRM;
                error_count := error_count + 1;
            END;
        END LOOP;
        
        -- Drop original table
        DROP TABLE chat.messages_original;
    END IF;
    
    -- Migrate documents if they exist
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'chat' AND table_name = 'documents_original') THEN
        FOR r IN SELECT * FROM chat.documents_original LOOP
            BEGIN
                INSERT INTO chat.documents_encrypted (
                    document_id, chat_id, encrypted_filename, encrypted_content, mime_type, file_size, created_at, updated_at
                ) VALUES (
                    r.document_id,
                    r.chat_id,
                    admin.encrypt_data(r.filename, 'documents'),
                    admin.encrypt_data(r.content, 'documents'),
                    r.mime_type,
                    r.file_size,
                    r.created_at,
                    r.updated_at
                );
                success_count := success_count + 1;
            EXCEPTION WHEN OTHERS THEN
                RAISE WARNING 'Error migrating document %: %', r.document_id, SQLERRM;
                error_count := error_count + 1;
            END;
        END LOOP;
        
        -- Drop original table
        DROP TABLE chat.documents_original;
    END IF;
    
    RAISE NOTICE 'Migration completed with % successful records and % errors', success_count, error_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =============================
-- 10. BASIC AUDIT LOGGING
-- =============================

-- Create simplified audit log table
CREATE TABLE IF NOT EXISTS admin.audit_log (
    id SERIAL PRIMARY KEY,
    user_id UUID,
    action TEXT NOT NULL,
    table_name TEXT NOT NULL,
    record_id TEXT,
    timestamp TIMESTAMP DEFAULT now()
);

-- Create index on audit log
CREATE INDEX IF NOT EXISTS audit_log_timestamp_idx ON admin.audit_log(timestamp);

-- Basic audit function
CREATE OR REPLACE FUNCTION admin.log_data_access() RETURNS TRIGGER AS $$
DECLARE
    current_user_id UUID;
    record_id TEXT;
BEGIN
    -- Try to get current user ID from application context
    BEGIN
        current_user_id := current_setting('app.current_user_id')::UUID;
    EXCEPTION WHEN OTHERS THEN
        current_user_id := NULL;
    END;
    
    -- Get record ID based on the table
    IF TG_TABLE_NAME = 'users_encrypted' THEN
        record_id := NEW.id::TEXT;
    ELSIF TG_TABLE_NAME = 'invites_encrypted' THEN
        record_id := NEW.id::TEXT;
    ELSIF TG_TABLE_NAME = 'chats_encrypted' THEN
        record_id := NEW.chat_id::TEXT;
    ELSIF TG_TABLE_NAME = 'messages_encrypted' THEN
        record_id := NEW.message_id::TEXT;
    END IF;
    
    -- Insert audit record
    INSERT INTO admin.audit_log (user_id, action, table_name, record_id)
    VALUES (current_user_id, TG_OP, TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, record_id);
    
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Add basic audit triggers
CREATE TRIGGER audit_users_access
AFTER INSERT OR UPDATE OR DELETE ON admin.users_encrypted
FOR EACH ROW EXECUTE FUNCTION admin.log_data_access();

CREATE TRIGGER audit_invites_access
AFTER INSERT OR UPDATE OR DELETE ON admin.invites_encrypted
FOR EACH ROW EXECUTE FUNCTION admin.log_data_access();

CREATE TRIGGER audit_chats_access
AFTER INSERT OR UPDATE OR DELETE ON chat.chats_encrypted
FOR EACH ROW EXECUTE FUNCTION admin.log_data_access();

CREATE TRIGGER audit_messages_access
AFTER INSERT OR UPDATE OR DELETE ON chat.messages_encrypted
FOR EACH ROW EXECUTE FUNCTION admin.log_data_access();

CREATE TRIGGER audit_documents_access
AFTER INSERT OR UPDATE OR DELETE ON chat.documents_encrypted
FOR EACH ROW EXECUTE FUNCTION admin.log_data_access();

-- =============================
-- 11. USAGE INSTRUCTIONS
-- =============================

/*
SIMPLIFIED SETUP FOR EPHEMERAL SYSTEMS:

1. Initialize encryption keys:
   SELECT admin.initialize_encryption();
   
2. Migrate existing data (if you have any):
   SELECT admin.migrate_to_encrypted();

3. Your application continues to use the regular table views:
   - admin.users
   - admin.invites
   - chat.chats
   - chat.messages

4. For ephemeral systems:
   - Before shutting down: SELECT admin.export_keys();
     Save this output securely
   - When relaunching: SELECT admin.import_keys('{"users_key":"..."}');
   
5. For key rotation:
   SELECT admin.rotate_key('users');
   
This approach provides:
- Simple key management suitable for ephemeral environments
- Easy export/import of keys between instances
- Transparent encryption/decryption for your application
- Row-level security for multi-tenant access control
*/























-- =============================
-- ENHANCED SECURITY ADDITIONS
-- =============================

-- 1. Add HMAC Verification
ALTER TABLE admin.encryption_keys ADD COLUMN key_type TEXT DEFAULT 'encryption';

-- Add HMAC keys during initialization
CREATE OR REPLACE FUNCTION admin.initialize_encryption() RETURNS VOID AS $$
DECLARE
    tables TEXT[] := ARRAY['users', 'invites', 'chats', 'messages', 'documents'];
    table_name TEXT;
BEGIN
    -- Generate encryption keys for each table
    FOREACH table_name IN ARRAY tables LOOP
        -- Encryption key
        INSERT INTO admin.encryption_keys (key_name, key_value, key_type)
        VALUES (table_name || '_key', admin.generate_key(), 'encryption')
        ON CONFLICT (key_name) DO NOTHING;
        
        -- HMAC key
        INSERT INTO admin.encryption_keys (key_name, key_value, key_type)
        VALUES (table_name || '_hmac_key', admin.generate_key(), 'hmac')
        ON CONFLICT (key_name) DO NOTHING;
    END LOOP;
    
    RAISE NOTICE 'Encryption initialized with keys for: %', array_to_string(tables, ', ');
END;
$$ LANGUAGE plpgsql;

-- Update encrypt_data function to include HMAC
CREATE OR REPLACE FUNCTION admin.encrypt_data(p_data TEXT, p_key_name TEXT) RETURNS BYTEA AS $$
DECLARE
    encryption_key BYTEA;
    hmac_key BYTEA;
    iv BYTEA;
    encrypted BYTEA;
    hmac BYTEA;
BEGIN
    -- Get the encryption key
    SELECT decode(key_value, 'hex') INTO encryption_key 
    FROM admin.encryption_keys 
    WHERE admin.encryption_keys.key_name = p_key_name || '_key' AND key_type = 'encryption';
    
    -- Get the HMAC key
    SELECT decode(key_value, 'hex') INTO hmac_key 
    FROM admin.encryption_keys 
    WHERE admin.encryption_keys.key_name = p_key_name || '_hmac_key' AND key_type = 'hmac';
    
    IF encryption_key IS NULL OR hmac_key IS NULL THEN
        RAISE EXCEPTION 'Encryption or HMAC key % not found', p_key_name;
    END IF;
    
    -- Generate random IV for this encryption
    iv := gen_random_bytes(16);
    
    -- Encrypt the data
    encrypted := encrypt_iv(convert_to(p_data, 'UTF8'), encryption_key, iv, 'aes-cbc');
    
    -- Generate HMAC for integrity
    hmac := hmac(iv || encrypted, hmac_key, 'sha256');
    
    -- Return HMAC + IV + encrypted data
    RETURN hmac || iv || encrypted;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Update decrypt_data function to verify HMAC
CREATE OR REPLACE FUNCTION admin.decrypt_data(p_encrypted_data BYTEA, p_key_name TEXT) RETURNS TEXT AS $$
DECLARE
    encryption_key BYTEA;
    hmac_key BYTEA;
    stored_hmac BYTEA;
    calculated_hmac BYTEA;
    iv BYTEA;
    data BYTEA;
    content BYTEA;
BEGIN
    -- Handle NULL input gracefully
    IF p_encrypted_data IS NULL THEN
        RETURN NULL;
    END IF;
    
    -- Get the encryption key
    SELECT decode(key_value, 'hex') INTO encryption_key 
    FROM admin.encryption_keys 
    WHERE admin.encryption_keys.key_name = p_key_name || '_key' AND key_type = 'encryption';
    
    -- Get the HMAC key
    SELECT decode(key_value, 'hex') INTO hmac_key 
    FROM admin.encryption_keys 
    WHERE admin.encryption_keys.key_name = p_key_name || '_hmac_key' AND key_type = 'hmac';
    
    IF encryption_key IS NULL OR hmac_key IS NULL THEN
        RAISE EXCEPTION 'Encryption or HMAC key % not found', p_key_name;
    END IF;
    
    -- Extract HMAC (first 32 bytes)
    stored_hmac := substring(p_encrypted_data from 1 for 32);
    
    -- Extract IV and ciphertext (everything after HMAC)
    content := substring(p_encrypted_data from 33);
    
    -- Calculate HMAC
    calculated_hmac := hmac(content, hmac_key, 'sha256');
    
    -- Verify HMAC
    IF stored_hmac != calculated_hmac THEN
        RAISE EXCEPTION 'Data integrity check failed';
    END IF;
    
    -- Extract IV (first 16 bytes of content)
    iv := substring(content from 1 for 16);
    
    -- Extract encrypted data (everything after IV)
    data := substring(content from 17);
    
    -- Decrypt and return as UTF8 text
    RETURN convert_from(decrypt_iv(data, encryption_key, iv, 'aes-cbc'), 'UTF8');
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'Decryption error: %', SQLERRM;
        RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2. Enhanced Audit Logging
ALTER TABLE admin.audit_log 
ADD COLUMN query_text TEXT,
ADD COLUMN client_ip TEXT,
ADD COLUMN success BOOLEAN DEFAULT TRUE;

-- Update audit function
CREATE OR REPLACE FUNCTION admin.log_data_access() RETURNS TRIGGER AS $$
DECLARE
    current_user_id UUID;
    record_id TEXT;
    client_address TEXT;
BEGIN
    -- Try to get current user ID from application context
    BEGIN
        current_user_id := current_setting('app.current_user_id')::UUID;
    EXCEPTION WHEN OTHERS THEN
        current_user_id := NULL;
    END;
    
    -- Try to get client IP
    BEGIN
        client_address := inet_client_addr()::TEXT;
    EXCEPTION WHEN OTHERS THEN
        client_address := NULL;
    END;
    
    -- Get record ID based on the table
    IF TG_TABLE_NAME = 'users_encrypted' THEN
        record_id := NEW.id::TEXT;
    ELSIF TG_TABLE_NAME = 'invites_encrypted' THEN
        record_id := NEW.id::TEXT;
    ELSIF TG_TABLE_NAME = 'chats_encrypted' THEN
        record_id := NEW.chat_id::TEXT;
    ELSIF TG_TABLE_NAME = 'messages_encrypted' THEN
        record_id := NEW.message_id::TEXT;
    END IF;
    
    -- Insert enhanced audit record
    INSERT INTO admin.audit_log (user_id, action, table_name, record_id, query_text, client_ip)
    VALUES (
        current_user_id, 
        TG_OP, 
        TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, 
        record_id,
        current_query(),
        client_address
    );
    
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- 3. Session Management Controls
-- Create session management
CREATE OR REPLACE FUNCTION admin.validate_session() RETURNS BOOLEAN AS $$
DECLARE
    session_start TIMESTAMP;
    max_session_time INTERVAL := INTERVAL '30 minutes';
BEGIN
    -- Get session start time
    BEGIN
        session_start := current_setting('app.session_start')::TIMESTAMP;
    EXCEPTION WHEN OTHERS THEN
        RETURN FALSE;
    END;
    
    -- Check if session is still valid
    IF (now() - session_start) > max_session_time THEN
        RETURN FALSE;
    END IF;
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

-- Add session check to key functions
CREATE OR REPLACE FUNCTION admin.require_valid_session() RETURNS VOID AS $$
BEGIN
    IF NOT admin.validate_session() THEN
        RAISE EXCEPTION 'Session expired or invalid';
    END IF;
END;
$$ LANGUAGE plpgsql;

-- 4. Data Classification
-- Add classification levels to tables
ALTER TABLE admin.users_encrypted ADD COLUMN sensitivity_level TEXT DEFAULT 'RESTRICTED';
ALTER TABLE admin.invites_encrypted ADD COLUMN sensitivity_level TEXT DEFAULT 'RESTRICTED';
ALTER TABLE chat.chats_encrypted ADD COLUMN sensitivity_level TEXT DEFAULT 'CONFIDENTIAL';
ALTER TABLE chat.messages_encrypted ADD COLUMN sensitivity_level TEXT DEFAULT 'CONFIDENTIAL';
ALTER TABLE chat.documents_encrypted ADD COLUMN sensitivity_level TEXT DEFAULT 'CONFIDENTIAL';

CREATE OR REPLACE FUNCTION admin.enforce_data_classification() RETURNS TRIGGER AS $$
DECLARE
    record_id TEXT := 'unknown';
BEGIN
    -- First determine the record ID based on the table
    IF TG_TABLE_SCHEMA = 'admin' AND TG_TABLE_NAME = 'users_encrypted' AND 
       EXISTS (SELECT 1 FROM information_schema.columns 
               WHERE table_schema = TG_TABLE_SCHEMA 
               AND table_name = TG_TABLE_NAME
               AND column_name = 'id') THEN
        record_id := NEW.id::TEXT;
    ELSIF TG_TABLE_SCHEMA = 'admin' AND TG_TABLE_NAME = 'invites_encrypted' AND 
          EXISTS (SELECT 1 FROM information_schema.columns 
                 WHERE table_schema = TG_TABLE_SCHEMA 
                 AND table_name = TG_TABLE_NAME
                 AND column_name = 'id') THEN
        record_id := NEW.id::TEXT;
    ELSIF TG_TABLE_SCHEMA = 'chat' AND TG_TABLE_NAME = 'chats_encrypted' AND 
          EXISTS (SELECT 1 FROM information_schema.columns 
                 WHERE table_schema = TG_TABLE_SCHEMA 
                 AND table_name = TG_TABLE_NAME
                 AND column_name = 'chat_id') THEN
        record_id := NEW.chat_id::TEXT;
    ELSIF TG_TABLE_SCHEMA = 'chat' AND TG_TABLE_NAME = 'messages_encrypted' AND 
          EXISTS (SELECT 1 FROM information_schema.columns 
                 WHERE table_schema = TG_TABLE_SCHEMA 
                 AND table_name = TG_TABLE_NAME
                 AND column_name = 'message_id') THEN
        record_id := NEW.message_id::TEXT;
    END IF;

    -- Check if this table has sensitivity_level before trying to use it
    IF EXISTS (SELECT 1 FROM information_schema.columns 
              WHERE table_schema = TG_TABLE_SCHEMA 
              AND table_name = TG_TABLE_NAME
              AND column_name = 'sensitivity_level') 
       AND NEW.sensitivity_level = 'RESTRICTED' THEN
        
        INSERT INTO admin.audit_log (user_id, action, table_name, record_id, query_text)
        VALUES (
            admin.get_current_user_id(), 
            'ACCESS_RESTRICTED', 
            TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, 
            record_id,
            current_query()
        );
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Add triggers for enforcing classification
CREATE TRIGGER enforce_users_classification
BEFORE INSERT OR UPDATE ON admin.users_encrypted
FOR EACH ROW EXECUTE FUNCTION admin.enforce_data_classification();

CREATE TRIGGER enforce_invites_classification
BEFORE INSERT OR UPDATE ON admin.invites_encrypted
FOR EACH ROW EXECUTE FUNCTION admin.enforce_data_classification();

SELECT admin.initialize_encryption();