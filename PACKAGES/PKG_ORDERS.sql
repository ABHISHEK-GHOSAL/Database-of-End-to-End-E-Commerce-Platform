-- =============================================================================
-- FILE: PKG_ORDERS.sql
-- PURPOSE: Complete order lifecycle: Place Order, Cancel Order, Order History.
-- ACID DEMONSTRATION: 
--   - ATOMICITY: SAVEPOINT before payment, ROLLBACK TO on failure.
--   - CONSISTENCY: Calculates total from order items, validates stock & promo.
--   - ISOLATION: SELECT ... FOR UPDATE on inventory rows.
--   - DURABILITY: Final COMMIT writes to redo logs.
-- TABLES: ORDERS, ORDER_ITEMS, PAYMENTS, CART_ITEMS, SHOPPING_CART, 
--         PRODUCT_INVENTORY, PRODUCTS, PROMOTIONS.
-- =============================================================================

-- =============================================================================
-- PACKAGE SPECIFICATION (Public Interface)
-- =============================================================================
CREATE OR REPLACE PACKAGE PKG_ORDERS AS

    -- -------------------------------------------------------------------------
    -- 1. PLACE_ORDER: The core ACID-compliant checkout process.
    --    Moves all items from the active shopping cart to an order.
    --    Validates stock, applies coupon, processes payment (mock), 
    --    deducts inventory, and clears the cart.
    --    Returns the new ORDER_ID.
    -- -------------------------------------------------------------------------
    FUNCTION place_order(
        p_customer_id   IN NUMBER,
        p_promo_code    IN VARCHAR2 DEFAULT NULL,
        p_payment_token IN VARCHAR2 DEFAULT 'MOCK_SUCCESS' -- Simulate gateway
    ) RETURN NUMBER;

    -- -------------------------------------------------------------------------
    -- 2. CANCEL_ORDER: Cancels an order if it is still in 'PENDING' or 'PAID' state.
    --    Restores inventory if the order was already paid.
    -- -------------------------------------------------------------------------
    PROCEDURE cancel_order(
        p_order_id    IN NUMBER,
        p_customer_id IN NUMBER
    );

    -- -------------------------------------------------------------------------
    -- 3. GET_ORDER_HISTORY: Returns all orders for a customer with status.
    -- -------------------------------------------------------------------------
    FUNCTION get_order_history(p_customer_id IN NUMBER) RETURN SYS_REFCURSOR;

    -- -------------------------------------------------------------------------
    -- 4. GET_ORDER_DETAILS: Returns full order details including items, payment, shipment.
    -- -------------------------------------------------------------------------
    FUNCTION get_order_details(p_order_id IN NUMBER) RETURN SYS_REFCURSOR;

    -- -------------------------------------------------------------------------
    -- 5. GET_ORDER_ITEMS: Returns the line items for a specific order.
    -- -------------------------------------------------------------------------
    FUNCTION get_order_items(p_order_id IN NUMBER) RETURN SYS_REFCURSOR;

END PKG_ORDERS;
/
SHOW ERRORS PKG_ORDERS;

