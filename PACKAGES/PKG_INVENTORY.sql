-- =============================================================================
-- FILE: PKG_INVENTORY.sql
-- PURPOSE: Dedicated inventory management: Add/Remove stock, Reserve/Release,
--          Low-stock alerts, and bulk stock adjustments.
-- TABLES:  PRODUCT_INVENTORY, PRODUCTS
-- ACID:    Uses SELECT ... FOR UPDATE for concurrent safety.
-- =============================================================================

-- =============================================================================
-- PACKAGE SPECIFICATION (Public Interface)
-- =============================================================================
CREATE OR REPLACE PACKAGE PKG_INVENTORY AS

    -- -------------------------------------------------------------------------
    -- 1. Add stock to a product (increase quantity_on_hand).
    --    Used for receiving new shipments or manual corrections.
    -- -------------------------------------------------------------------------
    PROCEDURE add_stock(
        p_product_id IN NUMBER,
        p_quantity   IN NUMBER,
        p_comment    IN VARCHAR2 DEFAULT 'Manual adjustment'
    );

    -- -------------------------------------------------------------------------
    -- 2. Remove stock from a product (decrease quantity_on_hand).
    --    Used for damage, theft, or manual corrections.
    --    Raises exception if quantity_on_hand is insufficient.
    -- -------------------------------------------------------------------------
    PROCEDURE remove_stock(
        p_product_id IN NUMBER,
        p_quantity   IN NUMBER,
        p_comment    IN VARCHAR2 DEFAULT 'Manual removal'
    );

    -- -------------------------------------------------------------------------
    -- 3. Reserve stock for an order (increase reserved_qty).
    --    Called during checkout before payment.
    -- -------------------------------------------------------------------------
    PROCEDURE reserve_stock(
        p_product_id IN NUMBER,
        p_quantity   IN NUMBER
    );

    -- -------------------------------------------------------------------------
    -- 4. Release reserved stock (decrease reserved_qty).
    --    Called when order is cancelled or payment fails.
    -- -------------------------------------------------------------------------
    PROCEDURE release_stock(
        p_product_id IN NUMBER,
        p_quantity   IN NUMBER
    );

    -- -------------------------------------------------------------------------
    -- 5. Get available stock (quantity_on_hand - reserved_qty) for a product.
    -- -------------------------------------------------------------------------
    FUNCTION get_available_stock(p_product_id IN NUMBER) RETURN NUMBER;

    -- -------------------------------------------------------------------------
    -- 6. Get detailed stock status for a specific product.
    --    Returns: product_id, name, sku, quantity_on_hand, reserved_qty,
    --    available, low_stock_threshold, is_low_stock_flag.
    -- -------------------------------------------------------------------------
    FUNCTION get_product_stock_status(p_product_id IN NUMBER) RETURN SYS_REFCURSOR;

    -- -------------------------------------------------------------------------
    -- 7. Get all products that are below their low_stock_threshold.
    --    Used by the purchasing team to reorder.
    -- -------------------------------------------------------------------------
    FUNCTION get_low_stock_items RETURN SYS_REFCURSOR;

    -- -------------------------------------------------------------------------
    -- 8. Get a complete inventory snapshot with all products.
    --    Includes products that don't have an inventory record (shows as NULL).
    -- -------------------------------------------------------------------------
    FUNCTION get_full_inventory_status RETURN SYS_REFCURSOR;

    -- -------------------------------------------------------------------------
    -- 9. Update the low_stock_threshold for a product.
    -- -------------------------------------------------------------------------
    PROCEDURE set_low_stock_threshold(
        p_product_id IN NUMBER,
        p_threshold  IN NUMBER
    );

    -- -------------------------------------------------------------------------
    -- 10. Bulk update: Add a fixed percentage to all product prices.
    --     Also triggers a review of low-stock thresholds (optional).
    -- -------------------------------------------------------------------------
    PROCEDURE bulk_price_update(
        p_percentage IN NUMBER,  -- e.g., 10 means +10%
        p_category_id IN NUMBER DEFAULT NULL  -- If NULL, update all
    );

    -- -------------------------------------------------------------------------
    -- 11. Reconcile inventory: Sync reserved_qty with actual orders
    --     (This is a utility to fix mismatches due to system errors).
    -- -------------------------------------------------------------------------
    PROCEDURE reconcile_inventory;

END PKG_INVENTORY;
/
SHOW ERRORS PKG_INVENTORY;

