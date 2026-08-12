-- =============================================================================
-- FILE: PKG_CATALOG.sql
-- PURPOSE: Manage Product Categories, Products, and Search functionality.
-- TABLES:  CATEGORIES, CATEGORY_MANAGERS, PRODUCTS, ORDER_ITEMS
-- =============================================================================

-- =============================================================================
-- PACKAGE SPECIFICATION (Public Interface)
-- =============================================================================
CREATE OR REPLACE PACKAGE PKG_CATALOG AS

    -- -------------------------------------------------------------------------
    -- 1. CATEGORY MANAGEMENT
    -- -------------------------------------------------------------------------
    
    PROCEDURE add_category(
        p_category_name     IN VARCHAR2,
        p_parent_category_id IN NUMBER DEFAULT NULL
    );

    PROCEDURE update_category(
        p_category_id       IN NUMBER,
        p_new_name          IN VARCHAR2 DEFAULT NULL,
        p_new_parent_id     IN NUMBER DEFAULT NULL
    );

    PROCEDURE delete_category(p_category_id IN NUMBER);

    FUNCTION get_category_tree RETURN SYS_REFCURSOR;

    -- -------------------------------------------------------------------------
    -- 2. PRODUCT MANAGEMENT
    -- -------------------------------------------------------------------------
    
    PROCEDURE add_product(
        p_category_id   IN NUMBER,
        p_product_name  IN VARCHAR2,
        p_price         IN NUMBER,
        p_sku           IN VARCHAR2,
        p_description   IN CLOB DEFAULT NULL,
        p_weight_kg     IN NUMBER DEFAULT 0
    );

    PROCEDURE update_product(
        p_product_id    IN NUMBER,
        p_category_id   IN NUMBER DEFAULT NULL,
        p_product_name  IN VARCHAR2 DEFAULT NULL,
        p_price         IN NUMBER DEFAULT NULL,
        p_sku           IN VARCHAR2 DEFAULT NULL,
        p_description   IN CLOB DEFAULT NULL,
        p_weight_kg     IN NUMBER DEFAULT NULL
    );

    PROCEDURE delete_product(p_product_id IN NUMBER);

    FUNCTION get_product_details(p_product_id IN NUMBER) RETURN SYS_REFCURSOR;

    -- -------------------------------------------------------------------------
    -- 3. SEARCH & RETRIEVAL
    -- -------------------------------------------------------------------------
    
    FUNCTION search_products(
        p_keyword      IN VARCHAR2 DEFAULT NULL,
        p_category_id  IN NUMBER DEFAULT NULL,
        p_min_price    IN NUMBER DEFAULT NULL,
        p_max_price    IN NUMBER DEFAULT NULL
    ) RETURN SYS_REFCURSOR;

END PKG_CATALOG;
/
SHOW ERRORS PKG_CATALOG;

