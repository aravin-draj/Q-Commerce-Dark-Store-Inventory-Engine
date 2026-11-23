# **Project Specification: Hyper-Local Q-Commerce Dark Store Inventory Engine**

## **1\. Project Overview & Scope**

The **Hyper-Local Q-Commerce Dark Store Inventory Engine** is a centralized, event-driven backend system built in **Java 21 and Spring Boot** that manages real-time, per-store inventory across a network of quick-commerce dark stores (modeled after platforms such as Blinkit, Zepto, and Swiggy Instamart).

* **System Boundary:** This is **not** a full quick-commerce clone (no mobile UI, rider GPS tracking, coupons, real payment gateway integration, or full user signup/OTP system). It is strictly the **Inventory & Store Core**—a centralized cloud backend tracking stock across multiple neighborhood dark stores simultaneously, where every inventory record and lock is scoped by store\_id and sku\_id.  
* **Core Problem Solved:** Quick-commerce systems combine three hard backend constraints:  
  1. **Hyper-local stock isolation:** Inventory availability is strictly per dark store, not a single global warehouse.  
  2. **Extreme read-to-write ratio:** High volumes of browsing traffic must be served at sub-millisecond latency without overloading the primary relational database.  
  3. **Localized flash concurrency & payment latency:** Hundreds of concurrent customers can attempt to purchase the last few units of a hot SKU at the same dark store simultaneously, while UPI/card payments introduce minutes of checkout delay and frequent abandonments.

## **2\. Actors & Data Ownership Model**

The engine serves three actors without requiring a full identity/account subsystem:

| Actor | Role / Access Level | Responsibilities |
| :---- | :---- | :---- |
| **Customer** | Public (browsing) / ROLE\_CUSTOMER (checkout) | Locate nearest serviceable dark store via GPS coordinates, browse store-specific catalog stock, initiate 5-minute checkout stock holds. |
| **Dark Store Manager** | ROLE\_STORE\_MANAGER | Onboard dark stores, record incoming restocks, log damaged/expired inventory adjustments, inspect audit logs. |
| **Automated Systems** | Internal (Kafka & Schedulers) | Order/Payment Simulator emitting UPI success, failure, and timeout events; scheduled expiry sweeper releasing abandoned holds; catalog cache updater. |

**Shared vs. Customer-Specific Data:**

* **General (per dark store):** Nearest-store geo-lookup, store catalog listings, and available SKU counts are shared across all users routed to that dark store.  
* **Customer-specific:** Checkout reservations and orders belong to a specific customer\_id (passed via request payload during early development and extracted from a verified JWT header once Gateway security is added).

## **3\. Technology Stack & Intentional Exclusions**

### **Selected Stack**

* **Language & Runtime:** Java 21 with Virtual Threads enabled (spring.threads.virtual.enabled=true) on standard Spring MVC (non-reactive).  
* **Frameworks:** Spring Boot 4.1.x (current stable line: 4.1.2), Spring Cloud 2025.1.x (Northfields release train: 2025.1.4) for Spring Cloud Gateway, Spring Data JPA, Spring Security (stateless JWT).  
* **Primary Database & Migrations:** PostgreSQL with Flyway SQL migrations.  
* **Cache, Geo-Index & Distributed Locking:** Redis with Redisson (redisson-spring-boot-starter).  
* **Event Streaming:** Apache Kafka running in KRaft mode (no Zookeeper).  
* **Testing & Benchmarking:** JUnit 5, Testcontainers (PostgreSQL \+ Redis), Grafana k6 (or Apache JMeter).  
* **Observability & Tooling:** Spring Boot Actuator, Micrometer / Prometheus metrics, OpenAPI / Swagger UI, Maven, Docker & Docker Compose.

### **Intentional Exclusions (Scope Guardrails)**

* **No Kubernetes:** Multi-instance orchestration is handled locally via Docker Compose.  
* **No Spring WebFlux / R2DBC:** Blocking JPA/Redis calls run on Java 21 Virtual Threads instead of reactive pipelines.  
* **No Netflix Eureka:** Static/Docker-DNS service routing via Spring Cloud Gateway is sufficient for 3 services.  
* **No Debezium CDC:** Event publishing uses application-level Kafka producers paired with idempotent database consumers.  
* **No Full Auth Service / Keycloak:** Authentication uses a minimal seeded JWT issuer and Gateway-level RBAC validation.  
* **No Frontend UI:** All workflows are exposed and demonstrated via REST APIs, Swagger UI, and automated load-test scripts.

