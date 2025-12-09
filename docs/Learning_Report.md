# Learning Report - Smart University Platform

## گزارش یادگیری - پلتفرم مدیریت هوشمند دانشگاه

**تیم پروژه:** Smart University Team  
**تاریخ:** دسامبر ۲۰۲۵  
**نسخه:** 1.0

---

## 1. Executive Summary (خلاصه اجرایی)

This document describes our team's learning journey in implementing the Smart University Microservices Platform. It focuses on our understanding and implementation of two critical distributed systems patterns: **Saga** and **Circuit Breaker**.

این سند سفر یادگیری تیم ما را در پیاده‌سازی پلتفرم میکروسرویس دانشگاه هوشمند توصیف می‌کند. تمرکز اصلی بر درک عمیق و پیاده‌سازی دو الگوی بحرانی سیستم‌های توزیع‌شده است: **Saga** و **Circuit Breaker**.

---

## 2. Understanding the Saga Pattern (درک الگوی Saga)

### 2.1 The Challenge: Distributed Transactions (چالش: تراکنش‌های توزیع‌شده)

در یک معماری یکپارچه (Monolithic)، می‌توانیم از تراکنش‌های ACID دیتابیس برای اطمینان از صحت داده‌ها استفاده کنیم. اما در میکروسرویس‌ها:

- هر سرویس دیتابیس مستقل خود را دارد
- نمی‌توان از `BEGIN TRANSACTION` / `COMMIT` بین چند سرویس استفاده کرد
- Two-Phase Commit (2PC) باعث قفل‌شدن منابع و کاهش در دسترس‌پذیری می‌شود

**Problem Statement:**
When a student buys a product from the marketplace:
1. Create order in Marketplace DB ✅
2. Authorize payment in Payment DB ✅
3. Reduce stock in Marketplace DB ✅

If step 3 fails (out of stock), we must **undo** steps 1 and 2!

### 2.2 Our Solution: Orchestrated Saga (راه‌حل ما: Saga هماهنگ‌شده)

ما الگوی **Saga Orchestration** را انتخاب کردیم که در آن یک سرویس مرکزی (Orchestrator) مسئول هماهنگی تمام مراحل است:

```
┌─────────────────────────────────────────────────────────────┐
│                    SAGA FLOW (جریان Saga)                   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   ┌──────────────┐       ┌──────────────┐                   │
│   │  Marketplace │       │   Payment    │                   │
│   │  (Orchestrator)│      │  (Participant)│                  │
│   └──────────────┘       └──────────────┘                   │
│          │                      │                           │
│          │  1. Create PENDING   │                           │
│          │     Order            │                           │
│          ├─────────────────────>│                           │
│          │                      │                           │
│          │  2. Authorize        │                           │
│          │     Payment          │                           │
│          │<─────────────────────┤                           │
│          │                      │                           │
│          │  3a. SUCCESS:        │                           │
│          │      - Reduce Stock  │                           │
│          │      - Confirm Order │                           │
│          │      - Publish Event │                           │
│          │                      │                           │
│          │  3b. FAILURE:        │                           │
│          │      - Cancel Payment│                           │
│          │      - Cancel Order  │                           │
│          │                      │                           │
└─────────────────────────────────────────────────────────────┘
```

### 2.3 Implementation Details (جزئیات پیاده‌سازی)

**File:** `marketplace-service/src/main/java/com/.../service/OrderSagaService.java`

```java
@Service
public class OrderSagaService {
    
    @Transactional
    public OrderDto checkout(List<OrderItemRequest> items, ...) {
        // STEP 1: Create PENDING order
        Order order = createPendingOrder(items, tenantId, userId);
        
        // STEP 2: Authorize payment via PaymentClient
        PaymentResponse paymentResponse = paymentClient.authorize(...);
        
        if (!paymentResponse.isSuccess()) {
            // COMPENSATION: Mark order as FAILED
            order.setStatus(OrderStatus.FAILED);
            return convertToDto(order);
        }
        
        // STEP 3: Try to reduce stock
        try {
            reduceStock(items);
            order.setStatus(OrderStatus.CONFIRMED);
            
            // STEP 4: Publish success event
            rabbitTemplate.convertAndSend("order.confirmed", event);
            
        } catch (InsufficientStockException e) {
            // COMPENSATION: Cancel payment
            paymentClient.cancel(paymentResponse.getPaymentId());
            order.setStatus(OrderStatus.CANCELLED);
        }
        
        return convertToDto(order);
    }
}
```