-- =============================================================================
-- PACKAGE BODY (Implementation)
-- =============================================================================
CREATE OR REPLACE PACKAGE BODY PKG_INVENTORY AS

    -- -------------------------------------------------------------------------
    -- PRIVATE EXCEPTIONS
    -- -------------------------------------------------------------------------
    e_product_not_found       EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_product_not_found, -20060);
    e_insufficient_stock      EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_insufficient_stock, -20061);
    e_invalid_quantity        EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_invalid_quantity, -20062);
    e_inventory_record_missing EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_inventory_record_missing, -20063);

    -- -------------------------------------------------------------------------
    -- PRIVATE HELPER: Ensure inventory record exists for a product.
    --                 Creates one with 0 stock if missing.
    -- -------------------------------------------------------------------------
    PROCEDURE ensure_inventory_record(p_product_id IN NUMBER) IS
        v_exists NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_exists FROM product_inventory WHERE product_id = p_product_id;
        IF v_exists = 0 THEN
            INSERT INTO product_inventory (product_id, quantity_on_hand, reserved_qty, low_stock_threshold)
            VALUES (p_product_id, 0, 0, 5);
        END IF;
    END ensure_inventory_record;

    -- -------------------------------------------------------------------------
    -- PRIVATE HELPER: Validate product exists
    -- -------------------------------------------------------------------------
    PROCEDURE validate_product(p_product_id IN NUMBER) IS
        v_exists NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_exists FROM products WHERE product_id = p_product_id;
        IF v_exists = 0 THEN
            RAISE e_product_not_found;
        END IF;
    END validate_product;

    -- -------------------------------------------------------------------------
    -- 1. ADD_STOCK
    -- -------------------------------------------------------------------------
    PROCEDURE add_stock(
        p_product_id IN NUMBER,
        p_quantity   IN NUMBER,
        p_comment    IN VARCHAR2 DEFAULT 'Manual adjustment'
    ) IS
    BEGIN
        -- Validate
        IF p_quantity <= 0 THEN
            RAISE_APPLICATION_ERROR(-20062, 'Quantity must be greater than 0.');
        END IF;

        validate_product(p_product_id);
        ensure_inventory_record(p_product_id);

        -- Update stock
        UPDATE product_inventory
        SET quantity_on_hand = quantity_on_hand + p_quantity,
            last_updated = SYSTIMESTAMP
        WHERE product_id = p_product_id;

        COMMIT;
        DBMS_OUTPUT.PUT_LINE('📦 Added ' || p_quantity || ' units to Product ID ' || p_product_id || '. ' || p_comment);

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END add_stock;

    -- -------------------------------------------------------------------------
    -- 2. REMOVE_STOCK (Uses SELECT FOR UPDATE to lock the row)
    -- -------------------------------------------------------------------------
    PROCEDURE remove_stock(
        p_product_id IN NUMBER,
        p_quantity   IN NUMBER,
        p_comment    IN VARCHAR2 DEFAULT 'Manual removal'
    ) IS
        v_current_on_hand NUMBER;
    BEGIN
        -- Validate
        IF p_quantity <= 0 THEN
            RAISE_APPLICATION_ERROR(-20062, 'Quantity must be greater than 0.');
        END IF;

        validate_product(p_product_id);
        ensure_inventory_record(p_product_id);

        -- ACID: Lock the row to prevent concurrent modifications
        SELECT quantity_on_hand
        INTO v_current_on_hand
        FROM product_inventory
        WHERE product_id = p_product_id
        FOR UPDATE;

        -- Check stock
        IF v_current_on_hand < p_quantity THEN
            RAISE_APPLICATION_ERROR(-20061, 
                'Insufficient stock for Product ID ' || p_product_id || 
                '. Available: ' || v_current_on_hand || ', Requested: ' || p_quantity);
        END IF;

        -- Update
        UPDATE product_inventory
        SET quantity_on_hand = quantity_on_hand - p_quantity,
            last_updated = SYSTIMESTAMP
        WHERE product_id = p_product_id;

        COMMIT;
        DBMS_OUTPUT.PUT_LINE('📦 Removed ' || p_quantity || ' units from Product ID ' || p_product_id || '. ' || p_comment);

    EXCEPTION
        WHEN e_insufficient_stock THEN
            ROLLBACK;
            RAISE;
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END remove_stock;

    -- -------------------------------------------------------------------------
    -- 3. RESERVE_STOCK
    -- -------------------------------------------------------------------------
    PROCEDURE reserve_stock(
        p_product_id IN NUMBER,
        p_quantity   IN NUMBER
    ) IS
        v_available NUMBER;
    BEGIN
        IF p_quantity <= 0 THEN
            RAISE_APPLICATION_ERROR(-20062, 'Quantity must be greater than 0.');
        END IF;

        validate_product(p_product_id);
        ensure_inventory_record(p_product_id);

        -- Lock the row
        SELECT quantity_on_hand - reserved_qty
        INTO v_available
        FROM product_inventory
        WHERE product_id = p_product_id
        FOR UPDATE;

        IF v_available < p_quantity THEN
            RAISE_APPLICATION_ERROR(-20061, 
                'Cannot reserve. Insufficient available stock for Product ID ' || p_product_id || 
                '. Available: ' || v_available || ', Requested: ' || p_quantity);
        END IF;

        -- Increase reserved_qty
        UPDATE product_inventory
        SET reserved_qty = reserved_qty + p_quantity,
            last_updated = SYSTIMESTAMP
        WHERE product_id = p_product_id;

        COMMIT;
        DBMS_OUTPUT.PUT_LINE('🔒 Reserved ' || p_quantity || ' units for Product ID ' || p_product_id);

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END reserve_stock;

    -- -------------------------------------------------------------------------
    -- 4. RELEASE_STOCK
    -- -------------------------------------------------------------------------
    PROCEDURE release_stock(
        p_product_id IN NUMBER,
        p_quantity   IN NUMBER
    ) IS
        v_reserved NUMBER;
    BEGIN
        IF p_quantity <= 0 THEN
            RAISE_APPLICATION_ERROR(-20062, 'Quantity must be greater than 0.');
        END IF;

        validate_product(p_product_id);
        ensure_inventory_record(p_product_id);

        -- Lock and check current reserved_qty
        SELECT reserved_qty
        INTO v_reserved
        FROM product_inventory
        WHERE product_id = p_product_id
        FOR UPDATE;

        IF v_reserved < p_quantity THEN
            RAISE_APPLICATION_ERROR(-20064, 'Cannot release. Only ' || v_reserved || ' units are reserved.');
        END IF;

        -- Decrease reserved_qty
        UPDATE product_inventory
        SET reserved_qty = reserved_qty - p_quantity,
            last_updated = SYSTIMESTAMP
        WHERE product_id = p_product_id;

        COMMIT;
        DBMS_OUTPUT.PUT_LINE('🔓 Released ' || p_quantity || ' units for Product ID ' || p_product_id);

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END release_stock;

    -- -------------------------------------------------------------------------
    -- 5. GET_AVAILABLE_STOCK
    -- -------------------------------------------------------------------------
    FUNCTION get_available_stock(p_product_id IN NUMBER) RETURN NUMBER IS
        v_available NUMBER;
    BEGIN
        SELECT NVL(quantity_on_hand - reserved_qty, 0)
        INTO v_available
        FROM product_inventory
        WHERE product_id = p_product_id;

        RETURN v_available;

    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN 0;
        WHEN OTHERS THEN
            RAISE;
    END get_available_stock;

    -- -------------------------------------------------------------------------
    -- 6. GET_PRODUCT_STOCK_STATUS
    -- -------------------------------------------------------------------------
    FUNCTION get_product_stock_status(p_product_id IN NUMBER) RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT 
                p.product_id,
                p.product_name,
                p.sku,
                p.current_price,
                NVL(pv.quantity_on_hand, 0) AS quantity_on_hand,
                NVL(pv.reserved_qty, 0) AS reserved_qty,
                NVL(pv.quantity_on_hand - pv.reserved_qty, 0) AS available_qty,
                NVL(pv.low_stock_threshold, 5) AS low_stock_threshold,
                CASE WHEN NVL(pv.quantity_on_hand - pv.reserved_qty, 0) < NVL(pv.low_stock_threshold, 5) 
                     THEN 'LOW' ELSE 'OK' END AS stock_status
            FROM products p
            LEFT JOIN product_inventory pv ON p.product_id = pv.product_id
            WHERE p.product_id = p_product_id;
        RETURN v_cursor;
    END get_product_stock_status;

    -- -------------------------------------------------------------------------
    -- 7. GET_LOW_STOCK_ITEMS
    -- -------------------------------------------------------------------------
    FUNCTION get_low_stock_items RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT 
                p.product_id,
                p.product_name,
                p.sku,
                NVL(pv.quantity_on_hand, 0) AS quantity_on_hand,
                NVL(pv.reserved_qty, 0) AS reserved_qty,
                NVL(pv.quantity_on_hand - pv.reserved_qty, 0) AS available_qty,
                NVL(pv.low_stock_threshold, 5) AS low_stock_threshold,
                (NVL(pv.low_stock_threshold, 5) - NVL(pv.quantity_on_hand - pv.reserved_qty, 0)) AS deficit
            FROM products p
            JOIN product_inventory pv ON p.product_id = pv.product_id
            WHERE NVL(pv.quantity_on_hand - pv.reserved_qty, 0) < NVL(pv.low_stock_threshold, 5)
            ORDER BY deficit DESC;
        RETURN v_cursor;
    END get_low_stock_items;

    -- -------------------------------------------------------------------------
    -- 8. GET_FULL_INVENTORY_STATUS
    -- -------------------------------------------------------------------------
    FUNCTION get_full_inventory_status RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT 
                p.product_id,
                p.product_name,
                p.sku,
                p.current_price,
                c.category_name,
                NVL(pv.quantity_on_hand, 0) AS quantity_on_hand,
                NVL(pv.reserved_qty, 0) AS reserved_qty,
                NVL(pv.quantity_on_hand - pv.reserved_qty, 0) AS available_qty,
                NVL(pv.low_stock_threshold, 5) AS low_stock_threshold,
                CASE WHEN NVL(pv.quantity_on_hand - pv.reserved_qty, 0) < NVL(pv.low_stock_threshold, 5) 
                     THEN '🔴 LOW' ELSE '🟢 OK' END AS status_indicator
            FROM products p
            LEFT JOIN categories c ON p.category_id = c.category_id
            LEFT JOIN product_inventory pv ON p.product_id = pv.product_id
            ORDER BY status_indicator DESC, p.product_name;
        RETURN v_cursor;
    END get_full_inventory_status;

    -- -------------------------------------------------------------------------
    -- 9. SET_LOW_STOCK_THRESHOLD
    -- -------------------------------------------------------------------------
    PROCEDURE set_low_stock_threshold(
        p_product_id IN NUMBER,
        p_threshold  IN NUMBER
    ) IS
    BEGIN
        IF p_threshold < 0 THEN
            RAISE_APPLICATION_ERROR(-20062, 'Threshold cannot be negative.');
        END IF;

        validate_product(p_product_id);
        ensure_inventory_record(p_product_id);

        UPDATE product_inventory
        SET low_stock_threshold = p_threshold,
            last_updated = SYSTIMESTAMP
        WHERE product_id = p_product_id;

        COMMIT;
        DBMS_OUTPUT.PUT_LINE('⚙️ Low-stock threshold for Product ID ' || p_product_id || ' set to ' || p_threshold);

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END set_low_stock_threshold;

    -- -------------------------------------------------------------------------
    -- 10. BULK_PRICE_UPDATE (Shows business-level transaction handling)
    -- -------------------------------------------------------------------------
    PROCEDURE bulk_price_update(
        p_percentage IN NUMBER,
        p_category_id IN NUMBER DEFAULT NULL
    ) IS
    BEGIN
        IF p_percentage = 0 THEN
            RETURN;
        END IF;

        -- Update prices: new_price = current_price * (1 + p_percentage/100)
        UPDATE products
        SET current_price = ROUND(current_price * (1 + p_percentage / 100), 2)
        WHERE (p_category_id IS NULL OR category_id = p_category_id);

        COMMIT;
        DBMS_OUTPUT.PUT_LINE('💰 Bulk price update completed. ' || 
                            SQL%ROWCOUNT || ' products affected. Percentage: ' || p_percentage || '%');

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END bulk_price_update;

    -- -------------------------------------------------------------------------
    -- 11. RECONCILE_INVENTORY (Admin utility to fix discrepancies)
    --     Recalculates reserved_qty based on actual PENDING/PAID orders.
    --     This is a safety net if orders were interrupted.
    -- -------------------------------------------------------------------------
    PROCEDURE reconcile_inventory IS
        v_total_reserved NUMBER;
    BEGIN
        -- Loop through all products and recalc reserved_qty from order_items
        FOR rec IN (SELECT DISTINCT product_id FROM products) LOOP
            -- Calculate total reserved quantity from orders that are not yet delivered/cancelled
            SELECT NVL(SUM(oi.quantity), 0)
            INTO v_total_reserved
            FROM order_items oi
            JOIN orders o ON oi.order_id = o.order_id
            WHERE oi.product_id = rec.product_id
              AND o.status IN ('PENDING', 'PAID', 'SHIPPED');

            -- Update reserved_qty to the calculated value
            UPDATE product_inventory
            SET reserved_qty = v_total_reserved,
                last_updated = SYSTIMESTAMP
            WHERE product_id = rec.product_id;
        END LOOP;

        COMMIT;
        DBMS_OUTPUT.PUT_LINE('✅ Inventory reconciled. All reserved quantities updated.');

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END reconcile_inventory;

END PKG_INVENTORY;
/
SHOW ERRORS PKG_INVENTORY;

