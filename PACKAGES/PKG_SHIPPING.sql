-- =============================================================================
-- FILE: PKG_SHIPPING.sql
-- PURPOSE: Manage order fulfillment (shipments) and reverse logistics (returns).
-- TABLES:  SHIPMENTS, RETURNS, ORDERS, PAYMENTS, ORDER_ITEMS
-- DEPENDENCIES: PKG_INVENTORY (add_stock), PKG_ORDERS (indirectly via status).
-- =============================================================================

-- =============================================================================
-- PACKAGE SPECIFICATION (Public Interface)
-- =============================================================================
CREATE OR REPLACE PACKAGE PKG_SHIPPING AS

    -- -------------------------------------------------------------------------
    -- 1. Create a shipment for a paid/shippable order.
    --    Generates a mock tracking number and sets status to 'IN_TRANSIT'.
    -- -------------------------------------------------------------------------
    PROCEDURE create_shipment(
        p_order_id      IN NUMBER,
        p_carrier_name  IN VARCHAR2 DEFAULT 'FedEx',
        p_customer_id   IN NUMBER DEFAULT NULL  -- Optional ownership check
    );

    -- -------------------------------------------------------------------------
    -- 2. Update tracking number for an existing shipment.
    -- -------------------------------------------------------------------------
    PROCEDURE update_tracking(
        p_shipment_id    IN NUMBER,
        p_new_tracking   IN VARCHAR2
    );

    -- -------------------------------------------------------------------------
    -- 3. Mark a shipment as delivered.
    --    Updates shipment status to 'DELIVERED' and order status to 'DELIVERED'.
    -- -------------------------------------------------------------------------
    PROCEDURE mark_as_delivered(
        p_shipment_id IN NUMBER
    );

    -- -------------------------------------------------------------------------
    -- 4. Mark a shipment as returned (received back from carrier).
    --    Used when a customer returns the physical goods.
    -- -------------------------------------------------------------------------
    PROCEDURE mark_shipment_returned(
        p_shipment_id IN NUMBER
    );

    -- -------------------------------------------------------------------------
    -- 5. Process a return request (creates a return record).
    --    Status is set to 'PENDING' initially.
    --    Reason must be provided.
    -- -------------------------------------------------------------------------
    PROCEDURE request_return(
        p_order_id   IN NUMBER,
        p_customer_id IN NUMBER,
        p_reason     IN VARCHAR2
    );

    -- -------------------------------------------------------------------------
    -- 6. Approve a return request.
    --    - Validates return window (30 days from order date).
    --    - Restocks all items from the order (calls PKG_INVENTORY.add_stock).
    --    - Issues a full refund (updates PAYMENTS to 'REFUNDED').
    --    - Updates ORDER status to 'RETURNED'.
    --    - Updates RETURN status to 'APPROVED'.
    -- -------------------------------------------------------------------------
    PROCEDURE approve_return(
        p_return_id IN NUMBER
    );

    -- -------------------------------------------------------------------------
    -- 7. Reject a return request.
    --    Updates RETURN status to 'REJECTED' and provides a reason.
    -- -------------------------------------------------------------------------
    PROCEDURE reject_return(
        p_return_id  IN NUMBER,
        p_reason     IN VARCHAR2 DEFAULT 'Return not approved'
    );

    -- -------------------------------------------------------------------------
    -- 8. Get shipment status (tracking info) for a given order.
    -- -------------------------------------------------------------------------
    FUNCTION get_shipment_by_order(p_order_id IN NUMBER) RETURN SYS_REFCURSOR;

    -- -------------------------------------------------------------------------
    -- 9. Get return status for a given order.
    -- -------------------------------------------------------------------------
    FUNCTION get_return_by_order(p_order_id IN NUMBER) RETURN SYS_REFCURSOR;

    -- -------------------------------------------------------------------------
    -- 10. Get all pending return requests for the admin dashboard.
    -- -------------------------------------------------------------------------
    FUNCTION get_pending_returns RETURN SYS_REFCURSOR;

END PKG_SHIPPING;
/
SHOW ERRORS PKG_SHIPPING;

