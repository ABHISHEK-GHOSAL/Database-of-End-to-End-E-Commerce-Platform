-- =============================================================================
-- FILE: PKG_CART.sql
-- PURPOSE: Manage Shopping Cart operations: Add, Update, Remove, View, Clear.
-- TABLES:  SHOPPING_CART, CART_ITEMS, PRODUCTS, PRODUCT_INVENTORY
-- =============================================================================

-- =============================================================================
-- PACKAGE SPECIFICATION (Public Interface)
-- =============================================================================
CREATE OR REPLACE PACKAGE PKG_CART AS

    -- -------------------------------------------------------------------------
    -- 1. Get or Create an active cart for a customer.
    --    Returns the CART_ID. If no active cart exists, creates one.
    -- -------------------------------------------------------------------------
    FUNCTION get_or_create_cart(p_customer_id IN NUMBER) RETURN NUMBER;

    -- -------------------------------------------------------------------------
    -- 2. Add a product to the cart.
    --    If the product already exists in the cart, the quantity is increased.
    --    Raises exception if stock is insufficient.
    -- -------------------------------------------------------------------------
    PROCEDURE add_to_cart(
        p_customer_id IN NUMBER,
        p_product_id  IN NUMBER,
        p_quantity    IN NUMBER DEFAULT 1
    );

    -- -------------------------------------------------------------------------
    -- 3. Update quantity of an existing cart item.
    --    If quantity = 0, the item is removed.
    -- -------------------------------------------------------------------------
    PROCEDURE update_cart_item(
        p_customer_id IN NUMBER,
        p_product_id  IN NUMBER,
        p_quantity    IN NUMBER
    );

    -- -------------------------------------------------------------------------
    -- 4. Remove a specific product from the cart.
    -- -------------------------------------------------------------------------
    PROCEDURE remove_from_cart(
        p_customer_id IN NUMBER,
        p_product_id  IN NUMBER
    );

    -- -------------------------------------------------------------------------
    -- 5. Clear all items from the cart.
    -- -------------------------------------------------------------------------
    PROCEDURE clear_cart(p_customer_id IN NUMBER);

    -- -------------------------------------------------------------------------
    -- 6. Calculate the total amount for the cart (sum of price * quantity).
    -- -------------------------------------------------------------------------
    FUNCTION get_cart_total(p_customer_id IN NUMBER) RETURN NUMBER;

    -- -------------------------------------------------------------------------
    -- 7. View the cart with product details, quantities, and line totals.
    --    Returns a Ref Cursor with: product_id, name, sku, price, quantity,
    --    line_total, available_stock.
    -- -------------------------------------------------------------------------
    FUNCTION view_cart(p_customer_id IN NUMBER) RETURN SYS_REFCURSOR;

END PKG_CART;
/
SHOW ERRORS PKG_CART;

