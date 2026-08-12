-- =============================================================================
-- FILE: PKG_SECURITY.sql
-- PURPOSE: User Registration, Authentication, Password Hashing & Profile Updates
-- SECURITY: Uses ORA_HASH to store passwords. Never stores plain text.
-- TABLES: CUSTOMERS
-- =============================================================================

-- =============================================================================
-- PACKAGE SPECIFICATION (Public Interface)
-- =============================================================================
CREATE OR REPLACE PACKAGE PKG_SECURITY AS

    -- -------------------------------------------------------------------------
    -- 1. HASH_PASSWORD: Uses ORA_HASH via SQL 
    --    Returns a VARCHAR2 representation of the numeric hash.
    -- -------------------------------------------------------------------------
    FUNCTION hash_password(p_password IN VARCHAR2) RETURN VARCHAR2;

    -- -------------------------------------------------------------------------
    -- 2. REGISTER_USER: Creates a new user account.
    --    Validates email uniqueness and hashes the password.
    --    Raises: DUP_EMAIL exception if email already exists.
    -- -------------------------------------------------------------------------
    PROCEDURE register_user(
        p_full_name   IN VARCHAR2,
        p_email       IN VARCHAR2,
        p_password    IN VARCHAR2,
        p_phone       IN VARCHAR2 DEFAULT NULL,
        p_is_active   IN CHAR DEFAULT 'Y'
    );

    -- -------------------------------------------------------------------------
    -- 3. AUTHENTICATE_USER: Verifies user credentials.
    --    Returns the CUSTOMER_ID if successful.
    --    Raises: INVALID_EMAIL or INVALID_PASSWORD exceptions on failure.
    -- -------------------------------------------------------------------------
    FUNCTION authenticate_user(
        p_email    IN VARCHAR2,
        p_password IN VARCHAR2
    ) RETURN NUMBER;

    -- -------------------------------------------------------------------------
    -- 4. RESET_PASSWORD: Allows a user to change their password.
    --    Requires the old password for verification (prevents unauthorized changes).
    -- -------------------------------------------------------------------------
    PROCEDURE reset_password(
        p_email         IN VARCHAR2,
        p_old_password  IN VARCHAR2,
        p_new_password  IN VARCHAR2
    );

    -- -------------------------------------------------------------------------
    -- 5. UPDATE_PROFILE: Updates non-sensitive user details.
    -- -------------------------------------------------------------------------
    PROCEDURE update_profile(
        p_customer_id IN NUMBER,
        p_full_name   IN VARCHAR2 DEFAULT NULL,
        p_phone       IN VARCHAR2 DEFAULT NULL
    );

    -- -------------------------------------------------------------------------
    -- 6. DEACTIVATE_USER: Soft-deletes a user (sets is_active = 'N').
    --    Prevents login but preserves audit/historical data.
    -- -------------------------------------------------------------------------
    PROCEDURE deactivate_user(p_customer_id IN NUMBER);

    -- -------------------------------------------------------------------------
    -- 7. GET_USER_BY_EMAIL: Returns user details (for admin verification).
    --    Returns a cursor containing user info without the password hash.
    -- -------------------------------------------------------------------------
    FUNCTION get_user_by_email(p_email IN VARCHAR2) RETURN SYS_REFCURSOR;

END PKG_SECURITY;