## **4\. Target Microservices Architecture**

The finished architecture separates read-heavy browsing from strongly consistent inventory writes across **three Spring Boot services** behind a single **API Gateway**:

Plaintext  
                \[ Clients / Swagger / k6 Load Tester \]  
                                  \|  
                      \[ API Gateway (Port 8080\) \]  
                      \- Routes traffic & load-balances  
                        multiple Inventory Service replicas  
                      \- Stateless JWT validation & RBAC  
                        (forwards X-User-Id, X-User-Role)  
                         /        \|        \\  
                        /         \|         \\  
                       v          v          v  
  \+-----------------------+  \+--------------------+  \+-------------------------+  
  \| Store & Catalog Svc   \|  \| Inventory Service  \|  \| Order & Payment         \|  
  \| (Read Path)           \|  \| (Write Path / SoT) \|  \| Simulator               \|  
  \| \- Geo-lookup          \|  \| \- 2+ Replicas      \|  \| \- Creates orders        \|  
  \| \- Store catalog API   \|  \| \- Redisson locks   \|  \| \- Simulates UPI         \|  
  \| \- Redis Hash reads    \|  \| \- TTL reservations \|  \|   success/fail/timeout  \|  
  \+-----------------------+  \| \- Audit ledger     \|  \+-------------------------+  
        ^                    \| \- Expiry sweeper   \|              \|  
        \| (Read/Sync)        \+--------------------+              \|  
  \+-----------+                 \|         \|                      \|  
  \|   Redis   \|          (Write)\|         \|(Publish/Consume)     \|(Publish)  
  \| \- GEO     \|          \+------------+  \+-------------------------------------+  
  \| \- Hashes  \|          \| PostgreSQL \|  \|            Apache Kafka             \|  
  \| \- RLock   \|          \| (Durable   \|  \| Topics:                             \|  
  \+-----------+          \|  Primary)  \|  \|  \- inventory.updated                \|  
                         \+------------+  \|  \- order.confirmed                  \|  
                                         \|  \- payment.failed                   \|  
                                         \+-------------------------------------+

### **API Surface Design (Logical Grouping)**

* **Public Read Endpoints:**  
  * GET /api/v1/stores/nearest?lat=...\&lng=... — Finds nearest active dark store via Redis GEOSEARCH.  
  * GET /api/v1/stores/{storeId}/catalog — Reads per-store SKU stock from Redis Hashes.  
* **Customer Write Endpoints (ROLE\_CUSTOMER):**  
  * POST /api/v1/reservations (requires Idempotency-Key header) — Locks and reserves SKU quantities for 5 minutes.  
  * POST /api/v1/orders/{orderId}/pay — Triggers simulated payment outcome (SUCCESS, FAIL, TIMEOUT).  
* **Store Manager Endpoints (ROLE\_STORE\_MANAGER):**  
  * POST /api/v1/admin/stores — Registers a dark store and indexes coordinates in Redis Geo.  
  * POST /api/v1/admin/inventory/restock — Increments shelf stock and writes a RESTOCK audit entry.  
  * POST /api/v1/admin/inventory/adjust — Records damaged/expired stock and writes a DAMAGE/SHRINKAGE audit entry.  
* **Lightweight Auth Endpoint (Added in Phase 5):**  
  * POST /api/v1/auth/token — Issues signed JWTs for pre-seeded demo customer and store-manager accounts.

## **5\. Data Design (PostgreSQL & Redis)**

### **PostgreSQL Schema (Managed by Flyway)**

> 1. **dark\_stores**: store\_id (PK), name, latitude, longitude, service\_radius\_km, status, created\_at.  
> 2. **store\_inventory**: Composite PK (store\_id, sku\_id), sku\_name, available\_qty, reserved\_qty, version (for optimistic-lock benchmarking), updated\_at.  
> 3. **inventory\_reservations**: reservation\_id (PK), order\_id, customer\_id, idempotency\_key (unique), store\_id, sku\_id, qty, status (RESERVED, CONFIRMED, RELEASED, EXPIRED), expires\_at, created\_at.  
> 4. **inventory\_ledger**: Append-only audit table with ledger\_id (PK), store\_id, sku\_id, delta, reason (SALE, RESTOCK, DAMAGE, SHRINKAGE), actor\_id, reference\_id, created\_at.  
> 5. **processed\_events**: event\_id (PK), event\_type, processed\_at — enforces idempotent Kafka consumption.