-- =============================================================================
-- PACKAGE BODY (Implementation)
-- =============================================================================
CREATE OR REPLACE PACKAGE BODY PKG_CART AS

    -- -------------------------------------------------------------------------
    -- PRIVATE EXCEPTIONS
    -- -------------------------------------------------------------------------
    e_cart_not_found       EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_cart_not_found, -20040);
    e_product_not_found    EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_product_not_found, -20041);
    e_insufficient_stock   EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_insufficient_stock, -20042);
    e_quantity_invalid     EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_quantity_invalid, -20043);

    -- -------------------------------------------------------------------------
    -- 1. GET_OR_CREATE_CART
    -- -------------------------------------------------------------------------
    FUNCTION get_or_create_cart(p_customer_id IN NUMBER) RETURN NUMBER IS
        v_cart_id NUMBER;
    BEGIN
        -- Check for an active cart
        SELECT cart_id
        INTO v_cart_id
        FROM shopping_cart
        WHERE customer_id = p_customer_id
          AND is_active = 'Y'
          AND ROWNUM = 1; -- Ensure we get only one (there should be only one active)

        RETURN v_cart_id;

    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            -- No active cart found. Create a new one.
            BEGIN
                INSERT INTO shopping_cart (customer_id, created_date, last_modified_date, is_active)
                VALUES (p_customer_id, SYSDATE, SYSDATE, 'Y')
                RETURNING cart_id INTO v_cart_id;

                DBMS_OUTPUT.PUT_LINE('🛒 New cart created for customer ' || p_customer_id || ' (Cart ID: ' || v_cart_id || ')');
                RETURN v_cart_id;
            END;
        WHEN OTHERS THEN
            RAISE;
    END get_or_create_cart;

    -- -------------------------------------------------------------------------
    -- PRIVATE HELPER: Validate product and check available stock
    -- -------------------------------------------------------------------------
    PROCEDURE validate_product_stock(
        p_product_id IN NUMBER,
        p_quantity   IN NUMBER
    ) IS
        v_exists      NUMBER;
        v_available   NUMBER;
        v_product_name VARCHAR2(200);
    BEGIN
        -- 1. Check if product exists
        SELECT COUNT(*), product_name
        INTO v_exists, v_product_name
        FROM products
        WHERE product_id = p_product_id
        GROUP BY product_name;

        IF v_exists = 0 THEN
            RAISE e_product_not_found;
        END IF;

        -- 2. Check available stock (quantity_on_hand - reserved_qty)
        SELECT NVL(quantity_on_hand - reserved_qty, 0)
        INTO v_available
        FROM product_inventory
        WHERE product_id = p_product_id;

        IF v_available < p_quantity THEN
            RAISE_APPLICATION_ERROR(-20042, 
                'Insufficient stock for "' || v_product_name || '". Available: ' || v_available || ', Requested: ' || p_quantity);
        END IF;

    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            -- If product exists but no inventory record, treat as 0 stock.
            RAISE_APPLICATION_ERROR(-20042, 'Product exists but inventory record is missing. Please contact support.');
        WHEN e_product_not_found THEN
            RAISE_APPLICATION_ERROR(-20041, 'Product ID ' || p_product_id || ' does not exist.');
        WHEN OTHERS THEN
            RAISE;
    END validate_product_stock;

    -- -------------------------------------------------------------------------
    -- 2. ADD_TO_CART
    -- -------------------------------------------------------------------------
    PROCEDURE add_to_cart(
        p_customer_id IN NUMBER,
        p_product_id  IN NUMBER,
        p_quantity    IN NUMBER DEFAULT 1
    ) IS
        v_cart_id      NUMBER;
        v_exists       NUMBER;
        v_curr_qty     NUMBER;
        v_new_qty      NUMBER;
    BEGIN
        -- Validate quantity
        IF p_quantity <= 0 THEN
            RAISE_APPLICATION_ERROR(-20043, 'Quantity must be greater than 0.');
        END IF;

        -- Get or create active cart
        v_cart_id := get_or_create_cart(p_customer_id);

        -- Validate stock
        validate_product_stock(p_product_id, p_quantity);

        -- Check if product already exists in this cart
        SELECT COUNT(*), quantity
        INTO v_exists, v_curr_qty
        FROM cart_items
        WHERE cart_id = v_cart_id AND product_id = p_product_id
        GROUP BY quantity; -- GROUP BY is a trick to handle no-data-found safely

        IF v_exists > 0 THEN
            -- Update existing item: add to current quantity
            v_new_qty := v_curr_qty + p_quantity;
            
            -- Re-validate stock for the combined quantity
            validate_product_stock(p_product_id, v_new_qty);

            UPDATE cart_items
            SET quantity = v_new_qty,
                added_date = SYSDATE
            WHERE cart_id = v_cart_id AND product_id = p_product_id;

            DBMS_OUTPUT.PUT_LINE('🛒 Updated quantity for Product ID ' || p_product_id || ' to ' || v_new_qty);
        ELSE
            -- Insert new item
            INSERT INTO cart_items (cart_id, product_id, quantity, added_date)
            VALUES (v_cart_id, p_product_id, p_quantity, SYSDATE);

            DBMS_OUTPUT.PUT_LINE('🛒 Added Product ID ' || p_product_id || ' (Qty: ' || p_quantity || ') to cart.');
        END IF;

        -- Update cart's last_modified_date
        UPDATE shopping_cart SET last_modified_date = SYSDATE WHERE cart_id = v_cart_id;

        COMMIT;

    EXCEPTION
        WHEN e_insufficient_stock THEN
            ROLLBACK;
            RAISE;
        WHEN e_product_not_found THEN
            ROLLBACK;
            RAISE;
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END add_to_cart;

    -- -------------------------------------------------------------------------
    -- 3. UPDATE_CART_ITEM
    -- -------------------------------------------------------------------------
    PROCEDURE update_cart_item(
        p_customer_id IN NUMBER,
        p_product_id  IN NUMBER,
        p_quantity    IN NUMBER
    ) IS
        v_cart_id      NUMBER;
        v_exists       NUMBER;
    BEGIN
        -- If quantity is 0, treat as remove
        IF p_quantity = 0 THEN
            remove_from_cart(p_customer_id, p_product_id);
            RETURN;
        END IF;

        IF p_quantity < 0 THEN
            RAISE_APPLICATION_ERROR(-20043, 'Quantity cannot be negative.');
        END IF;

        -- Get active cart
        v_cart_id := get_or_create_cart(p_customer_id);

        -- Check if item exists in cart
        SELECT COUNT(*)
        INTO v_exists
        FROM cart_items
        WHERE cart_id = v_cart_id AND product_id = p_product_id;

        IF v_exists = 0 THEN
            RAISE_APPLICATION_ERROR(-20044, 'Product ID ' || p_product_id || ' is not in your cart.');
        END IF;

        -- Validate stock for new quantity
        validate_product_stock(p_product_id, p_quantity);

        -- Update quantity
        UPDATE cart_items
        SET quantity = p_quantity,
            added_date = SYSDATE
        WHERE cart_id = v_cart_id AND product_id = p_product_id;

        -- Update cart timestamp
        UPDATE shopping_cart SET last_modified_date = SYSDATE WHERE cart_id = v_cart_id;

        COMMIT;
        DBMS_OUTPUT.PUT_LINE('🛒 Updated Product ID ' || p_product_id || ' to quantity ' || p_quantity);

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END update_cart_item;

    -- -------------------------------------------------------------------------
    -- 4. REMOVE_FROM_CART
    -- -------------------------------------------------------------------------
    PROCEDURE remove_from_cart(
        p_customer_id IN NUMBER,
        p_product_id  IN NUMBER
    ) IS
        v_cart_id      NUMBER;
        v_deleted      NUMBER;
    BEGIN
        v_cart_id := get_or_create_cart(p_customer_id);

        DELETE FROM cart_items
        WHERE cart_id = v_cart_id AND product_id = p_product_id;

        v_deleted := SQL%ROWCOUNT;

        IF v_deleted = 0 THEN
            DBMS_OUTPUT.PUT_LINE('⚠️ Product ID ' || p_product_id || ' was not in the cart.');
        ELSE
            -- Update cart timestamp
            UPDATE shopping_cart SET last_modified_date = SYSDATE WHERE cart_id = v_cart_id;
            COMMIT;
            DBMS_OUTPUT.PUT_LINE('🗑️ Removed Product ID ' || p_product_id || ' from cart.');
        END IF;

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END remove_from_cart;

    -- -------------------------------------------------------------------------
    -- 5. CLEAR_CART
    -- -------------------------------------------------------------------------
    PROCEDURE clear_cart(p_customer_id IN NUMBER) IS
        v_cart_id NUMBER;
    BEGIN
        v_cart_id := get_or_create_cart(p_customer_id);

        DELETE FROM cart_items WHERE cart_id = v_cart_id;

        UPDATE shopping_cart SET last_modified_date = SYSDATE WHERE cart_id = v_cart_id;

        COMMIT;
        DBMS_OUTPUT.PUT_LINE('🧹 Cart cleared for customer ' || p_customer_id);

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END clear_cart;

    -- -------------------------------------------------------------------------
    -- 6. GET_CART_TOTAL
    -- -------------------------------------------------------------------------
    FUNCTION get_cart_total(p_customer_id IN NUMBER) RETURN NUMBER IS
        v_cart_id NUMBER;
        v_total   NUMBER := 0;
    BEGIN
        v_cart_id := get_or_create_cart(p_customer_id);

        SELECT NVL(SUM(ci.quantity * p.current_price), 0)
        INTO v_total
        FROM cart_items ci
        JOIN products p ON ci.product_id = p.product_id
        WHERE ci.cart_id = v_cart_id;

        RETURN v_total;

    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN 0;
        WHEN OTHERS THEN
            RAISE;
    END get_cart_total;

    -- -------------------------------------------------------------------------
    -- 7. VIEW_CART
    -- -------------------------------------------------------------------------
    FUNCTION view_cart(p_customer_id IN NUMBER) RETURN SYS_REFCURSOR IS
        v_cart_id NUMBER;
        v_cursor  SYS_REFCURSOR;
    BEGIN
        v_cart_id := get_or_create_cart(p_customer_id);

        OPEN v_cursor FOR
            SELECT 
                ci.product_id,
                p.product_name,
                p.sku,
                p.current_price AS unit_price,
                ci.quantity,
                (ci.quantity * p.current_price) AS line_total,
                NVL(pv.quantity_on_hand - pv.reserved_qty, 0) AS available_stock,
                TO_CHAR(ci.added_date, 'DD-MON-YYYY HH24:MI') AS added_on
            FROM cart_items ci
            JOIN products p ON ci.product_id = p.product_id
            LEFT JOIN product_inventory pv ON p.product_id = pv.product_id
            WHERE ci.cart_id = v_cart_id
            ORDER BY ci.added_date;

        RETURN v_cursor;

    EXCEPTION
        WHEN OTHERS THEN
            -- Return an empty cursor if something fails
            OPEN v_cursor FOR SELECT 'Error fetching cart' AS message FROM DUAL WHERE 1=0;
            RETURN v_cursor;
    END view_cart;

END PKG_CART;
/