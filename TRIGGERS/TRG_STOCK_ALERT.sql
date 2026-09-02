-- =============================================================================
-- FILE: TRG_STOCK_ALERT.sql
-- PURPOSE: Trigger on PRODUCT_INVENTORY table.
--           Detects when available stock (quantity_on_hand - reserved_qty) 
--           falls below the low_stock_threshold.
--           Inserts a record into LOW_STOCK_ALERTS for operations follow-up.

-- =============================================================================



-- =============================================================================
-- CREATE TRIGGER (Row-level, after update of specific columns)
--         We use a normal row-level trigger because we need the specific row values.
-- =============================================================================
CREATE OR REPLACE TRIGGER trg_stock_alert
    AFTER UPDATE OF quantity_on_hand, reserved_qty, low_stock_threshold
    ON product_inventory
    FOR EACH ROW
DECLARE
    v_old_available   NUMBER := NVL(:OLD.quantity_on_hand, 0) - NVL(:OLD.reserved_qty, 0);
    v_new_available   NUMBER := NVL(:NEW.quantity_on_hand, 0) - NVL(:NEW.reserved_qty, 0);
    v_threshold       NUMBER := NVL(:NEW.low_stock_threshold, 5);
    v_product_name    products.product_name%TYPE;
    v_sku             products.sku%TYPE;
    v_alert_triggered BOOLEAN := FALSE;
BEGIN
    -- -------------------------------------------------------------------------
    -- 1. Determine if an alert should be triggered.
    --    Alert only if new available stock is below threshold, 
    --    and (old available was >= threshold OR threshold changed).
    --    This prevents duplicate alerts on every tiny change.
    -- -------------------------------------------------------------------------
    IF v_new_available < v_threshold THEN
        -- Check if we already have an UNRESOLVED alert for this product.
        DECLARE
            v_existing_alert NUMBER;
        BEGIN
            SELECT COUNT(*) INTO v_existing_alert
            FROM low_stock_alerts
            WHERE product_id = :NEW.product_id AND resolved_flag = 'N';

            IF v_existing_alert = 0 THEN
                v_alert_triggered := TRUE;
            END IF;
        END;
    END IF;

    -- -------------------------------------------------------------------------
    -- 2. If alert is triggered, fetch product details and insert into alerts table.
    -- -------------------------------------------------------------------------
    IF v_alert_triggered THEN
        BEGIN
            SELECT product_name, sku
            INTO v_product_name, v_sku
            FROM products
            WHERE product_id = :NEW.product_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_product_name := 'UNKNOWN PRODUCT';
                v_sku := 'UNKNOWN SKU';
        END;

        -- Insert the alert record
        INSERT INTO low_stock_alerts (
            product_id,
            product_name,
            sku,
            current_stock,
            threshold,
            created_at,
            resolved_flag
        ) VALUES (
            :NEW.product_id,
            v_product_name,
            v_sku,
            v_new_available,
            v_threshold,
            SYSTIMESTAMP,
            'N'
        );

        -- Print a visible message (for debugging/awareness)
        DBMS_OUTPUT.PUT_LINE('🚨 LOW STOCK ALERT! Product: ' || v_product_name || 
                             ' (SKU: ' || v_sku || ') | Available: ' || v_new_available || 
                             ' | Threshold: ' || v_threshold);

    END IF;

EXCEPTION
    WHEN OTHERS THEN
        -- Log the error but do NOT fail the main transaction.
        -- The inventory update must succeed even if the alert fails.
        DBMS_OUTPUT.PUT_LINE('⚠️ Stock Alert Trigger Error: ' || SQLERRM);
        -- We don't RAISE here to keep the business transaction intact.
END trg_stock_alert;
/
SHOW ERRORS TRG_STOCK_ALERT;

