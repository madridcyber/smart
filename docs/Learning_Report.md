# Learning_Report

This report reflects on key technical learnings from implementing the Smart University Microservices Platform, focusing on Saga, Circuit Breaker, event-driven architecture, and non-functional trade-offs.

---

## 1. Saga Implementation (Marketplace + Payment)

### What Was Implemented

- **Orchestrator**: Marketplace Service (`OrderSagaService`) acts as the Saga orchestrator for checkout.
- **Participants**:
  - Payment Service: authorises and cancels payments.
  - Marketplace itself: manages order lifecycle and stock.
- **Workflow**:
  1. Create a `PENDING` order with items.
  2. Call Payment Service to authorise payment.
  3. If authorised:
     - Validate and decrement stock under pessimistic locking.
  4. If any failure occurs:
     - Mark order `CANCELED`.
     - Compensate by cancelling payment when appropriate.
  5. On success:
     - Mark order `CONFIRMED`.
     - Publish `OrderConfirmedEvent` to RabbitMQ.

### Lessons Learned

1. **Local Transactions + Compensations vs Global Transactions**
   - Sagas embrace local transactions with compensating actions instead of global ACID transactions.
   - This reduces coupling to a central transaction manager and is more compatible with microservices.
   - Trade-off: consistency is eventual and must be made visible in domain states (`PENDING`, `CONFIRMED`, `CANCELED`).

2. **Explicit Domain States Improve Clarity**
   - Modeling `OrderStatus` explicitly makes the system behaviour easier to reason about and test.
   - Observability of order states is critical for debugging and user support.

3. **Tests Must Cover Failure Paths**
   - Happy-path tests are not enough:
     - Payment authorization failures must be handled without stock changes.
     - Stock failures after successful authorization must trigger compensation.
   - Writing integration tests for both failure paths forced the orchestration logic to be robust and explicit.

4. **Idempotency and Safety**
   - Saga steps and compensations should be idempotent or safe to retry.
   - While this project operates at small scale, the patterns used are ready to be hardened with idempotent tokens or explicit business constraints.

---

## 2. Circuit Breaker Behaviour (Exam → Notification)

### What Was Implemented

- **Placement**: In Exam Service, wrapping outbound HTTP calls to Notification Service.
- **Library**: Resilience4j (`resilience4j-spring-boot3`).
- **Behaviour**:
  - When starting an exam:
    - A Circuit Breaker (`notificationCb`) surrounds the call to `/notification/notify/exam/{examId}`.
    - On failure or open circuit:
      - A fallback logs the error.
      - The exam still transitions to `LIVE`.
      - An `ExamStartedEvent` is still emitted to RabbitMQ.

### Lessons Learned

1. **Critical vs Non-Critical Dependencies**
   - Exam start is a critical operation; notifications are important but non-critical.
   - Circuit Breakers help distinguish these by preventing non-critical failure from cascading into critical flows.

2. **Fallbacks Must Be Thoughtful**
   - A fallback should:
     - Preserve important side effects (exam state transition).
     - Log enough context (examId, tenantId, exception) for troubleshooting.
   - It should not silently swallow errors; observability is essential.

3. **Configuration Tuning**
   - Circuit Breaker settings (window size, failure rate thresholds, wait duration) are trade-offs:
     - Too aggressive → unnecessary open circuits.
     - Too lenient → prolonged degradation.
   - In this project, default-ish values are used, but the architecture allows fine-tuning based on production metrics.

4. **Complementary Patterns**
   - Circuit Breakers work well in combination with:
     - Retries (not used here, but often appropriate).
     - Timeouts (important for bounding call durations).
     - Bulkheads (isolation of resources per dependency).

---

## 3. Event-Driven Architecture (Observer Pattern)

### What Was Implemented

- **Event Producers**:
  - Marketplace Service publishes `OrderConfirmedEvent` on successful Saga completion.
  - Exam Service publishes `ExamStartedEvent` on exam start.
- **Event Consumer**:
  - Notification Service listens to both event streams using RabbitMQ and `@RabbitListener`.
  - Each event is persisted as a `NotificationLog` entry, with payload and tenant id.

### Lessons Learned

1. **Loose Coupling via Events**
   - Producers know nothing about consumers; Notification can evolve independently.
   - New consumers (analytics, monitoring) can be added without touching core domains.