### **Redis Key Conventions**

* **Geospatial Index:** stores:geo (GEOADD / GEOSEARCH mapping coordinates to store\_id).  
* **Catalog Read Cache:** store:{storeId}:stock (Redis Hash mapping skuId to available\_qty).  
* **Distributed Lock Key:** lock:store:{storeId}:sku:{skuId} (managed exclusively by Redisson RLock).

## **6\. Core Engineering Methods & Design Patterns**

> 1. **Two-Layer Concurrency Control (Zero Overselling):**  
   * **Layer 1 (Redisson Distributed Lock):** Serializes competing checkout requests across horizontally scaled JVM instances using Redisson RLock with automatic Watchdog lease renewal and atomic Lua unlock verification.  
   * **Layer 2 (Atomic Conditional SQL Safety Net):** Executes a single conditional database mutation rather than a read-modify-write cycle:  
     SQL  
     UPDATE store\_inventory  
     SET available\_qty \= available\_qty \- :qty,  
         reserved\_qty  \= reserved\_qty \+ :qty  
     WHERE store\_id \= :storeId  
       AND sku\_id \= :skuId  
       AND available\_qty \>= :qty;

     If 0 rows are updated, the request fails fast with HTTP 409 Conflict.  
   * **Toggleable Strategy Pattern for Benchmarking:** Inventory reservation supports switching between NONE (naive JPA read-then-write), DB\_OPTIMISTIC (@Version), and REDISSON\_LOCK (Redisson \+ conditional SQL) via configuration so load tests can empirically prove failure vs. safety.  
> 2. **Multi-SKU Cart Deadlock Prevention:**  
   * Multi-item checkouts sort all requested items by sku\_id ascending before acquiring locks (or using RedissonMultiLock) so concurrent carts with overlapping items never deadlock.  
> 3. **TTL Reservation Lifecycle & Double-Release Protection:**  
   * Checkouts set status \= 'RESERVED' with expires\_at \= NOW() \+ 5 minutes.  
   * Confirmed payments transition RESERVED to CONFIRMED, decrement reserved\_qty, and append a SALE row to inventory\_ledger.  
   * Failed payments (via Kafka) or abandoned holds (via a @Scheduled expiry sweeper running every 30 seconds) restore stock using a conditional state guard:  
     SQL  
     UPDATE inventory\_reservations  
     SET status \= 'RELEASED' \-- or 'EXPIRED'  
     WHERE reservation\_id \= :reservationId  
       AND status \= 'RESERVED';

     Stock is added back to available\_qty **only if** this statement modifies exactly 1 row—eliminating phantom inventory if a late payment-failure webhook races with the expiry sweeper.  
> 4. **End-to-End Idempotency:**  
   * **HTTP level:** Idempotency-Key prevents duplicate checkout holds from mobile network retries.  
   * **Kafka level:** Consumers check and insert event\_id into processed\_events inside the same @Transactional boundary as stock mutations so redelivered broker messages are safely ignored.  
> 5. **Eventual Consistency for Catalog Reads:**  
   * Every committed stock change publishes an inventory.updated Kafka event. Store & Catalog Service consumes it to refresh the corresponding Redis Hash entry, accepting slight read staleness (milliseconds) while checkout remains strongly consistent against PostgreSQL.

## **7\. Repository & Project Structure**

The project evolves from a modular single-application structure into a multi-module Maven repository:

