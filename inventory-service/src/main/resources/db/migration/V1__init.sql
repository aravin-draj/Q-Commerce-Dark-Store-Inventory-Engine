-- ============================================================================
-- V1__init.sql
-- Hyper-Local Q-Commerce Dark Store Inventory Engine
-- Tables:
--   1. dark_stores (Step 17)
--   2. store_inventory (Step 18)
--   3. inventory_reservations (Step 19)
--   4. inventory_reservation_items (Step 19b - Multi-SKU cart lines)
--   5. inventory_ledger (Step 20)
--   6. processed_events (Step 21)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Step 17: Dark Stores Table
-- Geographic anchor for rider delivery radius and store operating state.
-- ----------------------------------------------------------------------------
CREATE TABLE dark_stores (
    store_id            VARCHAR(36) PRIMARY KEY,
    name                VARCHAR(100) NOT NULL,
    latitude            DOUBLE PRECISION NOT NULL,
    longitude           DOUBLE PRECISION NOT NULL,
    service_radius_km   NUMERIC(4, 2) NOT NULL DEFAULT 3.00,
    status              VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    created_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT chk_store_status CHECK (status IN ('ACTIVE', 'INACTIVE', 'MAINTENANCE'))
);

-- ----------------------------------------------------------------------------
-- Step 18: Store Inventory Table
-- Core write engine: composite PK, atomic updates, and non-negative guards.
-- ----------------------------------------------------------------------------
CREATE TABLE store_inventory (
    store_id            VARCHAR(36) NOT NULL REFERENCES dark_stores(store_id) ON DELETE RESTRICT,
    sku_id              VARCHAR(50) NOT NULL,
    sku_name            VARCHAR(150) NOT NULL,
    available_qty       INT NOT NULL DEFAULT 0,
    reserved_qty        INT NOT NULL DEFAULT 0,
    version             BIGINT NOT NULL DEFAULT 0,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (store_id, sku_id),
    CONSTRAINT chk_available_qty_non_negative CHECK (available_qty >= 0),
    CONSTRAINT chk_reserved_qty_non_negative CHECK (reserved_qty >= 0)
);

CREATE INDEX idx_inventory_sku ON store_inventory (sku_id);

-- ----------------------------------------------------------------------------
-- Step 19: Inventory Reservations Table (Parent Hold Ticket)
-- Tracks 5-minute checkout holds and prevents mobile duplicate submissions.
-- ----------------------------------------------------------------------------
CREATE TABLE inventory_reservations (
    reservation_id      VARCHAR(36) PRIMARY KEY,
    store_id            VARCHAR(36) NOT NULL REFERENCES dark_stores(store_id) ON DELETE RESTRICT,
    customer_id         VARCHAR(50) NOT NULL,
    idempotency_key     VARCHAR(100) NOT NULL,
    status              VARCHAR(20) NOT NULL DEFAULT 'RESERVED',
    expires_at          TIMESTAMPTZ NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_reservation_idempotency UNIQUE (idempotency_key),
    CONSTRAINT chk_reservation_status CHECK (status IN ('RESERVED', 'CONFIRMED', 'RELEASED', 'EXPIRED'))
);

CREATE INDEX idx_reservations_status_expires 
ON inventory_reservations (status, expires_at);

CREATE INDEX idx_reservations_customer 
ON inventory_reservations (customer_id);

-- ----------------------------------------------------------------------------
-- Step 19b: Inventory Reservation Items Table (Multi-SKU Cart Lines)
-- Individual item lines belonging to a parent reservation ticket.
-- ----------------------------------------------------------------------------
CREATE TABLE inventory_reservation_items (
    item_id             BIGSERIAL PRIMARY KEY,
    reservation_id      VARCHAR(36) NOT NULL REFERENCES inventory_reservations(reservation_id) ON DELETE CASCADE,
    sku_id              VARCHAR(50) NOT NULL,
    quantity            INT NOT NULL,

    CONSTRAINT chk_item_quantity_positive CHECK (quantity > 0),
    CONSTRAINT uq_reservation_sku UNIQUE (reservation_id, sku_id)
);

CREATE INDEX idx_res_items_reservation_id 
ON inventory_reservation_items (reservation_id);

-- ----------------------------------------------------------------------------
-- Step 20: Inventory Ledger Table
-- Append-only double-entry audit trail for stock verification.
-- ----------------------------------------------------------------------------
CREATE TABLE inventory_ledger (
    ledger_id           BIGSERIAL PRIMARY KEY,
    store_id            VARCHAR(36) NOT NULL,
    sku_id              VARCHAR(50) NOT NULL,
    delta               INT NOT NULL,
    reason              VARCHAR(30) NOT NULL,
    actor_id            VARCHAR(50) NOT NULL,
    reference_id        VARCHAR(100),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT chk_ledger_reason CHECK (reason IN ('RESTOCK', 'SALE', 'DAMAGE', 'SHRINKAGE', 'CORRECTION')),
    CONSTRAINT chk_ledger_delta_nonzero CHECK (delta <> 0)
);

CREATE INDEX idx_ledger_store_sku ON inventory_ledger (store_id, sku_id);
CREATE INDEX idx_ledger_reference ON inventory_ledger (reference_id);

-- ----------------------------------------------------------------------------
-- Step 21: Processed Events Table
-- Kafka consumer deduplication barrier to guarantee exactly-once processing.
-- ----------------------------------------------------------------------------
CREATE TABLE processed_events (
    event_id            VARCHAR(100) PRIMARY KEY,
    event_type          VARCHAR(50) NOT NULL,
    processed_at        TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
