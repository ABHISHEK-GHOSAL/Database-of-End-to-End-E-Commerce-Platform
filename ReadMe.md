# 🛒 End-to-End E-Commerce Database Platform

### A Normalized, Transaction-Safe Relational Database Built with Oracle SQL & PL/SQL

> A database-centric implementation of an End-to-End E-Commerce Platform demonstrating relational database design, normalization up to BCNF, ACID transaction principles, PL/SQL programming, data integrity, concurrency control, auditing, and business-rule automation.

---

## 📌 Project Overview

This project implements the database backend of an **End-to-End E-Commerce Platform** using **Oracle SQL and PL/SQL**.

The primary objective is to demonstrate how a production-oriented relational database can model and manage core e-commerce processes while maintaining:

* Data integrity
* Minimal data redundancy
* Referential integrity
* Transaction consistency
* Concurrency control
* Business-rule enforcement
* Auditability
* Modular PL/SQL architecture

The database covers the major transactional flow:

**Customer → Product → Cart → Order → Payment → Shipment → Return**

It also includes inventory management, promotions, security, auditing, and automated low-stock alerts.

---

# 🎯 Key Database Concepts Demonstrated

| Database Concept              | Implementation                                        |
| ----------------------------- | ----------------------------------------------------- |
| Relational Database Design    | Entity-based normalized schema                        |
| 1NF                           | Atomic attributes and elimination of repeating groups |
| 2NF                           | Removal of partial dependencies                       |
| 3NF                           | Removal of transitive dependencies                    |
| BCNF                          | Determinants represented as candidate keys            |
| Primary Keys                  | Entity identification                                 |
| Foreign Keys                  | Referential integrity                                 |
| Composite Keys                | `ORDER_ITEMS`                                         |
| Unique Constraints            | SKU, email, cart-product combinations                 |
| Check Constraints             | Status, quantity, price and percentage validation     |
| ACID                          | Transaction management                                |
| Concurrency Control           | `SELECT ... FOR UPDATE`                               |
| Transaction Control           | `COMMIT`, `ROLLBACK`, `SAVEPOINT`                     |
| Stored Procedures & Functions | Business logic implementation                         |
| PL/SQL Packages               | Modular database programming                          |
| Triggers                      | Auditing and automated stock alerts                   |
| Exception Handling            | Controlled transaction failure                        |
| Collections & Records         | PL/SQL data processing                                |
| Database Auditing             | Order change tracking                                 |

---




---

# 🗄️ Core Database Schema

## 1. Customer Management

### `CUSTOMERS`

Stores customer identity and account information.

Key design decisions:

* Surrogate primary key using Oracle Identity
* Unique customer email
* Password stored as a hash
* Active/inactive status enforced using `CHECK`
* Customer address information separated into another relation

This separation prevents customer and address information from being unnecessarily duplicated across transactional records.

---

## 2. Address Management

### `CUSTOMER_ADDRESSES`

Allows a customer to maintain multiple addresses.

```text
CUSTOMERS
    │
    └──< CUSTOMER_ADDRESSES
```

Address information is maintained separately from customer information, reducing redundancy and allowing multiple addresses per customer.

---

## 3. Product & Category Management

### `CATEGORIES`

Supports hierarchical product categories using a self-referencing foreign key.

```text
CATEGORY
   │
   └── PARENT_CATEGORY
```

### `PRODUCTS`

Stores product-level information such as:

* Product name
* SKU
* Category
* Current price
* Description
* Weight

SKU is protected using a `UNIQUE` constraint to prevent duplicate product identifiers.

---

## 4. Inventory Management

### `PRODUCT_INVENTORY`

Maintains:

* Quantity on hand
* Reserved quantity
* Low-stock threshold
* Last updated timestamp

Inventory is also central to the project's concurrency-control implementation.

During critical inventory operations, rows are locked using:

```sql
SELECT quantity_on_hand
INTO v_current_on_hand
FROM product_inventory
WHERE product_id = p_product_id
FOR UPDATE;
```

This ensures that concurrent transactions cannot modify the same inventory row simultaneously while the stock operation is in progress.