Plaintext  
qcommerce-darkstore-inventory/  
├── docker-compose.yml                  \# Postgres, Redis, Kafka (KRaft), Kafka UI, services  
├── pom.xml                             \# Parent Maven POM (Java 21, Spring Boot 4.1.x, Spring Cloud)  
├── common-events/                      \# Shared Kafka event payloads & DTO records  
├── api-gateway/                        \# Spring Cloud Gateway, load balancing, JWT RBAC filter  
├── store-catalog-service/              \# Redis Geo lookup, Redis Hash reads, Kafka cache consumer  
├── inventory-service/                  \# Core write engine, Flyway SQL, Redisson locks, sweeper  
│   └── src/main/  
│       ├── java/.../inventory/  
│       │   ├── config/                 \# Redisson, Kafka, locking strategy config  
│       │   ├── controller/             \# Customer & Manager REST controllers  
│       │   ├── domain/                 \# Entities, DTOs, reservation state enums  
│       │   ├── locking/                \# Strategy interface \+ Naive / Optimistic / Redisson impls  
│       │   ├── messaging/              \# Kafka producer & idempotent event consumers  
│       │   ├── repository/             \# Spring Data JPA \+ atomic conditional SQL queries  
│       │   ├── scheduler/              \# TTL reservation expiry sweeper  
│       │   └── service/                \# Inventory, Reservation, Store, Ledger services  
│       └── resources/  
│           └── db/migration/           \# Flyway SQL scripts (V1\_\_init.sql, etc.)  
├── order-payment-simulator/            \# Mock order creation & UPI success/fail/timeout emitter  
├── load-tests/                         \# k6 scripts (500-VU flash burst) & benchmark results  
└── docs/  
    ├── architecture-diagram.png  
    └── DECISIONS.md                    \# Architectural Decision Records (ADRs)

## **8\. Incremental Build Plan (Monolith-First Evolution)**

The system is built incrementally so core concurrency correctness is proven before introducing distributed infrastructure complexity:

> 1. **Phase 1 — Local Infrastructure & Schema:** Configure docker-compose.yml (PostgreSQL \+ Redis), initialize the Spring Boot app, and establish Flyway migrations for all core tables.  
> 2. **Phase 2 — Single-App Inventory Core & Race-Condition Proof:** Implement store/SKU management, reservation lifecycle, audit ledger, and naive locking inside one modular Spring Boot app. Write a multi-threaded Testcontainers integration test demonstrating naive overselling, then fix it with atomic conditional SQL and double-release state guards.  
> 3. **Phase 3 — Redis Geo, Caching, Redisson Locks & Multi-Port Testing:** Integrate Redisson RLock (with ascending SKU sorting), scheduled expiry sweeper, Redis GEOSEARCH, and Redis Hash catalog caching. Run two local app instances on different ports to verify cross-JVM lock safety.  
> 4. **Phase 4 — Kafka Integration & Service Split:** Add Kafka (KRaft) to Docker Compose, refactor the modular monolith into store-catalog-service, inventory-service, and order-payment-simulator, wire inventory.updated / order.confirmed / payment.failed topics, and enforce consumer idempotency via processed\_events.  
> 5. **Phase 5 — API Gateway, Lightweight JWT RBAC, Metrics & Load Benchmarks:** Place api-gateway in front of 2 Dockerized inventory-service instances, add stateless JWT role checks (ROLE\_CUSTOMER, ROLE\_STORE\_MANAGER), expose Actuator/Micrometer metrics, and execute k6 500-concurrent-request benchmarks comparing NONE, DB\_OPTIMISTIC, and REDISSON\_LOCK.  
> 6. **Phase 6 — Documentation & Deployment:** Finalize architecture diagrams, DECISIONS.md, benchmark tables in README.md, and deploy a live Swagger-accessible demo instance alongside one-command local Docker Compose execution.

## **9\. Verification & Acceptance Criteria**

* **Integration Correctness:** Testcontainers suites (real PostgreSQL \+ Redis) verify zero overselling across 50+ concurrent threads, deadlock-free overlapping multi-SKU carts, safe concurrent payment-failure vs. TTL-expiry handling, and duplicate Kafka event rejection.  
* **Multi-Instance Stress Proof:** Running k6 with 500 concurrent virtual users competing for 10 units of a single SKU across 2 Gateway-balanced Inventory Service instances produces reproducible metrics showing:  
  * NONE: Oversells (final stock drops below 0 or confirmed reservations exceed 10).  
  * DB\_OPTIMISTIC: Zero overselling, elevated contention failures/retries.  
  * REDISSON\_LOCK \+ Atomic Conditional SQL: Exactly 10 reservations succeed, 490 receive clean 409 Conflict responses, final available\_qty \= 0, and recorded p95 latency stays stable.