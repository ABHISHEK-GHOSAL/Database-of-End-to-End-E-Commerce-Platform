-- =============================================================================
-- FILE: TRG_AUDIT_ORDERS.sql
-- PURPOSE: Audit trigger on ORDERS table.
--           Logs INSERT, UPDATE, and DELETE operations into AUDIT_LOGS.
--           Tracks who changed the record (Oracle USER) and timestamp.
-- =============================================================================

-- =============================================================================
-- Drop trigger if it already exists (for clean re-runs)
-- =============================================================================
DROP TRIGGER trg_audit_orders;

-- =============================================================================
-- CREATE TRIGGER (Compound Trigger - Supports multiple operations elegantly)
-- =============================================================================
CREATE OR REPLACE TRIGGER trg_audit_orders
    FOR INSERT OR UPDATE OR DELETE ON orders
    COMPOUND TRIGGER

    -- -------------------------------------------------------------------------
    -- 1. DECLARE: Variables to hold the old and new states per row.
    --    We use a PL/SQL table (collection) to handle multi-row operations
    --    (e.g., batch updates) without losing context.
    -- -------------------------------------------------------------------------
    TYPE t_audit_row IS RECORD (
        action          VARCHAR2(10),
        old_status      orders.status%TYPE,
        new_status      orders.status%TYPE,
        old_total       orders.total_amount%TYPE,
        new_total       orders.total_amount%TYPE,
        changed_by      VARCHAR2(100)
    );

    TYPE t_audit_table IS TABLE OF t_audit_row INDEX BY PLS_INTEGER;
    g_audit_data t_audit_table;
    g_idx         PLS_INTEGER := 0;

    -- -------------------------------------------------------------------------
    -- 2. BEFORE EACH ROW: Capture the data from the row being modified.
    --    We store it in the collection for processing in AFTER STATEMENT.
    -- -------------------------------------------------------------------------
    BEFORE EACH ROW IS
    BEGIN
        g_idx := g_idx + 1;
        g_audit_data(g_idx).action := CASE 
                                        WHEN INSERTING THEN 'INSERT'
                                        WHEN UPDATING  THEN 'UPDATE'
                                        WHEN DELETING  THEN 'DELETE'
                                      END;
        g_audit_data(g_idx).old_status := :OLD.status;
        g_audit_data(g_idx).new_status := :NEW.status;
        g_audit_data(g_idx).old_total  := :OLD.total_amount;
        g_audit_data(g_idx).new_total  := :NEW.total_amount;
        g_audit_data(g_idx).changed_by := USER;  -- Oracle session user
    END BEFORE EACH ROW;

    -- -------------------------------------------------------------------------
    -- 3. AFTER STATEMENT: Insert the captured data into AUDIT_LOGS.
    --    This minimizes the number of INSERT statements and is more efficient.
    -- -------------------------------------------------------------------------
    AFTER STATEMENT IS
        v_old_value VARCHAR2(4000);
        v_new_value VARCHAR2(4000);
        v_log_count NUMBER := 0;
    BEGIN
        FOR i IN 1 .. g_audit_data.COUNT LOOP
            -- Build a human-readable log string for the change
            -- We log the status change and the total amount change as a single audit entry per row.
            v_old_value := 'Status=' || NVL(g_audit_data(i).old_status, 'NULL') || 
                           ', Total=' || NVL(TO_CHAR(g_audit_data(i).old_total), 'NULL');
            v_new_value := 'Status=' || NVL(g_audit_data(i).new_status, 'NULL') || 
                           ', Total=' || NVL(TO_CHAR(g_audit_data(i).new_total), 'NULL');

            -- Skip logging if nothing actually changed (for UPDATE with no real change)
            IF g_audit_data(i).action = 'UPDATE' AND v_old_value = v_new_value THEN
                CONTINUE;
            END IF;

            -- Insert into audit log table
            INSERT INTO audit_logs (
                table_name,
                action,
                column_name,   -- We'll store a generic 'FULL_ROW' or the specific changed field
                old_value,
                new_value,
                changed_by_user,
                change_timestamp
            ) VALUES (
                'ORDERS',
                g_audit_data(i).action,
                'FULL_ROW',     -- Indicates we logged the whole relevant row state
                v_old_value,
                v_new_value,
                g_audit_data(i).changed_by,
                SYSTIMESTAMP
            );

            v_log_count := v_log_count + 1;
        END LOOP;

        -- Optional: Print confirmation (useful for debugging)
        IF v_log_count > 0 THEN
            DBMS_OUTPUT.PUT_LINE('🔍 Audit Log: ' || v_log_count || ' entries recorded for ORDERS table.');
        END IF;

        -- Clear the collection for the next transaction
        g_audit_data.DELETE;
        g_idx := 0;

    EXCEPTION
        WHEN OTHERS THEN
            -- Log the error, but don't block the main transaction.
            -- We write to DBMS_OUTPUT for visibility, and we RAISE to prevent silent failures
            -- if audit logging is critical. For this project, we raise to demonstrate data integrity.
            DBMS_OUTPUT.PUT_LINE('❌ Audit Log Error: ' || SQLERRM);
            RAISE;
    END AFTER STATEMENT;

END trg_audit_orders;
/
SHOW ERRORS TRG_AUDIT_ORDERS;