---

## 5. Shopping Cart

The cart is divided into:

```text
SHOPPING_CART
      │
      └──< CART_ITEMS
```

`CART_ITEMS` stores one product per row instead of storing multiple products in a single attribute.

A unique constraint on:

```text
(CART_ID, PRODUCT_ID)
```

prevents the same product from being inserted multiple times into the same cart.

---

# 📐 Database Normalization

A major objective of this project is to demonstrate normalization from:

**1NF → 2NF → 3NF → BCNF**

Normalization helps reduce:

* Data redundancy
* Update anomalies
* Insert anomalies
* Delete anomalies
* Inconsistent data

---

# 1️⃣ First Normal Form — 1NF

A relation satisfies **1NF** when attributes contain atomic values and repeating groups are eliminated.

### Example: `CART_ITEMS`

Instead of storing:

```text
Cart ID | Products
--------|---------------------------
101     | Laptop, Mouse, Keyboard
```

the database stores:

```text
Cart ID | Product ID | Quantity
--------|------------|---------
101     | 10         | 1
101     | 20         | 1
101     | 30         | 1
```

Each row represents one product in the cart.

This eliminates multi-valued attributes and maintains atomic data.

---

# 2️⃣ Second Normal Form — 2NF

**2NF eliminates partial dependencies** on part of a composite key.

### Example: `ORDER_ITEMS`

The table uses a composite primary key:

```sql
PRIMARY KEY (ORDER_ID, PRODUCT_ID)
```

Attributes such as:

```text
QUANTITY
SNAPSHOT_PRICE
```

describe the relationship between a specific order and a specific product.

Product attributes such as:

```text
PRODUCT_NAME
CURRENT_PRICE
SKU
```

are maintained in the `PRODUCTS` table rather than being duplicated in `ORDER_ITEMS`.

This prevents product information from partially depending only on `PRODUCT_ID`.

---

## Historical Price and Normalization

The project intentionally stores:

```text
SNAPSHOT_PRICE
```

inside `ORDER_ITEMS`.

This is not unnecessary duplication.

There are two different business meanings:

```text
PRODUCTS.CURRENT_PRICE
        ↓
Current selling price


ORDER_ITEMS.SNAPSHOT_PRICE
        ↓
Price at the time of the transaction
```

Therefore, `SNAPSHOT_PRICE` represents historical transactional data and should not be replaced with the current product price.

---

# 3️⃣ Third Normal Form — 3NF

**3NF removes transitive dependencies.**

For example, an order should not unnecessarily store:

```text
ORDER_ID
CUSTOMER_ID
CUSTOMER_NAME
CITY
STATE
ZIP
```

because customer information depends on `CUSTOMER_ID`, not directly on `ORDER_ID`.

Instead, the relationships are separated:

```text
ORDERS
   │
   ├── CUSTOMER_ID
   │       │
   │       └──► CUSTOMERS
   │
   └── SHIPPING_ADDRESS_ID
           │
           └──► CUSTOMER_ADDRESSES
```

This prevents customer and address information from being duplicated across orders.

---

# 4️⃣ Boyce-Codd Normal Form — BCNF

**BCNF is stricter than 3NF.**

A relation is in BCNF when every determinant is a candidate key.

For example, consider the dependency:

```text
CATEGORY_ID → MANAGER_NAME
```

Instead of unnecessarily storing manager information in another relation, the project separates category-manager information into:

```text
CATEGORY_MANAGERS
-------------------------
CATEGORY_ID
MANAGER_NAME
APPROVAL_LEVEL
```

Here:

```text
CATEGORY_ID → MANAGER_NAME
```

and `CATEGORY_ID` acts as the key of the relation.

Therefore, the determinant is a candidate key, satisfying the BCNF requirement.

---

# 🔐 ACID Transaction Properties

The project demonstrates the four fundamental **ACID properties** through order processing and inventory management.

> **Note:** ACID behavior is provided by Oracle's transactional engine, while this project demonstrates practical use of transaction-control and concurrency mechanisms to preserve those properties during business operations.

