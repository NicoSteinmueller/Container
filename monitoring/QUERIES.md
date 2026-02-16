# Nützliche Prometheus & Loki Queries

## 🔥 Prometheus Queries (Metriken)

### Request Rate
```promql
# Requests pro Sekunde (gesamt)
rate(traefik_entrypoint_requests_total[5m])

# Requests pro Sekunde nach EntryPoint
rate(traefik_entrypoint_requests_total[5m]) by (entrypoint)

# Requests pro Sekunde nach Service
rate(traefik_service_requests_total[5m]) by (service)
```

### Response Codes
```promql
# 4xx Errors
sum(rate(traefik_service_requests_total{code=~"4.."}[5m]))

# 5xx Errors
sum(rate(traefik_service_requests_total{code=~"5.."}[5m]))

# Success Rate (2xx)
sum(rate(traefik_service_requests_total{code=~"2.."}[5m])) / sum(rate(traefik_service_requests_total[5m])) * 100
```

### Response Times
```promql
# Average Response Time
rate(traefik_service_request_duration_seconds_sum[5m]) / rate(traefik_service_request_duration_seconds_count[5m])

# P95 Response Time
histogram_quantile(0.95, rate(traefik_service_request_duration_seconds_bucket[5m]))

# P99 Response Time
histogram_quantile(0.99, rate(traefik_service_request_duration_seconds_bucket[5m]))
```

### Backend Health
```promql
# Anzahl aktiver Backends
traefik_service_server_up

# Ungesunde Backends
traefik_service_server_up == 0
```

### TLS/Certificates
```promql
# Tage bis Zertifikat abläuft
(traefik_tls_certs_not_after - time()) / 86400

# Zertifikate die in 30 Tagen ablaufen
(traefik_tls_certs_not_after - time()) / 86400 < 30
```

### Top Endpoints
```promql
# Top 10 Services nach Request-Count
topk(10, sum(rate(traefik_service_requests_total[5m])) by (service))

# Langsamste Services
topk(10, rate(traefik_service_request_duration_seconds_sum[5m]) / rate(traefik_service_request_duration_seconds_count[5m]) by (service))
```

## 📝 Loki Queries (Logs)

### Access Logs
```logql
# Alle Traefik Access Logs
{job="traefik", type="access"}

# Fehler (4xx, 5xx)
{job="traefik", type="access"} | json | status >= 400

# Langsame Requests (> 1 Sekunde)
{job="traefik", type="access"} | json | duration > 1000000000

# Requests von bestimmter IP
{job="traefik", type="access"} | json | client_ip="192.168.1.100"

# POST Requests
{job="traefik", type="access"} | json | method="POST"

# Specific Path
{job="traefik", type="access"} | json | path=~"/api/.*"
```

### Application Logs
```logql
# Alle Application Logs
{job="traefik", type="application"}

# Error Level
{job="traefik", type="application"} | json | level="error"

# Warning Level
{job="traefik", type="application"} | json | level="warning"

# Suche nach Stichwort
{job="traefik", type="application"} |= "certificate"
```

### Aggregationen
```logql
# Request Count pro Minute
count_over_time({job="traefik", type="access"}[1m])

# Error Rate (4xx/5xx)
sum(rate({job="traefik", type="access"} | json | status >= 400 [5m]))

# Top Client IPs
topk(10, sum by (client_ip) (count_over_time({job="traefik", type="access"} | json [1h])))

# Top User Agents
topk(10, sum by (user_agent) (count_over_time({job="traefik", type="access"} | json [1h])))
```

### Erweiterte Filters
```logql
# Kombinierte Bedingungen
{job="traefik", type="access"} 
  | json 
  | status >= 400 
  | duration > 500000000
  | path!="/health"

# Regex Patterns
{job="traefik", type="access"} 
  | json 
  | path=~"/api/(users|admin)/.*"
  | method!="GET"
```

## 📊 Dashboard-Panels Beispiele

### Requests/s Panel (Graph)
```promql
Query: rate(traefik_entrypoint_requests_total[5m])
Legend: {{entrypoint}}
```

### Error Rate Panel (Stat)
```promql
Query: sum(rate(traefik_service_requests_total{code=~"5.."}[5m])) / sum(rate(traefik_service_requests_total[5m])) * 100
Unit: Percent (0-100)
Thresholds: Green < 1, Orange < 5, Red >= 5
```

### Response Time Heatmap
```promql
Query: sum(rate(traefik_service_request_duration_seconds_bucket[5m])) by (le)
Format: Heatmap
```

### Top Errors Table
```logql
Query: topk(10, sum by (status, path) (count_over_time({job="traefik", type="access"} | json | status >= 400 [1h])))
Format: Table
```

## 🎨 Alert-Beispiele

### High Error Rate
```promql
sum(rate(traefik_service_requests_total{code=~"5.."}[5m])) / sum(rate(traefik_service_requests_total[5m])) > 0.05
```

### Slow Response Time
```promql
histogram_quantile(0.95, rate(traefik_service_request_duration_seconds_bucket[5m])) > 2
```

### Certificate Expiring Soon
```promql
(traefik_tls_certs_not_after - time()) / 86400 < 14
```

### Backend Down
```promql
traefik_service_server_up == 0
```

## 💡 Tipps

- **Rate vs Increase**: `rate()` für per-second rates, `increase()` für absolute Änderung
- **Time Ranges**: Kürzere Ranges (1m-5m) für Echtzeit, längere (1h+) für Trends
- **Labels**: Mit `by (label)` gruppieren, mit `without (label)` ausschließen
- **Regex**: `=~` für Regex-Match, `!~` für negatives Match
- **JSON Parsing**: Loki parsed JSON automatisch mit `| json`