-- =============================================================================
-- PACKAGE BODY PKG_SECURITY (100% COMPATIBLE - No Special Grants Required)
-- Uses ORA_HASH (built-in SQL function) for password "hashing".
-- NOTE: ORA_HASH is a 32-bit checksum, NOT cryptographic. 
-- Perfect for demonstrating concepts on Oracle Cloud Free Tier.
-- =============================================================================
CREATE OR REPLACE PACKAGE BODY PKG_SECURITY AS

    -- -------------------------------------------------------------------------
    -- PRIVATE EXCEPTIONS
    -- -------------------------------------------------------------------------
    e_dup_email      EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_dup_email, -20001);
    e_invalid_email  EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_invalid_email, -20002);
    e_invalid_pwd    EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_invalid_pwd, -20003);
    e_old_pwd_mismatch EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_old_pwd_mismatch, -20004);
    e_user_inactive  EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_user_inactive, -20005);

    -- -------------------------------------------------------------------------
    -- 1. HASH_PASSWORD: Uses ORA_HASH via SQL 
    --    Returns a VARCHAR2 representation of the numeric hash.
    -- -------------------------------------------------------------------------
    FUNCTION hash_password(p_password IN VARCHAR2) RETURN VARCHAR2 IS
        v_hash VARCHAR2(100);
    BEGIN
        -- ORA_HASH is a SQL function. Calling it via SELECT ensures PL/SQL recognizes it.
        SELECT TO_CHAR(ORA_HASH(p_password)) INTO v_hash FROM DUAL;
        RETURN v_hash;
    END hash_password;

    -- -------------------------------------------------------------------------
    -- 2. REGISTER_USER
    -- -------------------------------------------------------------------------
    PROCEDURE register_user(
        p_full_name   IN VARCHAR2,
        p_email       IN VARCHAR2,
        p_password    IN VARCHAR2,
        p_phone       IN VARCHAR2 DEFAULT NULL,
        p_is_active   IN CHAR DEFAULT 'Y'
    ) IS
        v_email_upper VARCHAR2(100) := UPPER(p_email);
        v_count       NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_count 
        FROM customers 
        WHERE UPPER(email) = v_email_upper;

        IF v_count > 0 THEN
            RAISE e_dup_email;
        END IF;

        INSERT INTO customers (
            full_name,
            email,
            hashed_password,
            phone,
            is_active
        ) VALUES (
            p_full_name,
            p_email,
            hash_password(p_password),
            p_phone,
            p_is_active
        );

        COMMIT;
        DBMS_OUTPUT.PUT_LINE('User ' || p_email || ' registered successfully!');

    EXCEPTION
        WHEN e_dup_email THEN
            RAISE_APPLICATION_ERROR(-20001, 'Email ' || p_email || ' already exists.');
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END register_user;

    -- -------------------------------------------------------------------------
    -- 3. AUTHENTICATE_USER
    -- -------------------------------------------------------------------------
    FUNCTION authenticate_user(
        p_email    IN VARCHAR2,
        p_password IN VARCHAR2
    ) RETURN NUMBER IS
        v_customer_id   customers.customer_id%TYPE;
        v_stored_hash   customers.hashed_password%TYPE;
        v_is_active     customers.is_active%TYPE;
        v_input_hash    VARCHAR2(100) := hash_password(p_password);
    BEGIN
        SELECT customer_id, hashed_password, is_active
        INTO v_customer_id, v_stored_hash, v_is_active
        FROM customers
        WHERE UPPER(email) = UPPER(p_email);

        IF v_is_active = 'N' THEN
            RAISE e_user_inactive;
        END IF;

        IF v_stored_hash = v_input_hash THEN
            RETURN v_customer_id;
        ELSE
            RAISE e_invalid_pwd;
        END IF;

    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20002, 'Invalid email address.');
        WHEN e_user_inactive THEN
            RAISE_APPLICATION_ERROR(-20005, 'Account is deactivated.');
        WHEN e_invalid_pwd THEN
            RAISE_APPLICATION_ERROR(-20003, 'Invalid password.');
        WHEN OTHERS THEN
            RAISE;
    END authenticate_user;

    -- -------------------------------------------------------------------------
    -- 4. RESET_PASSWORD
    -- -------------------------------------------------------------------------
    PROCEDURE reset_password(
        p_email         IN VARCHAR2,
        p_old_password  IN VARCHAR2,
        p_new_password  IN VARCHAR2
    ) IS
        v_customer_id   customers.customer_id%TYPE;
        v_stored_hash   customers.hashed_password%TYPE;
        v_old_hash      VARCHAR2(100) := hash_password(p_old_password);
    BEGIN
        SELECT customer_id, hashed_password
        INTO v_customer_id, v_stored_hash
        FROM customers
        WHERE UPPER(email) = UPPER(p_email);

        IF v_stored_hash != v_old_hash THEN
            RAISE e_old_pwd_mismatch;
        END IF;

        UPDATE customers
        SET hashed_password = hash_password(p_new_password)
        WHERE customer_id = v_customer_id;

        COMMIT;
        DBMS_OUTPUT.PUT_LINE('Password updated for ' || p_email);

    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20002, 'Invalid email address.');
        WHEN e_old_pwd_mismatch THEN
            RAISE_APPLICATION_ERROR(-20004, 'Old password does not match.');
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END reset_password;

    -- -------------------------------------------------------------------------
    -- 5. UPDATE_PROFILE
    -- -------------------------------------------------------------------------
    PROCEDURE update_profile(
        p_customer_id IN NUMBER,
        p_full_name   IN VARCHAR2 DEFAULT NULL,
        p_phone       IN VARCHAR2 DEFAULT NULL
    ) IS
    BEGIN
        UPDATE customers
        SET 
            full_name = NVL(p_full_name, full_name),
            phone = NVL(p_phone, phone)
        WHERE customer_id = p_customer_id;

        IF SQL%ROWCOUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20010, 'Customer ID not found.');
        END IF;

        COMMIT;
        DBMS_OUTPUT.PUT_LINE('Profile updated for ID: ' || p_customer_id);

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END update_profile;

    -- -------------------------------------------------------------------------
    -- 6. DEACTIVATE_USER
    -- -------------------------------------------------------------------------
    PROCEDURE deactivate_user(p_customer_id IN NUMBER) IS
    BEGIN
        UPDATE customers
        SET is_active = 'N'
        WHERE customer_id = p_customer_id;

        IF SQL%ROWCOUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20010, 'Customer ID not found.');
        END IF;

        COMMIT;
        DBMS_OUTPUT.PUT_LINE('User ' || p_customer_id || ' deactivated.');

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END deactivate_user;

    -- -------------------------------------------------------------------------
    -- 7. GET_USER_BY_EMAIL
    -- -------------------------------------------------------------------------
    FUNCTION get_user_by_email(p_email IN VARCHAR2) RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT 
                customer_id,
                full_name,
                email,
                phone,
                created_date,
                is_active
            FROM customers
            WHERE UPPER(email) = UPPER(p_email);
        RETURN v_cursor;
    END get_user_by_email;

END PKG_SECURITY;
/