2. **Observability**
   - Events form a natural audit trail of significant domain operations.
   - Storing events in `NotificationLog` provides a searchable history for debugging and reporting.

3. **Domain-Driven Events**
   - Events are phrased in domain language (`order.confirmed`, `exam.started`), not technical language.
   - This makes the architecture easier to explain and reason about with domain experts.

4. **Eventual Consistency**
   - The system accepts that notifications may lag behind primary operations.
   - For user experience, this is acceptable as long as core actions (e.g. exam start) are consistent and reliable.

---

## 4. Multi-Tenancy and Security

### What Was Implemented

- **Multi-Tenancy**:
  - Row-level tenant isolation per service using `tenantId` columns.
  - Tenant propagated from JWT → Gateway → `X-Tenant-Id` header → service queries.
- **Security**:
  - JWT-based authentication with roles (STUDENT, TEACHER, ADMIN).
  - RBAC at Gateway and within services (e.g., only teachers can create exams).
  - Services trust only gateway-injected headers for identity and tenant.

### Lessons Learned

1. **Tenant Context as a First-Class Concern**
   - Failing to include tenant filters in queries is the primary risk.
   - Making tenant id explicit in entity models, repositories, and method signatures greatly reduces this risk.

2. **Security Layers**
   - Gateway-level RBAC simplifies enforcement for route-level decisions.
   - Service-level checks are still necessary for business-specific rules (e.g., exam creator vs other teachers).

3. **Data Isolation vs Operational Complexity**
   - Row-level tenant isolation plus database-per-service strikes a good balance for this project:
     - Strong logical isolation per tenant within each service.
     - Operationally manageable number of databases.

---

## 5. Performance and Reliability Trade-offs

### Performance

- **Design choices**:
  - Database-per-service with straightforward, indexable queries.
  - Dashboard sensors & shuttles stored in the Dashboard service's PostgreSQL database and updated via scheduled jobs, while reads remain simple and cache-friendly.
  - **Redis distributed caching** for Marketplace product listings (`@Cacheable` on `GET /market/products`):
    - 10-minute TTL for product listings
    - Cache eviction on product creation (`@CacheEvict`)
    - JSON serialization for cached objects
    - Shared cache across service replicas for consistency

- **Trade-offs**:
  - Strong consistency for core operations (e.g. bookings, exams) sometimes implies more DB locking or checks, slightly increasing latency.
  - Redis adds an extra infrastructure component but enables horizontal scaling with shared cache.
  - In this educational setting, correctness and clarity are favoured over micro-optimisations.

### Reliability

- **Techniques used**:
  - Pessimistic locking for bookings and stock decrements.
  - Saga with compensation for cross-service workflows.
  - Circuit Breaker for notification calls.
  - Clear domain states (order and exam states).

- **Trade-offs**:
  - Additional complexity in orchestration and state management.
  - Requires good logging and metrics to debug distributed flows.

---

## 6. Maintainability and Patterns

### Patterns Applied

- **Saga** (Marketplace/Payment).
- **Circuit Breaker** (Exam → Notification).
- **Observer / Event-driven** (Notification reacting to domain events).
- **State** (Exam lifecycle).
- **Strategy** (Payment providers).
- **Repository** (JPA repositories).
- **Factory** (ExamStateFactory).

### Lessons Learned

- Well-chosen patterns reduce conditional complexity and centralise change.
- ADRs help future maintainers understand *why* patterns were chosen, not just *how* they were implemented.
- Consistent layering (Controller → Service → Repository) makes the system easier to extend (e.g., adding new endpoints or services).

---

## 7. Summary

The project provided a concrete end-to-end exercise in modern microservice architecture:

- **Saga** demonstrated distributed transaction handling with compensations.
- **Circuit Breaker** showed how to protect critical flows from non-critical dependencies.
- **Event-driven architecture** illustrated decoupling and observability.
- **Multi-tenancy** and **security** required careful propagation of tenant and user context across all layers.
- The combination of patterns, tests, and documentation produced a system that is not only functional but also explainable and maintainable.

These learnings are directly transferable to real-world microservice systems where cross-service workflows, resilience, and multi-tenancy are common challenges.