### 2.4 Key Learnings: Saga (یادگیری‌های کلیدی)

| Learning | Description (فارسی) |
|----------|-------------------|
| **Compensation Logic** | هر مرحله باید یک عملیات معکوس (Compensation) داشته باشد |
| **Idempotency** | عملیات باید idempotent باشند تا retry ایمن باشد |
| **Ordering Matters** | ترتیب مراحل مهم است - اول پرداخت، بعد کسر موجودی |
| **Event Publishing** | رویدادها فقط پس از موفقیت منتشر شوند |
| **Error Handling** | هر خطا باید به compensation منجر شود |

### 2.5 Why We Chose Orchestration over Choreography

| Aspect | Orchestration (انتخاب ما) | Choreography |
|--------|--------------------------|--------------|
| Control Flow | متمرکز و واضح | توزیع‌شده و پیچیده |
| Debugging | آسان‌تر - یک نقطه کنترل | سخت‌تر - پیگیری رویدادها |
| Coupling | وابستگی به Orchestrator | کمتر اما پیچیده‌تر |
| Our Scope | مناسب برای اندازه پروژه | برای سیستم‌های بزرگ‌تر |

---

## 3. Understanding the Circuit Breaker Pattern (درک الگوی Circuit Breaker)

### 3.1 The Challenge: Cascading Failures (چالش: شکست‌های آبشاری)

وقتی سرویس Notification از کار می‌افتد:

```
┌─────────────────────────────────────────────────────────────┐
│            WITHOUT CIRCUIT BREAKER (بدون Circuit Breaker)   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   Student                                                   │
│      │                                                      │
│      │  Start Exam                                          │
│      ▼                                                      │
│   ┌──────────────┐       ┌──────────────┐                   │
│   │    Exam      │──────>│ Notification │ ❌ DOWN           │
│   │   Service    │       │   Service    │                   │
│   └──────────────┘       └──────────────┘                   │
│      │                                                      │
│      │  BLOCKED! Timeout...                                 │
│      │  Thread exhausted...                                 │
│      │  Connection pool drained...                          │
│      ▼                                                      │
│   ❌ EXAM SERVICE ALSO FAILS! (سرویس آزمون هم از کار می‌افتد)│
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 Our Solution: Resilience4j Circuit Breaker

```
┌─────────────────────────────────────────────────────────────┐
│           WITH CIRCUIT BREAKER (با Circuit Breaker)         │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   ┌──────────┐    ┌────────────────┐    ┌──────────────┐    │
│   │   Exam   │───>│ Circuit Breaker│───>│ Notification │    │
│   │ Service  │    │   (Closed)     │    │   Service    │    │
│   └──────────┘    └────────────────┘    └──────────────┘    │
│                                                             │
│   STATES:                                                   │
│   ┌────────────────────────────────────────────────────┐    │
│   │                                                    │    │
│   │   CLOSED ──> 5 failures ──> OPEN ──> 10s ──> HALF  │    │
│   │     ▲                         │              OPEN  │    │
│   │     │                         │               │    │    │
│   │     └─── success ◄────────────┴───────────────┘    │    │
│   │                                                    │    │
│   └────────────────────────────────────────────────────┘    │
│                                                             │
│   When OPEN: Fallback runs, exam continues! ✅              │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 3.3 Implementation Details (جزئیات پیاده‌سازی)

**Configuration:** `exam-service/src/main/resources/application.yml`

```yaml
resilience4j:
  circuitbreaker:
    instances:
      notificationCb:
        slidingWindowSize: 10           # تعداد فراخوانی برای محاسبه
        failureRateThreshold: 50        # درصد شکست برای باز شدن
        waitDurationInOpenState: 10s    # مدت باز ماندن
        permittedNumberOfCallsInHalfOpenState: 3  # تست در حالت نیمه‌باز
```

**Code:** `exam-service/src/main/java/.../service/NotificationClient.java`