-- =============================================================================
-- PACKAGE BODY (Implementation)
-- =============================================================================
CREATE OR REPLACE PACKAGE BODY PKG_ORDERS AS

    -- -------------------------------------------------------------------------
    -- PRIVATE EXCEPTIONS
    -- -------------------------------------------------------------------------
    e_order_not_found      EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_order_not_found, -20050);
    e_cart_empty           EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_cart_empty, -20051);
    e_insufficient_stock   EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_insufficient_stock, -20052);
    e_invalid_promo        EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_invalid_promo, -20053);
    e_order_not_cancellable EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_order_not_cancellable, -20054);
    e_payment_failed       EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_payment_failed, -20055);
    e_wrong_customer       EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_wrong_customer, -20056);

    -- -------------------------------------------------------------------------
    -- PRIVATE HELPER: Validate and apply coupon (discount logic)
    -- -------------------------------------------------------------------------
    FUNCTION apply_coupon(
        p_promo_code   IN VARCHAR2,
        p_total_before IN NUMBER
    ) RETURN NUMBER IS
        v_discount_percent NUMBER;
        v_valid_to          DATE;
        v_usage_limit       NUMBER;
        v_usage_count       NUMBER;
    BEGIN
        IF p_promo_code IS NULL THEN
            RETURN p_total_before;
        END IF;

        -- Fetch promo details
        SELECT discount_percent, valid_to, usage_limit
        INTO v_discount_percent, v_valid_to, v_usage_limit
        FROM promotions
        WHERE promo_code = UPPER(p_promo_code)
          AND SYSDATE BETWEEN valid_from AND valid_to;

        -- Check usage limit (if defined)
        IF v_usage_limit IS NOT NULL THEN
            SELECT COUNT(*) INTO v_usage_count
            FROM orders
            WHERE promo_code = UPPER(p_promo_code);

            IF v_usage_count >= v_usage_limit THEN
                RAISE_APPLICATION_ERROR(-20057, 'Promo code usage limit exceeded.');
            END IF;
        END IF;

        -- Apply discount
        RETURN ROUND(p_total_before * (1 - v_discount_percent / 100), 2);

    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20053, 'Invalid or expired promo code.');
        WHEN OTHERS THEN
            RAISE;
    END apply_coupon;

    -- -------------------------------------------------------------------------
    -- PRIVATE HELPER: Mock payment gateway call
    -- -------------------------------------------------------------------------
    PROCEDURE mock_payment_gateway(
        p_order_id     IN NUMBER,
        p_amount       IN NUMBER,
        p_payment_token IN VARCHAR2,
        p_status       OUT VARCHAR2,
        p_transaction_id OUT VARCHAR2
    ) IS
    BEGIN
        -- Simulate payment processing
        IF p_payment_token = 'MOCK_SUCCESS' THEN
            p_status := 'SUCCESS';
            p_transaction_id := 'TXN-' || TO_CHAR(SYSDATE, 'YYYYMMDDHH24MISS') || '-' || p_order_id;
        ELSIF p_payment_token = 'MOCK_FAIL' THEN
            p_status := 'FAILED';
            p_transaction_id := NULL;
        ELSE
            -- Default to success for any other token (for demo purposes)
            p_status := 'SUCCESS';
            p_transaction_id := 'TXN-' || TO_CHAR(SYSDATE, 'YYYYMMDDHH24MISS') || '-' || p_order_id;
        END IF;

        -- Simulate a delay (optional)
        -- DBMS_SESSION.SLEEP(1);

        -- If we want to simulate a random failure for demo:
        -- IF DBMS_RANDOM.VALUE < 0.1 THEN ... 
    END mock_payment_gateway;

    -- -------------------------------------------------------------------------
    -- 1. PLACE_ORDER (The ACID Showcase)
    -- -------------------------------------------------------------------------
    FUNCTION place_order(
        p_customer_id   IN NUMBER,
        p_promo_code    IN VARCHAR2 DEFAULT NULL,
        p_payment_token IN VARCHAR2 DEFAULT 'MOCK_SUCCESS'
    ) RETURN NUMBER IS

        -- Order variables
        v_order_id          NUMBER;
        v_total_before      NUMBER := 0;
        v_total_after       NUMBER := 0;
        v_cart_id           NUMBER;
        v_shipping_address_id NUMBER;

        -- Payment variables
        v_payment_status    VARCHAR2(20);
        v_transaction_id    VARCHAR2(100);

        -- Stock validation cursor
        CURSOR c_cart_items IS
            SELECT ci.product_id, ci.quantity, p.current_price
            FROM cart_items ci
            JOIN products p ON ci.product_id = p.product_id
            WHERE ci.cart_id = v_cart_id;

        -- Custom exceptions
        e_stock_exception   EXCEPTION;

    BEGIN
        -- -----------------------------------------------------------------
        -- STEP 1: Get the active cart for the customer
        -- -----------------------------------------------------------------
        BEGIN
            SELECT cart_id INTO v_cart_id
            FROM shopping_cart
            WHERE customer_id = p_customer_id AND is_active = 'Y' AND ROWNUM = 1;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20051, 'Cart is empty. Add items before checkout.');
        END;

        -- Check if cart has items
        DECLARE
            v_item_count NUMBER;
        BEGIN
            SELECT COUNT(*) INTO v_item_count FROM cart_items WHERE cart_id = v_cart_id;
            IF v_item_count = 0 THEN
                RAISE_APPLICATION_ERROR(-20051, 'Cart is empty. Add items before checkout.');
            END IF;
        END;

        -- Get default shipping address (use the first shipping address for simplicity)
        BEGIN
            SELECT address_id INTO v_shipping_address_id
            FROM customer_addresses
            WHERE customer_id = p_customer_id AND is_shipping_default = 'Y' AND ROWNUM = 1;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                -- If no default, pick the first address
                SELECT address_id INTO v_shipping_address_id
                FROM customer_addresses
                WHERE customer_id = p_customer_id AND ROWNUM = 1;
        END;

        -- -----------------------------------------------------------------
        -- STEP 2: START TRANSACTION (Implicit at first DML)
        --         ATOMICITY: We will use SAVEPOINT to control rollback.
        -- -----------------------------------------------------------------

        -- SAVEPOINT A: Entire order transaction. 
        -- If anything fails before commit, everything rolls back.
        SAVEPOINT sp_order_start;

        -- -----------------------------------------------------------------
        -- STEP 3: ISOLATION - Lock inventory rows to prevent overselling.
        --         SELECT ... FOR UPDATE locks each product row until commit.
        -- -----------------------------------------------------------------
        FOR rec IN c_cart_items LOOP
            DECLARE
                v_available NUMBER;
            BEGIN
                -- Lock the specific inventory row
                SELECT quantity_on_hand - reserved_qty
                INTO v_available
                FROM product_inventory
                WHERE product_id = rec.product_id
                FOR UPDATE NOWAIT; -- NOWAIT avoids waiting indefinitely

                -- CONSISTENCY: Validate stock against requested quantity
                IF v_available < rec.quantity THEN
                    -- Store the product_id for error reporting
                    RAISE_APPLICATION_ERROR(-20052, 
                        'Insufficient stock for Product ID ' || rec.product_id || 
                        '. Available: ' || v_available || ', Requested: ' || rec.quantity);
                END IF;

                -- Calculate total before discount
                v_total_before := v_total_before + (rec.quantity * rec.current_price);
            END;
        END LOOP;

        -- -----------------------------------------------------------------
        -- STEP 4: Apply coupon (Consistency check)
        -- -----------------------------------------------------------------
        v_total_after := apply_coupon(p_promo_code, v_total_before);

        -- -----------------------------------------------------------------
        -- STEP 5: Create the Order Header (DML - starts transaction)
        -- -----------------------------------------------------------------
        INSERT INTO orders (
            customer_id,
            shipping_address_id,
            promo_code,
            order_date,
            total_amount,
            status
        ) VALUES (
            p_customer_id,
            v_shipping_address_id,
            UPPER(p_promo_code),
            SYSDATE,
            v_total_after,
            'PENDING'
        ) RETURNING order_id INTO v_order_id;

        -- -----------------------------------------------------------------
        -- STEP 6: Move cart items to ORDER_ITEMS
        --         Snapshot the price at order time.
        -- -----------------------------------------------------------------
        INSERT INTO order_items (order_id, product_id, quantity, snapshot_price)
        SELECT 
            v_order_id,
            ci.product_id,
            ci.quantity,
            p.current_price
        FROM cart_items ci
        JOIN products p ON ci.product_id = p.product_id
        WHERE ci.cart_id = v_cart_id;

        -- -----------------------------------------------------------------
        -- STEP 7: Reserve inventory (update reserved_qty) - Isolation
        --         This prevents other orders from using this stock during payment.
        -- -----------------------------------------------------------------
        UPDATE product_inventory pv
        SET reserved_qty = reserved_qty + (
            SELECT quantity FROM cart_items WHERE cart_id = v_cart_id AND product_id = pv.product_id
        )
        WHERE EXISTS (
            SELECT 1 FROM cart_items ci WHERE ci.cart_id = v_cart_id AND ci.product_id = pv.product_id
        );

        -- -----------------------------------------------------------------
        -- STEP 8: ATOMICITY CHECKPOINT - Savepoint before payment
        --         If payment fails, we rollback to this point, releasing the 
        --         reserved inventory and removing the order.
        -- -----------------------------------------------------------------
        SAVEPOINT sp_before_payment;

        -- -----------------------------------------------------------------
        -- STEP 9: Call mock payment gateway (Could raise exception)
        -- -----------------------------------------------------------------
        mock_payment_gateway(
            p_order_id       => v_order_id,
            p_amount         => v_total_after,
            p_payment_token  => p_payment_token,
            p_status         => v_payment_status,
            p_transaction_id => v_transaction_id
        );

        -- Check payment result
        IF v_payment_status = 'FAILED' THEN
            RAISE e_payment_failed;
        END IF;

        -- -----------------------------------------------------------------
        -- STEP 10: Payment successful - Record payment and finalize order
        -- -----------------------------------------------------------------

        -- Insert payment record
        INSERT INTO payments (
            order_id,
            amount,
            payment_date,
            gateway_reference,
            status
        ) VALUES (
            v_order_id,
            v_total_after,
            SYSDATE,
            v_transaction_id,
            'SUCCESS'
        );

        -- Update order status to 'PAID'
        UPDATE orders SET status = 'PAID' WHERE order_id = v_order_id;

        -- -----------------------------------------------------------------
        -- STEP 11: DURABILITY - Permanently deduct actual stock, release reserved.
        --         This is the point of no return. Once committed, data is permanent.
        -- -----------------------------------------------------------------
        UPDATE product_inventory pv
        SET 
            quantity_on_hand = quantity_on_hand - (
                SELECT quantity FROM cart_items WHERE cart_id = v_cart_id AND product_id = pv.product_id
            ),
            reserved_qty = reserved_qty - (
                SELECT quantity FROM cart_items WHERE cart_id = v_cart_id AND product_id = pv.product_id
            )
        WHERE EXISTS (
            SELECT 1 FROM cart_items ci WHERE ci.cart_id = v_cart_id AND ci.product_id = pv.product_id
        );

        -- -----------------------------------------------------------------
        -- STEP 12: Clear the cart (move items to order, so empty the cart)
        -- -----------------------------------------------------------------
        DELETE FROM cart_items WHERE cart_id = v_cart_id;
        UPDATE shopping_cart SET is_active = 'N', last_modified_date = SYSDATE WHERE cart_id = v_cart_id;

        -- -----------------------------------------------------------------
        -- STEP 13: COMMIT - DURABILITY achieved. All changes are permanent.
        --         Even if power fails after this, data is safe in redo logs.
        -- -----------------------------------------------------------------
        COMMIT;

        DBMS_OUTPUT.PUT_LINE('✅ Order ' || v_order_id || ' placed successfully! Total: $' || v_total_after);

        -- Return the new order ID to the caller
        RETURN v_order_id;

    EXCEPTION
        -- -----------------------------------------------------------------
        -- ATOMICITY: If stock validation fails, rollback everything.
        -- -----------------------------------------------------------------
        WHEN e_insufficient_stock OR e_stock_exception THEN
            ROLLBACK TO sp_order_start;
            RAISE_APPLICATION_ERROR(-20052, 'Stock validation failed. Order rolled back.');

        -- -----------------------------------------------------------------
        -- ATOMICITY: If payment fails, rollback to savepoint.
        --         Order is kept in 'PENDING' state (optional) for retry.
        -- -----------------------------------------------------------------
        WHEN e_payment_failed THEN
            -- Rollback to before payment: releases inventory, removes order items, but keeps order header.
            ROLLBACK TO sp_before_payment;

            -- Update order status to PAYMENT_FAILED so user can retry
            UPDATE orders SET status = 'PAYMENT_FAILED' WHERE order_id = v_order_id;

            -- Release reserved inventory (since payment failed)
            UPDATE product_inventory pv
            SET reserved_qty = reserved_qty - (
                SELECT quantity FROM order_items WHERE order_id = v_order_id AND product_id = pv.product_id
            )
            WHERE EXISTS (
                SELECT 1 FROM order_items oi WHERE oi.order_id = v_order_id AND oi.product_id = pv.product_id
            );

            COMMIT; -- Commit the status update

            RAISE_APPLICATION_ERROR(-20055, 'Payment failed. Order ' || v_order_id || ' is in PAYMENT_FAILED state. You may retry.');

        -- -----------------------------------------------------------------
        -- Any other exception: full rollback to start.
        -- -----------------------------------------------------------------
        WHEN OTHERS THEN
            ROLLBACK TO sp_order_start;
            RAISE;

    END place_order;

    -- -------------------------------------------------------------------------
    -- 2. CANCEL_ORDER
    -- -------------------------------------------------------------------------
    PROCEDURE cancel_order(
        p_order_id    IN NUMBER,
        p_customer_id IN NUMBER
    ) IS
        v_order_status orders.status%TYPE;
        v_total_amount orders.total_amount%TYPE;
    BEGIN
        -- Validate order exists and belongs to this customer
        SELECT status, total_amount
        INTO v_order_status, v_total_amount
        FROM orders
        WHERE order_id = p_order_id AND customer_id = p_customer_id;

        -- Check if order can be cancelled
        IF v_order_status NOT IN ('PENDING', 'PAID') THEN
            RAISE_APPLICATION_ERROR(-20054, 'Order cannot be cancelled. Current status: ' || v_order_status);
        END IF;

        -- If order is PAID, we need to restore inventory and issue a refund (mock)
        IF v_order_status = 'PAID' THEN
            -- Restore inventory (add back quantity_on_hand)
            UPDATE product_inventory pv
            SET quantity_on_hand = quantity_on_hand + (
                SELECT quantity FROM order_items WHERE order_id = p_order_id AND product_id = pv.product_id
            )
            WHERE EXISTS (
                SELECT 1 FROM order_items oi WHERE oi.order_id = p_order_id AND oi.product_id = pv.product_id
            );

            -- Mark payment as refunded (mock)
            UPDATE payments
            SET status = 'REFUNDED'
            WHERE order_id = p_order_id;
        END IF;

        -- Update order status to CANCELLED
        UPDATE orders SET status = 'CANCELLED' WHERE order_id = p_order_id;

        COMMIT;
        DBMS_OUTPUT.PUT_LINE('✅ Order ' || p_order_id || ' cancelled successfully.');

    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20050, 'Order not found or does not belong to this customer.');
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END cancel_order;

    -- -------------------------------------------------------------------------
    -- 3. GET_ORDER_HISTORY
    -- -------------------------------------------------------------------------
    FUNCTION get_order_history(p_customer_id IN NUMBER) RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT 
                order_id,
                TO_CHAR(order_date, 'DD-MON-YYYY HH24:MI') AS order_date_formatted,
                total_amount,
                status,
                promo_code
            FROM orders
            WHERE customer_id = p_customer_id
            ORDER BY order_date DESC;
        RETURN v_cursor;
    END get_order_history;

    -- -------------------------------------------------------------------------
    -- 4. GET_ORDER_DETAILS (Full details including payment & shipment)
    -- -------------------------------------------------------------------------
    FUNCTION get_order_details(p_order_id IN NUMBER) RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT 
                o.order_id,
                o.order_date,
                o.total_amount,
                o.status,
                o.promo_code,
                p.payment_id,
                p.amount AS payment_amount,
                p.status AS payment_status,
                p.gateway_reference,
                s.shipment_id,
                s.tracking_number,
                s.carrier_name,
                s.status AS shipment_status,
                s.shipped_date,
                s.delivered_date
            FROM orders o
            LEFT JOIN payments p ON o.order_id = p.order_id
            LEFT JOIN shipments s ON o.order_id = s.order_id
            WHERE o.order_id = p_order_id;
        RETURN v_cursor;
    END get_order_details;

    -- -------------------------------------------------------------------------
    -- 5. GET_ORDER_ITEMS
    -- -------------------------------------------------------------------------
    FUNCTION get_order_items(p_order_id IN NUMBER) RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT 
                oi.product_id,
                p.product_name,
                p.sku,
                oi.quantity,
                oi.snapshot_price,
                (oi.quantity * oi.snapshot_price) AS line_total
            FROM order_items oi
            JOIN products p ON oi.product_id = p.product_id
            WHERE oi.order_id = p_order_id
            ORDER BY p.product_name;
        RETURN v_cursor;
    END get_order_items;

END PKG_ORDERS;
/
SHOW ERRORS PKG_ORDERS;