---

## ⚛️ Atomicity

Atomicity means a transaction is treated as a single logical unit:

**Either all required operations succeed, or the transaction is rolled back.**

A simplified checkout flow is:

```text
Create Order
     ↓
Create Order Items
     ↓
Validate Inventory
     ↓
Apply Promotion
     ↓
Process Payment
     ↓
Deduct Inventory
     ↓
Clear Cart
     ↓
COMMIT
```

If a critical operation fails, rollback logic prevents the database from remaining in a partially completed state.

The order-processing package uses transaction control mechanisms including `SAVEPOINT`, `ROLLBACK`, and `COMMIT`.

---

# 🔄 Consistency

Consistency ensures that database rules remain valid before and after a transaction.

This project enforces consistency through multiple layers.

### Database Constraints

Examples include:

```sql
CHECK (quantity > 0)

CHECK (current_price >= 0)

CHECK (discount_percent BETWEEN 0 AND 100)
```

### Referential Integrity

Foreign keys ensure that relationships reference valid parent records.

### Business Validation

PL/SQL packages validate conditions such as:

* Product existence
* Inventory availability
* Promotion validity
* Order state
* Payment state

Therefore, transactions are prevented from creating invalid business states.

---

# 🔒 Isolation

Isolation controls how concurrent transactions interact with each other.

The project demonstrates row-level locking using:

```sql
SELECT ... FOR UPDATE
```

Example:

```text
Transaction A
      │
      ├── Lock inventory row
      │
      ├── Check stock
      │
      ├── Update inventory
      │
      └── COMMIT
             │
             ▼
Transaction B
      │
      └── Waits for the locked row
```

This is particularly important for inventory management.

Without proper concurrency control, two customers could simultaneously purchase the last available item.

Using row-level locking helps prevent such overselling scenarios.

---

# 💾 Durability

Durability means that once a transaction is successfully committed, its changes become permanent according to Oracle's transaction semantics.

The project uses:

```sql
COMMIT;
```

after successful transaction processing.

If an error occurs before the successful completion of the transaction, rollback mechanisms can be used to undo the transaction's changes.

---

# ⚙️ PL/SQL Architecture

Business logic is modularized into dedicated PL/SQL packages rather than being implemented as one large script.

```text
PACKAGES/
│
├── PKG_CART.sql
├── PKG_CATALOG.sql
├── PKG_INVENTORY.sql
├── PKG_ORDERS.sql
├── PKG_SECURITY.sql
└── PKG_SHIPPING.sql
```

This separation follows a **domain-oriented approach**, making the database logic easier to maintain and extend.

---

# 📦 `PKG_CART`

Responsible for shopping-cart operations.

Typical responsibilities include:

* Cart management
* Adding products
* Updating quantities
* Removing products
* Cart validation

---

# 📦 `PKG_CATALOG`

Handles product and category-related database operations.

---

# 📦 `PKG_INVENTORY`

Handles inventory-related operations such as:

* Adding stock
* Removing stock
* Reserving stock
* Validating inventory
* Preventing insufficient-stock transactions

The package uses row-level locking during critical stock operations.

---

# 📦 `PKG_ORDERS`

The central transactional package.

A simplified checkout workflow is:

```text
Shopping Cart
     ↓
Validate Customer
     ↓
Validate Products
     ↓
Validate Inventory
     ↓
Calculate Order Total
     ↓
Apply Promotion
     ↓
Create Order
     ↓
Create Order Items
     ↓
Process Payment
     ↓
Deduct Inventory
     ↓
Clear Cart
     ↓
COMMIT
```

Exception handling and transaction control are used to prevent partially completed order transactions.

---

# 📦 `PKG_SECURITY`

Provides database-side security-related functionality.

Customer credentials are not stored as plaintext passwords. Password values are stored using a hashed representation.

---

# 📦 `PKG_SHIPPING`

Handles shipment-related database operations and the order shipment lifecycle.

---

# 🔔 Database Triggers

The project uses triggers for database-level automation.

```text
TRIGGERS/
│
├── TRG_AUDIT_ORDERS.sql
└── TRG_STOCK_ALERT.sql
```