```java
@Service
public class NotificationClient {
    
    @CircuitBreaker(name = "notificationCb", fallbackMethod = "notifyExamFallback")
    public void notifyExamStarted(String tenantId, UUID examId) {
        // HTTP call to Notification Service
        restTemplate.postForObject(
            notificationServiceUrl + "/notify/exam-started",
            new ExamNotificationRequest(tenantId, examId),
            Void.class
        );
    }
    
    // FALLBACK: اگر Circuit Breaker باز باشد یا خطا رخ دهد
    public void notifyExamFallback(String tenantId, UUID examId, Exception ex) {
        log.warn("⚠️ Circuit Breaker: Notification failed for exam {}. " +
                 "Fallback activated. Exam will still proceed.", examId);
        // Exam continues without notification!
    }
}
```

### 3.4 Circuit Breaker States Explained (توضیح حالت‌ها)

| State | Behavior (رفتار) | Transition (تغییر حالت) |
|-------|-----------------|------------------------|
| **CLOSED** | همه فراخوانی‌ها عبور می‌کنند | اگر نرخ شکست > 50% → OPEN |
| **OPEN** | همه فراخوانی‌ها فوراً Fail می‌شوند (Fallback) | بعد از 10 ثانیه → HALF_OPEN |
| **HALF_OPEN** | 3 فراخوانی آزمایشی اجازه عبور دارند | موفق → CLOSED، ناموفق → OPEN |

### 3.5 Key Learnings: Circuit Breaker (یادگیری‌های کلیدی)

| Learning | Description (فارسی) |
|----------|-------------------|
| **Fail Fast** | وقتی سرویس خراب است، سریع شکست بخور بجای انتظار |
| **Graceful Degradation** | سیستم باید با قابلیت کمتر ادامه دهد |
| **Critical vs Non-Critical** | اعلان غیرحیاتی است، آزمون حیاتی است |
| **Monitoring** | وضعیت Circuit Breaker باید قابل مشاهده باشد |
| **Tuning** | تنظیم thresholds نیاز به آزمایش دارد |

### 3.6 Testing the Circuit Breaker

**Test File:** `exam-service/.../service/NotificationClientCircuitBreakerTest.java`

```java
@Test
void whenNotificationFails_thenFallbackIsCalled() {
    // Simulate Notification Service failure
    mockServer.expect(requestTo(containsString("/notify")))
              .andRespond(withServerError());
    
    // Start exam - should NOT throw exception
    assertDoesNotThrow(() -> notificationClient.notifyExamStarted("tenant1", examId));
    
    // Verify fallback was called (exam continues)
    verify(mockAppender).doAppend(argThat(event -> 
        event.getMessage().contains("Fallback activated")));
}
```

---

## 4. Architectural Decisions (تصمیمات معماری)

### 4.1 Why Database-per-Service? (چرا دیتابیس جداگانه؟)

```
┌─────────────────────────────────────────────────────────────┐
│              DATABASE-PER-SERVICE ARCHITECTURE              │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐       │
│   │  Auth   │  │ Booking │  │ Market  │  │  Exam   │       │
│   │ Service │  │ Service │  │ Service │  │ Service │       │
│   └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘       │
│        │            │            │            │             │
│   ┌────▼────┐  ┌────▼────┐  ┌────▼────┐  ┌────▼────┐       │
│   │ auth-db │  │booking-db│  │market-db│  │ exam-db │       │
│   │ (Postgres)│  │(Postgres)│  │(Postgres)│  │(Postgres)│    │
│   └─────────┘  └─────────┘  └─────────┘  └─────────┘       │
│                                                             │
│   BENEFITS:                                                 │
│   ✅ Independent scaling                                    │
│   ✅ Technology flexibility (می‌توان از DB متفاوت استفاده کرد)│
│   ✅ Fault isolation (شکست یک DB بقیه را تحت تاثیر نمی‌گذارد)│
│   ✅ Independent deployment                                 │
│                                                             │
│   TRADE-OFFS:                                               │
│   ⚠️ No ACID across services → نیاز به Saga                 │
│   ⚠️ Data duplication possible                              │
│   ⚠️ More operational complexity                            │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 Multi-Tenancy Strategy (استراتژی چندمستاجری)

ما از **Row-Level Multi-Tenancy** استفاده کردیم:

```sql
-- Every tenant-scoped table has tenant_id
CREATE TABLE products (
    id UUID PRIMARY KEY,
    tenant_id VARCHAR(100) NOT NULL,  -- Faculty identifier
    name VARCHAR(255),
    price DECIMAL(10,2),
    stock INTEGER
);