-- =============================================================================
-- PACKAGE BODY (Implementation)
-- =============================================================================
CREATE OR REPLACE PACKAGE BODY PKG_CATALOG AS

    -- -------------------------------------------------------------------------
    -- PRIVATE EXCEPTIONS
    -- -------------------------------------------------------------------------
    e_category_has_children EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_category_has_children, -20020);
    e_category_has_products EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_category_has_products, -20021);
    e_product_in_orders EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_product_in_orders, -20022);
    e_duplicate_sku EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_duplicate_sku, -20023);

    -- -------------------------------------------------------------------------
    -- 1. CATEGORY MANAGEMENT
    -- -------------------------------------------------------------------------

    PROCEDURE add_category(
        p_category_name     IN VARCHAR2,
        p_parent_category_id IN NUMBER DEFAULT NULL
    ) IS
    BEGIN
        IF p_parent_category_id IS NOT NULL THEN
            DECLARE
                v_exists NUMBER;
            BEGIN
                SELECT COUNT(*) INTO v_exists FROM categories WHERE category_id = p_parent_category_id;
                IF v_exists = 0 THEN
                    RAISE_APPLICATION_ERROR(-20024, 'Parent category ID ' || p_parent_category_id || ' does not exist.');
                END IF;
            END;
        END IF;

        INSERT INTO categories (category_name, parent_category_id)
        VALUES (p_category_name, p_parent_category_id);

        COMMIT;
        DBMS_OUTPUT.PUT_LINE('✅ Category "' || p_category_name || '" added successfully.');

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END add_category;

    PROCEDURE update_category(
        p_category_id   IN NUMBER,
        p_new_name      IN VARCHAR2 DEFAULT NULL,
        p_new_parent_id IN NUMBER DEFAULT NULL
    ) IS
    BEGIN
        DECLARE
            v_exists NUMBER;
        BEGIN
            SELECT COUNT(*) INTO v_exists FROM categories WHERE category_id = p_category_id;
            IF v_exists = 0 THEN
                RAISE_APPLICATION_ERROR(-20025, 'Category ID ' || p_category_id || ' not found.');
            END IF;
        END;

        IF p_new_parent_id IS NOT NULL THEN
            DECLARE
                v_exists NUMBER;
            BEGIN
                SELECT COUNT(*) INTO v_exists FROM categories WHERE category_id = p_new_parent_id;
                IF v_exists = 0 THEN
                    RAISE_APPLICATION_ERROR(-20024, 'Parent category ID ' || p_new_parent_id || ' does not exist.');
                END IF;
            END;
        END IF;

        UPDATE categories
        SET 
            category_name = NVL(p_new_name, category_name),
            parent_category_id = NVL(p_new_parent_id, parent_category_id)
        WHERE category_id = p_category_id;

        COMMIT;
        DBMS_OUTPUT.PUT_LINE('✅ Category ID ' || p_category_id || ' updated successfully.');

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END update_category;

    PROCEDURE delete_category(p_category_id IN NUMBER) IS
        v_count NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_count FROM categories WHERE parent_category_id = p_category_id;
        IF v_count > 0 THEN
            RAISE e_category_has_children;
        END IF;

        SELECT COUNT(*) INTO v_count FROM products WHERE category_id = p_category_id;
        IF v_count > 0 THEN
            RAISE e_category_has_products;
        END IF;

        DELETE FROM categories WHERE category_id = p_category_id;
        COMMIT;
        DBMS_OUTPUT.PUT_LINE('✅ Category ID ' || p_category_id || ' deleted successfully.');

    EXCEPTION
        WHEN e_category_has_children THEN
            RAISE_APPLICATION_ERROR(-20020, 'Cannot delete category. It has child categories.');
        WHEN e_category_has_products THEN
            RAISE_APPLICATION_ERROR(-20021, 'Cannot delete category. It has products assigned.');
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END delete_category;

    FUNCTION get_category_tree RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT 
                c.category_id,
                c.category_name,
                c.parent_category_id,
                p.category_name AS parent_category_name
            FROM categories c
            LEFT JOIN categories p ON c.parent_category_id = p.category_id
            ORDER BY NVL(c.parent_category_id, 0), c.category_name;
        RETURN v_cursor;
    END get_category_tree;

    -- -------------------------------------------------------------------------
    -- 2. PRODUCT MANAGEMENT
    -- -------------------------------------------------------------------------

    PROCEDURE add_product(
        p_category_id   IN NUMBER,
        p_product_name  IN VARCHAR2,
        p_price         IN NUMBER,
        p_sku           IN VARCHAR2,
        p_description   IN CLOB DEFAULT NULL,
        p_weight_kg     IN NUMBER DEFAULT 0
    ) IS
        v_cat_exists     NUMBER;
        v_new_product_id NUMBER; -- Variable to hold the auto-generated ID
    BEGIN
        -- Validate Category
        SELECT COUNT(*) INTO v_cat_exists FROM categories WHERE category_id = p_category_id;
        IF v_cat_exists = 0 THEN
            RAISE_APPLICATION_ERROR(-20026, 'Category ID ' || p_category_id || ' does not exist.');
        END IF;

        -- Validate unique SKU
        SELECT COUNT(*) INTO v_cat_exists FROM products WHERE sku = p_sku;
        IF v_cat_exists > 0 THEN
            RAISE e_duplicate_sku;
        END IF;

        -- Validate price
        IF p_price < 0 THEN
            RAISE_APPLICATION_ERROR(-20027, 'Price cannot be negative.');
        END IF;

       
        INSERT INTO products (
            category_id,
            product_name,
            current_price,
            sku,
            description,
            weight_kg
        ) VALUES (
            p_category_id,
            p_product_name,
            p_price,
            p_sku,
            p_description,
            p_weight_kg
        ) RETURNING product_id INTO v_new_product_id; -- Captures the generated ID

        -- Insert into inventory using the captured ID
        BEGIN
            INSERT INTO product_inventory (product_id, quantity_on_hand, low_stock_threshold)
            VALUES (v_new_product_id, 0, 5);
        EXCEPTION
            WHEN DUP_VAL_ON_INDEX THEN
                -- If inventory already exists, do nothing.
                NULL;
        END;

        COMMIT;
        DBMS_OUTPUT.PUT_LINE('✅ Product "' || p_product_name || '" (SKU: ' || p_sku || ') added successfully with ID: ' || v_new_product_id);

    EXCEPTION
        WHEN e_duplicate_sku THEN
            RAISE_APPLICATION_ERROR(-20023, 'SKU "' || p_sku || '" already exists. Please use a unique SKU.');
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END add_product;

    PROCEDURE update_product(
        p_product_id    IN NUMBER,
        p_category_id   IN NUMBER DEFAULT NULL,
        p_product_name  IN VARCHAR2 DEFAULT NULL,
        p_price         IN NUMBER DEFAULT NULL,
        p_sku           IN VARCHAR2 DEFAULT NULL,
        p_description   IN CLOB DEFAULT NULL,
        p_weight_kg     IN NUMBER DEFAULT NULL
    ) IS
        v_cat_exists NUMBER;
        v_sku_exists NUMBER;
    BEGIN
        -- Validate Product exists
        DECLARE
            v_exists NUMBER;
        BEGIN
            SELECT COUNT(*) INTO v_exists FROM products WHERE product_id = p_product_id;
            IF v_exists = 0 THEN
                RAISE_APPLICATION_ERROR(-20028, 'Product ID ' || p_product_id || ' not found.');
            END IF;
        END;

        -- Validate Category (if provided)
        IF p_category_id IS NOT NULL THEN
            SELECT COUNT(*) INTO v_cat_exists FROM categories WHERE category_id = p_category_id;
            IF v_cat_exists = 0 THEN
                RAISE_APPLICATION_ERROR(-20026, 'Category ID ' || p_category_id || ' does not exist.');
            END IF;
        END IF;

        -- Validate SKU uniqueness (if provided and changed)
        IF p_sku IS NOT NULL THEN
            SELECT COUNT(*) INTO v_sku_exists 
            FROM products 
            WHERE sku = p_sku AND product_id != p_product_id;
            IF v_sku_exists > 0 THEN
                RAISE e_duplicate_sku;
            END IF;
        END IF;

        -- Perform update
        UPDATE products
        SET 
            category_id = NVL(p_category_id, category_id),
            product_name = NVL(p_product_name, product_name),
            current_price = NVL(p_price, current_price),
            sku = NVL(p_sku, sku),
            description = NVL(p_description, description),
            weight_kg = NVL(p_weight_kg, weight_kg)
        WHERE product_id = p_product_id;

        COMMIT;
        DBMS_OUTPUT.PUT_LINE('✅ Product ID ' || p_product_id || ' updated successfully.');

    EXCEPTION
        WHEN e_duplicate_sku THEN
            RAISE_APPLICATION_ERROR(-20023, 'SKU "' || p_sku || '" already belongs to another product.');
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END update_product;

    PROCEDURE delete_product(p_product_id IN NUMBER) IS
        v_count NUMBER;
    BEGIN
        -- 1. Check if product is referenced in any orders (to maintain data integrity)
        SELECT COUNT(*) INTO v_count FROM order_items WHERE product_id = p_product_id;
        IF v_count > 0 THEN
            RAISE e_product_in_orders;
        END IF;

        -- 2. Delete from inventory first (FK constraint)
        DELETE FROM product_inventory WHERE product_id = p_product_id;

        -- 3. Delete the product
        DELETE FROM products WHERE product_id = p_product_id;

        COMMIT;
        DBMS_OUTPUT.PUT_LINE('✅ Product ID ' || p_product_id || ' deleted successfully.');

    EXCEPTION
        WHEN e_product_in_orders THEN
            RAISE_APPLICATION_ERROR(-20022, 'Cannot delete product. It is referenced in existing orders.');
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END delete_product;

    FUNCTION get_product_details(p_product_id IN NUMBER) RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT 
                p.product_id,
                p.product_name,
                p.current_price,
                p.sku,
                p.description,
                p.weight_kg,
                p.category_id,
                c.category_name,
                pv.quantity_on_hand,
                pv.low_stock_threshold
            FROM products p
            LEFT JOIN categories c ON p.category_id = c.category_id
            LEFT JOIN product_inventory pv ON p.product_id = pv.product_id
            WHERE p.product_id = p_product_id;
        RETURN v_cursor;
    END get_product_details;

    -- -------------------------------------------------------------------------
    -- 3. SEARCH & RETRIEVAL (Dynamic WHERE Clause)
    -- -------------------------------------------------------------------------

    FUNCTION search_products(
        p_keyword      IN VARCHAR2 DEFAULT NULL,
        p_category_id  IN NUMBER DEFAULT NULL,
        p_min_price    IN NUMBER DEFAULT NULL,
        p_max_price    IN NUMBER DEFAULT NULL
    ) RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
        v_sql VARCHAR2(4000);
    BEGIN
        v_sql := '
            SELECT 
                p.product_id,
                p.product_name,
                p.current_price,
                p.sku,
                c.category_name,
                pv.quantity_on_hand,
                (pv.quantity_on_hand - pv.reserved_qty) AS available_qty
            FROM products p
            LEFT JOIN categories c ON p.category_id = c.category_id
            LEFT JOIN product_inventory pv ON p.product_id = pv.product_id
            WHERE 1=1';

        IF p_keyword IS NOT NULL THEN
            v_sql := v_sql || ' AND (UPPER(p.product_name) LIKE UPPER(''%' || p_keyword || '%'') 
                                OR UPPER(p.sku) LIKE UPPER(''%' || p_keyword || '%'')
                                OR UPPER(p.description) LIKE UPPER(''%' || p_keyword || '%''))';
        END IF;

        IF p_category_id IS NOT NULL THEN
            v_sql := v_sql || ' AND p.category_id = ' || p_category_id;
        END IF;

        IF p_min_price IS NOT NULL THEN
            v_sql := v_sql || ' AND p.current_price >= ' || p_min_price;
        END IF;

        IF p_max_price IS NOT NULL THEN
            v_sql := v_sql || ' AND p.current_price <= ' || p_max_price;
        END IF;

        v_sql := v_sql || ' ORDER BY p.product_name';

        OPEN v_cursor FOR v_sql;
        RETURN v_cursor;

    EXCEPTION
        WHEN OTHERS THEN
            OPEN v_cursor FOR SELECT 'Error in search' AS error_message FROM DUAL WHERE 1=0;
            RETURN v_cursor;
    END search_products;

END PKG_CATALOG;
/