---

# 📝 Order Auditing

`TRG_AUDIT_ORDERS` captures important order modifications and records information such as:

* Action performed
* Previous status
* New status
* Previous total
* New total
* Database user
* Timestamp

This creates an audit trail for transactional changes.

The trigger demonstrates advanced PL/SQL trigger design using compound-trigger concepts and collections for handling row-level changes.

---

# 🚨 Low Stock Alert

`TRG_STOCK_ALERT` works with the `LOW_STOCK_ALERTS` table to persist low-stock conditions.

The alert structure records information such as:

```text
PRODUCT_ID
PRODUCT_NAME
SKU
CURRENT_STOCK
THRESHOLD
CREATED_AT
RESOLVED_FLAG
RESOLVED_AT
COMMENTS
```

This demonstrates how database triggers can automatically initiate business processes when data changes satisfy a specific condition.

---

# 🛡️ Data Integrity

The database uses multiple layers of integrity enforcement.

## Entity Integrity

Implemented using:

* Primary Keys
* Identity columns
* `NOT NULL` constraints

## Referential Integrity

Implemented using:

* Foreign Keys
* Parent-child relationships
* Self-referencing category relationships

## Domain Integrity

Implemented using:

* `CHECK` constraints
* Valid status values
* Quantity validation
* Price validation
* Discount validation

Examples:

```text
Quantity > 0
Price >= 0
Discount between 0 and 100
Valid order statuses
Valid payment statuses
Valid shipment statuses
```

## Key Integrity

Implemented using:

```text
PRIMARY KEY
UNIQUE
COMPOSITE PRIMARY KEY
```

Examples include:

* Unique customer email
* Unique product SKU
* Unique `(CART_ID, PRODUCT_ID)` combination


---

# 🛠️ Technology Stack

### Database

* Oracle Database
* Oracle SQL
* Oracle PL/SQL

### Database Programming

* Stored Procedures
* Functions
* Packages
* Cursors
* Records
* Collections
* Exception Handling
* Triggers

### Database Design

* Entity-Relationship Modeling
* Relational Modeling
* Functional Dependencies
* Normalization
* 1NF
* 2NF
* 3NF
* BCNF

### Transaction Management

* `COMMIT`
* `ROLLBACK`
* `SAVEPOINT`
* `SELECT ... FOR UPDATE`
* Exception-driven transaction handling

---



# 🎓 What This Project Demonstrates

This project demonstrates practical knowledge of:

```text
Relational Database Design
        ↓
Functional Dependencies
        ↓
Normalization
        ↓
Primary & Foreign Keys
        ↓
Constraints
        ↓
PL/SQL Programming
        ↓
Transaction Management
        ↓
Concurrency Control
        ↓
Business Logic
        ↓
Database Automation
        ↓
Auditing
```

The database is not treated merely as a data-storage layer.

Instead, it acts as an **active transactional layer** responsible for:

* Maintaining data integrity
* Enforcing relationships
* Validating business rules
* Managing transactions
* Controlling concurrent access
* Automating database operations
* Maintaining audit information

---

# 🚀 Future Enhancements

Potential extensions include:

* Database indexing and execution-plan analysis
* Query performance benchmarking
* Materialized views for analytics
* Table partitioning for large transactional datasets
* Advanced role-based database security
* PL/SQL unit testing
* Automated deployment scripts
* Database migration/version-control framework
* Advanced reporting views
* Deadlock and concurrency test scenarios
* Performance monitoring and optimization

---

# 👨‍💻 Author

**Abhishek Ghosal**

Oracle SQL & PL/SQL Developer | Database Enthusiast

### Areas of Interest

* Oracle Database
* SQL & PL/SQL
* Relational Database Design
* Database Development
* Enterprise Application Databases
* Transaction Processing

---

## ⭐ Project Focus

> **Design a normalized relational database, enforce integrity at the database layer, implement transactional business logic using PL/SQL, and demonstrate ACID and concurrency-control principles through a realistic end-to-end e-commerce workflow.**