-- Every query filters by tenant
SELECT * FROM products WHERE tenant_id = 'engineering';
```

**Why not Database-per-Tenant?**
- پیچیدگی عملیاتی بالاتر
- برای این مقیاس پروژه، Row-Level کافی است
- مدیریت migration ساده‌تر است

---

## 5. Testing Strategy (استراتژی تست)

### 5.1 Test Pyramid

```
                    ┌─────────────┐
                    │   E2E Tests │  (Manual + Scripts)
                    │     5%      │
                    └──────┬──────┘
                           │
                ┌──────────▼──────────┐
                │  Integration Tests  │  (Spring Boot Test)
                │        25%          │
                └──────────┬──────────┘
                           │
          ┌────────────────▼────────────────┐
          │          Unit Tests             │  (JUnit + Mockito)
          │            70%                  │
          └─────────────────────────────────┘
```

### 5.2 Critical Test Cases

| Test | Purpose | File |
|------|---------|------|
| Saga Success | Full checkout flow | `MarketplaceControllerIntegrationTest` |
| Saga Compensation | Payment fails → Order cancelled | `MarketplaceControllerIntegrationTest` |
| Circuit Breaker Open | Notification down → Fallback | `NotificationClientCircuitBreakerTest` |
| Overbooking Prevention | Concurrent booking → Only one succeeds | `BookingControllerIntegrationTest` |
| JWT Validation | Invalid token → 401 | `JwtAuthenticationFilterTests` |

---

## 6. Challenges and Solutions (چالش‌ها و راه‌حل‌ها)

| Challenge | Solution | Learning |
|-----------|----------|----------|
| Distributed Transactions | Saga Pattern with compensation | شکستن تراکنش بزرگ به مراحل کوچک |
| Service Failure | Circuit Breaker + Fallback | طراحی برای شکست (Design for Failure) |
| Data Isolation | Row-level tenant_id | هر query باید tenant را فیلتر کند |
| Overbooking | Pessimistic Locking | `SELECT FOR UPDATE` برای منابع محدود |
| Event Consistency | Outbox Pattern (simplified) | رویداد فقط بعد از commit منتشر شود |

---

## 7. Reflection: What We Would Do Differently (بازتاب)

### Things That Worked Well ✅

1. **Starting with ADRs**: نوشتن تصمیمات قبل از کد، طراحی را بهبود داد
2. **Incremental Development**: ساخت سرویس‌ها یک‌به‌یک و تست هر کدام
3. **Docker Compose**: محیط توسعه قابل تکرار برای همه اعضای تیم
4. **AI-Assisted Development**: سرعت توسعه بالاتر با حفظ کیفیت

### Things We Would Improve ⚠️

1. **Observability**: افزودن distributed tracing (Jaeger/Zipkin)
2. **API Versioning**: نسخه‌بندی API برای سازگاری backward
3. **Event Schema Registry**: Schema مشترک برای رویدادها
4. **Load Testing**: تست بار قبل از استقرار

---

## 8. Conclusion (نتیجه‌گیری)

این پروژه تجربه عملی ارزشمندی در طراحی و پیاده‌سازی سیستم‌های توزیع‌شده فراهم کرد:

- **Saga** به ما آموخت که چگونه بدون تراکنش‌های توزیع‌شده، سازگاری داده را حفظ کنیم
- **Circuit Breaker** نشان داد که چگونه از شکست‌های آبشاری جلوگیری کنیم
- **Microservices** مزایا و هزینه‌های معماری توزیع‌شده را آشکار کرد

این الگوها در سیستم‌های تولیدی بزرگ مانند Netflix، Amazon و Uber استفاده می‌شوند و درک آن‌ها برای مهندسین نرم‌افزار مدرن ضروری است.

---

**پایان گزارش یادگیری**

*Smart University Team - December 2025*
