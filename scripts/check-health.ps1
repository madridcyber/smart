# Smart University Health Check Script for Windows PowerShell
# Verifies all services are running and healthy

Write-Host "`n===========================================" -ForegroundColor Cyan
Write-Host "  Smart University Health Check" -ForegroundColor Cyan
Write-Host "===========================================" -ForegroundColor Cyan

$services = @(
    @{ Name = "Gateway"; Port = 8080; HealthPath = "/actuator/health" },
    @{ Name = "Auth Service"; Port = 8081; HealthPath = "/actuator/health" },
    @{ Name = "Booking Service"; Port = 8082; HealthPath = "/actuator/health" },
    @{ Name = "Marketplace Service"; Port = 8083; HealthPath = "/actuator/health" },
    @{ Name = "Payment Service"; Port = 8084; HealthPath = "/actuator/health" },
    @{ Name = "Exam Service"; Port = 8085; HealthPath = "/actuator/health" },
    @{ Name = "Notification Service"; Port = 8086; HealthPath = "/actuator/health" },
    @{ Name = "Dashboard Service"; Port = 8087; HealthPath = "/actuator/health" },
    @{ Name = "Frontend"; Port = 3000; HealthPath = "/" }
)

$infrastructure = @(
    @{ Name = "RabbitMQ"; Port = 15672; HealthPath = "/" },
    @{ Name = "Redis"; Port = 6379; Command = "redis-cli ping" }
)

Write-Host "`n📡 Checking Microservices..." -ForegroundColor Yellow

$healthyCount = 0
$totalCount = $services.Count

foreach ($svc in $services) {
    $url = "http://localhost:$($svc.Port)$($svc.HealthPath)"
    Write-Host -NoNewline "   $($svc.Name.PadRight(25))"
    
    try {
        $response = Invoke-WebRequest -Uri $url -TimeoutSec 5 -ErrorAction Stop
        if ($response.StatusCode -eq 200) {
            Write-Host "✅ UP" -ForegroundColor Green
            $healthyCount++
        } else {
            Write-Host "⚠️  HTTP $($response.StatusCode)" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "❌ DOWN" -ForegroundColor Red
    }
}

Write-Host "`n🔧 Checking Infrastructure..." -ForegroundColor Yellow

# Check RabbitMQ
Write-Host -NoNewline "   RabbitMQ                  "
try {
    $rabbit = Invoke-WebRequest -Uri "http://localhost:15672/" -TimeoutSec 5 -ErrorAction Stop
    Write-Host "✅ UP (Web UI available)" -ForegroundColor Green
}
catch {
    Write-Host "❌ DOWN" -ForegroundColor Red
}

# Check Redis
Write-Host -NoNewline "   Redis                     "
try {
    $redisPing = docker exec redis redis-cli ping 2>$null
    if ($redisPing -eq "PONG") {
        Write-Host "✅ UP (PONG received)" -ForegroundColor Green
    } else {
        Write-Host "⚠️  No response" -ForegroundColor Yellow
    }
}
catch {
    Write-Host "⚠️  Cannot check (Docker?)" -ForegroundColor Yellow
}

# Check PostgreSQL databases via Docker
Write-Host "`n🗄️  Checking Databases..." -ForegroundColor Yellow

$databases = @("auth-db", "booking-db", "market-db", "payment-db", "exam-db", "notification-db", "dashboard-db")

foreach ($db in $databases) {
    Write-Host -NoNewline "   $($db.PadRight(25))"
    try {
        $status = docker inspect --format='{{.State.Status}}' $db 2>$null
        if ($status -eq "running") {
            Write-Host "✅ Running" -ForegroundColor Green
        } else {
            Write-Host "⚠️  $status" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "❌ Not found" -ForegroundColor Red
    }
}

Write-Host "`n===========================================" -ForegroundColor Cyan
Write-Host "  Health Check Summary" -ForegroundColor Cyan
Write-Host "===========================================" -ForegroundColor Cyan

$percentage = [math]::Round(($healthyCount / $totalCount) * 100)
$color = if ($percentage -eq 100) { "Green" } elseif ($percentage -ge 80) { "Yellow" } else { "Red" }

Write-Host "`n   Services Healthy: $healthyCount / $totalCount ($percentage%)" -ForegroundColor $color

if ($healthyCount -eq $totalCount) {
    Write-Host "`n   🎉 All systems operational! Ready to test." -ForegroundColor Green
    Write-Host "   🌐 Open: http://localhost:3000" -ForegroundColor Cyan
} else {
    Write-Host "`n   ⚠️  Some services are down. Run:" -ForegroundColor Yellow
    Write-Host "      docker compose logs -f [service-name]" -ForegroundColor Gray
}