-- =============================================================================
-- PACKAGE BODY (Implementation)
-- =============================================================================
CREATE OR REPLACE PACKAGE BODY PKG_SHIPPING AS

    -- -------------------------------------------------------------------------
    -- PRIVATE EXCEPTIONS
    -- -------------------------------------------------------------------------
    e_order_not_found       EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_order_not_found, -20070);
    e_invalid_order_status  EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_invalid_order_status, -20071);
    e_shipment_exists       EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_shipment_exists, -20072);
    e_return_exists         EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_return_exists, -20073);
    e_return_window_expired EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_return_window_expired, -20074);
    e_invalid_return_status EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_invalid_return_status, -20075);
    e_shipment_not_found    EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_shipment_not_found, -20076);
    e_return_not_found      EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_return_not_found, -20077);
    e_customer_mismatch     EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_customer_mismatch, -20078);

    -- -------------------------------------------------------------------------
    -- PRIVATE HELPERS
    -- -------------------------------------------------------------------------

    -- Generate a mock tracking number
    FUNCTION generate_tracking_number(p_order_id IN NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN 'TRK-' || TO_CHAR(SYSDATE, 'YYYYMMDD') || '-' || p_order_id || '-' || 
               DBMS_RANDOM.STRING('X', 6);
    END generate_tracking_number;

    -- Validate order exists and get its status
    PROCEDURE validate_order(
        p_order_id    IN NUMBER,
        p_customer_id IN NUMBER DEFAULT NULL,
        p_required_status OUT VARCHAR2
    ) IS
        v_cust_id NUMBER;
    BEGIN
        SELECT customer_id, status
        INTO v_cust_id, p_required_status
        FROM orders
        WHERE order_id = p_order_id;

        IF p_customer_id IS NOT NULL AND v_cust_id != p_customer_id THEN
            RAISE e_customer_mismatch;
        END IF;

    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20070, 'Order ID ' || p_order_id || ' not found.');
        WHEN OTHERS THEN
            RAISE;
    END validate_order;

    -- -------------------------------------------------------------------------
    -- 1. CREATE_SHIPMENT
    -- -------------------------------------------------------------------------
    PROCEDURE create_shipment(
        p_order_id      IN NUMBER,
        p_carrier_name  IN VARCHAR2 DEFAULT 'FedEx',
        p_customer_id   IN NUMBER DEFAULT NULL
    ) IS
        v_order_status  VARCHAR2(20);
        v_shipment_id   NUMBER;
        v_tracking      VARCHAR2(50);
    BEGIN
        -- Validate order and status
        validate_order(p_order_id, p_customer_id, v_order_status);

        -- Only PAID or SHIPPED orders can be shipped (already PAID, or previously SHIPPED)
        IF v_order_status NOT IN ('PAID', 'SHIPPED') THEN
            RAISE_APPLICATION_ERROR(-20071, 'Order is in status "' || v_order_status || 
                '". Only PAID or SHIPPED orders can be shipped.');
        END IF;

        -- Check if shipment already exists
        DECLARE
            v_count NUMBER;
        BEGIN
            SELECT COUNT(*) INTO v_count FROM shipments WHERE order_id = p_order_id;
            IF v_count > 0 THEN
                RAISE e_shipment_exists;
            END IF;
        END;

        -- Generate tracking
        v_tracking := generate_tracking_number(p_order_id);

        -- Insert shipment
        INSERT INTO shipments (
            order_id,
            tracking_number,
            carrier_name,
            shipped_date,
            status
        ) VALUES (
            p_order_id,
            v_tracking,
            p_carrier_name,
            SYSDATE,
            'IN_TRANSIT'
        ) RETURNING shipment_id INTO v_shipment_id;

        -- Update order status to 'SHIPPED'
        UPDATE orders SET status = 'SHIPPED' WHERE order_id = p_order_id;

        COMMIT;
        DBMS_OUTPUT.PUT_LINE('🚚 Shipment ' || v_shipment_id || ' created for Order ' || p_order_id || 
                             '. Tracking: ' || v_tracking);

    EXCEPTION
        WHEN e_shipment_exists THEN
            RAISE_APPLICATION_ERROR(-20072, 'A shipment already exists for Order ' || p_order_id);
        WHEN e_customer_mismatch THEN
            RAISE_APPLICATION_ERROR(-20078, 'Order does not belong to this customer.');
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END create_shipment;

    -- -------------------------------------------------------------------------
    -- 2. UPDATE_TRACKING
    -- -------------------------------------------------------------------------
    PROCEDURE update_tracking(
        p_shipment_id    IN NUMBER,
        p_new_tracking   IN VARCHAR2
    ) IS
        v_exists NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_exists FROM shipments WHERE shipment_id = p_shipment_id;
        IF v_exists = 0 THEN
            RAISE e_shipment_not_found;
        END IF;

        UPDATE shipments
        SET tracking_number = p_new_tracking
        WHERE shipment_id = p_shipment_id;

        COMMIT;
        DBMS_OUTPUT.PUT_LINE('📦 Tracking updated for Shipment ' || p_shipment_id || ': ' || p_new_tracking);

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END update_tracking;

    -- -------------------------------------------------------------------------
    -- 3. MARK_AS_DELIVERED
    -- -------------------------------------------------------------------------
    PROCEDURE mark_as_delivered(
        p_shipment_id IN NUMBER
    ) IS
        v_order_id NUMBER;
    BEGIN
        -- Get the associated order ID
        SELECT order_id INTO v_order_id
        FROM shipments
        WHERE shipment_id = p_shipment_id;

        -- Update shipment
        UPDATE shipments
        SET status = 'DELIVERED',
            delivered_date = SYSDATE
        WHERE shipment_id = p_shipment_id;

        -- Update order status to 'DELIVERED'
        UPDATE orders
        SET status = 'DELIVERED'
        WHERE order_id = v_order_id;

        COMMIT;
        DBMS_OUTPUT.PUT_LINE('✅ Shipment ' || p_shipment_id || ' marked as DELIVERED. Order ' || v_order_id || ' completed.');

    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20076, 'Shipment ID ' || p_shipment_id || ' not found.');
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END mark_as_delivered;

    -- -------------------------------------------------------------------------
    -- 4. MARK_SHIPMENT_RETURNED (Physical return of goods)
    -- -------------------------------------------------------------------------
    PROCEDURE mark_shipment_returned(
        p_shipment_id IN NUMBER
    ) IS
        v_order_id NUMBER;
    BEGIN
        SELECT order_id INTO v_order_id
        FROM shipments
        WHERE shipment_id = p_shipment_id;

        UPDATE shipments
        SET status = 'RETURNED'
        WHERE shipment_id = p_shipment_id;

        COMMIT;
        DBMS_OUTPUT.PUT_LINE('🔄 Shipment ' || p_shipment_id || ' marked as RETURNED. Awaiting refund process.');

    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20076, 'Shipment ID ' || p_shipment_id || ' not found.');
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END mark_shipment_returned;

    -- -------------------------------------------------------------------------
    -- 5. REQUEST_RETURN
    -- -------------------------------------------------------------------------
    PROCEDURE request_return(
        p_order_id   IN NUMBER,
        p_customer_id IN NUMBER,
        p_reason     IN VARCHAR2
    ) IS
        v_order_status VARCHAR2(20);
        v_payment_id   NUMBER;
        v_return_id    NUMBER;
    BEGIN
        -- Validate order and ownership
        validate_order(p_order_id, p_customer_id, v_order_status);

        -- Only DELIVERED orders can be returned (or SHIPPED if you allow)
        IF v_order_status NOT IN ('DELIVERED', 'SHIPPED') THEN
            RAISE_APPLICATION_ERROR(-20071, 'Order is in status "' || v_order_status || 
                '". Only DELIVERED or SHIPPED orders can be returned.');
        END IF;

        -- Check if return already exists
        DECLARE
            v_count NUMBER;
        BEGIN
            SELECT COUNT(*) INTO v_count FROM returns WHERE order_id = p_order_id;
            IF v_count > 0 THEN
                RAISE e_return_exists;
            END IF;
        END;

        -- Get payment_id
        SELECT payment_id INTO v_payment_id
        FROM payments
        WHERE order_id = p_order_id AND status = 'SUCCESS';

        -- Insert return request
        INSERT INTO returns (
            order_id,
            payment_id,
            return_date,
            reason,
            return_status,
            refund_amount,
            restock_status
        ) VALUES (
            p_order_id,
            v_payment_id,
            SYSDATE,
            p_reason,
            'PENDING',
            NULL,   -- To be set on approval
            'N'
        ) RETURNING return_id INTO v_return_id;

        COMMIT;
        DBMS_OUTPUT.PUT_LINE('📩 Return request ' || v_return_id || ' created for Order ' || p_order_id || 
                             '. Status: PENDING.');

    EXCEPTION
        WHEN e_return_exists THEN
            RAISE_APPLICATION_ERROR(-20073, 'A return request already exists for Order ' || p_order_id);
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20079, 'No successful payment found for this order.');
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END request_return;

    -- -------------------------------------------------------------------------
    -- 6. APPROVE_RETURN (The complex business transaction)
    --    This is an ACID operation: restock + refund must happen together.
    -- -------------------------------------------------------------------------
    PROCEDURE approve_return(
        p_return_id IN NUMBER
    ) IS
        v_order_id      NUMBER;
        v_payment_id    NUMBER;
        v_order_total   NUMBER;
        v_order_status  VARCHAR2(20);
    BEGIN
        -- -----------------------------------------------------------------
        -- 1. Validate return exists and is PENDING
        -- -----------------------------------------------------------------
        SELECT order_id, payment_id, return_status
        INTO v_order_id, v_payment_id, v_order_status
        FROM returns
        WHERE return_id = p_return_id;

        IF v_order_status != 'PENDING' THEN
            RAISE_APPLICATION_ERROR(-20075, 'Return is not in PENDING state. Current status: ' || v_order_status);
        END IF;

        -- -----------------------------------------------------------------
        -- 2. Validate return window (30 days from order date)
        -- -----------------------------------------------------------------
        DECLARE
            v_order_date DATE;
            v_days_diff  NUMBER;
        BEGIN
            SELECT order_date INTO v_order_date FROM orders WHERE order_id = v_order_id;
            v_days_diff := TRUNC(SYSDATE - v_order_date);
            IF v_days_diff > 30 THEN
                RAISE_APPLICATION_ERROR(-20074, 'Return window expired. Order was placed ' || v_days_diff || ' days ago. Max 30 days.');
            END IF;
        END;

        -- -----------------------------------------------------------------
        -- 3. Get order total (refund amount)
        -- -----------------------------------------------------------------
        SELECT total_amount INTO v_order_total
        FROM orders
        WHERE order_id = v_order_id;

        -- -----------------------------------------------------------------
        -- 4. START TRANSACTION with SAVEPOINT for ACID
        -- -----------------------------------------------------------------
        SAVEPOINT sp_return_approval;

        -- -----------------------------------------------------------------
        -- 5. Restock all items from the order (call PKG_INVENTORY)
        --    Loop through order_items and add stock back.
        -- -----------------------------------------------------------------
        FOR rec IN (SELECT product_id, quantity FROM order_items WHERE order_id = v_order_id) LOOP
            -- Call the add_stock procedure from PKG_INVENTORY
            -- Note: PKG_INVENTORY.add_stock has its own COMMIT, but since we are inside 
            -- a bigger transaction, Oracle will handle it as part of the outer transaction.
            -- However, to be safe, we manage our own SAVEPOINT.
            PKG_INVENTORY.add_stock(
                p_product_id => rec.product_id,
                p_quantity   => rec.quantity,
                p_comment    => 'Restock from Return #' || p_return_id
            );
        END LOOP;

        -- -----------------------------------------------------------------
        -- 6. Issue refund: Update payment status to REFUNDED
        -- -----------------------------------------------------------------
        UPDATE payments
        SET status = 'REFUNDED'
        WHERE payment_id = v_payment_id;

        -- -----------------------------------------------------------------
        -- 7. Update order status to RETURNED
        -- -----------------------------------------------------------------
        UPDATE orders
        SET status = 'RETURNED'
        WHERE order_id = v_order_id;

        -- -----------------------------------------------------------------
        -- 8. Update return record
        -- -----------------------------------------------------------------
        UPDATE returns
        SET 
            return_status = 'APPROVED',
            refund_amount = v_order_total,
            restock_status = 'Y'
        WHERE return_id = p_return_id;

        -- -----------------------------------------------------------------
        -- 9. COMMIT - All changes are permanent
        -- -----------------------------------------------------------------
        COMMIT;

        DBMS_OUTPUT.PUT_LINE('✅ Return ' || p_return_id || ' APPROVED. Refund issued: $' || v_order_total || 
                             '. Stock restored. Order ' || v_order_id || ' is now RETURNED.');

    EXCEPTION
        WHEN e_return_window_expired THEN
            ROLLBACK TO sp_return_approval;
            RAISE;
        WHEN OTHERS THEN
            ROLLBACK TO sp_return_approval;
            -- Update return status to REJECTED automatically on error?
            -- Let's keep it PENDING and raise the error so admin can investigate.
            RAISE_APPLICATION_ERROR(-20080, 'Error processing return: ' || SQLERRM);
    END approve_return;

    -- -------------------------------------------------------------------------
    -- 7. REJECT_RETURN
    -- -------------------------------------------------------------------------
    PROCEDURE reject_return(
        p_return_id  IN NUMBER,
        p_reason     IN VARCHAR2 DEFAULT 'Return not approved'
    ) IS
        v_status VARCHAR2(20);
    BEGIN
        SELECT return_status INTO v_status
        FROM returns
        WHERE return_id = p_return_id;

        IF v_status != 'PENDING' THEN
            RAISE_APPLICATION_ERROR(-20075, 'Return is not in PENDING state.');
        END IF;

        UPDATE returns
        SET 
            return_status = 'REJECTED',
            reason = reason || ' | REJECTED: ' || p_reason
        WHERE return_id = p_return_id;

        COMMIT;
        DBMS_OUTPUT.PUT_LINE('❌ Return ' || p_return_id || ' REJECTED. Reason: ' || p_reason);

    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20077, 'Return ID ' || p_return_id || ' not found.');
        WHEN OTHERS THEN
            ROLLBACK;
            RAISE;
    END reject_return;

    -- -------------------------------------------------------------------------
    -- 8. GET_SHIPMENT_BY_ORDER
    -- -------------------------------------------------------------------------
    FUNCTION get_shipment_by_order(p_order_id IN NUMBER) RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT 
                shipment_id,
                tracking_number,
                carrier_name,
                shipped_date,
                delivered_date,
                status
            FROM shipments
            WHERE order_id = p_order_id;
        RETURN v_cursor;
    END get_shipment_by_order;

    -- -------------------------------------------------------------------------
    -- 9. GET_RETURN_BY_ORDER
    -- -------------------------------------------------------------------------
    FUNCTION get_return_by_order(p_order_id IN NUMBER) RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT 
                return_id,
                payment_id,
                return_date,
                reason,
                return_status,
                refund_amount,
                restock_status
            FROM returns
            WHERE order_id = p_order_id;
        RETURN v_cursor;
    END get_return_by_order;

    -- -------------------------------------------------------------------------
    -- 10. GET_PENDING_RETURNS (Admin dashboard)
    -- -------------------------------------------------------------------------
    FUNCTION get_pending_returns RETURN SYS_REFCURSOR IS
        v_cursor SYS_REFCURSOR;
    BEGIN
        OPEN v_cursor FOR
            SELECT 
                r.return_id,
                r.order_id,
                o.customer_id,
                c.full_name AS customer_name,
                r.return_date,
                r.reason,
                o.total_amount AS order_total,
                o.status AS order_status
            FROM returns r
            JOIN orders o ON r.order_id = o.order_id
            JOIN customers c ON o.customer_id = c.customer_id
            WHERE r.return_status = 'PENDING'
            ORDER BY r.return_date ASC;
        RETURN v_cursor;
    END get_pending_returns;

END PKG_SHIPPING;
/
SHOW ERRORS PKG_SHIPPING;

