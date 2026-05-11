# cloud_armor.tf

resource "google_compute_security_policy" "prd_waf_policy" {
  name        = "ilpoomjinro-waf-policy"
  description = "GCE Ingress에 연결될 Cloud Armor WAF 방어 정책"

  # 1. 기본 규칙: 조건에 안 걸리는 일반 트래픽은 모두 허용 (우선순위 제일 낮음)
  rule {
    action   = "allow"
    priority = "2147483647"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Default allow rule"
  }

  # 2. XSS (크로스 사이트 스크립팅) 및 SQL 인젝션 공격 차단
  rule {
    action   = "deny(403)"
    priority = 1000
    match {
      expr {
        # 구글이 제공하는 미리 정의된 강력한 WAF 룰셋 사용
        expression = "evaluatePreconfiguredExpr('sqli-v33-stable') || evaluatePreconfiguredExpr('xss-v33-stable')"
      }
    }
    description = "Block SQL Injection and XSS attacks"
  }

  # 3. LFI (Local File Inclusion) 및 RCE (Remote Code Execution) 차단
  rule {
    action   = "deny(403)"
    priority = 1001
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('lfi-v33-stable') || evaluatePreconfiguredExpr('rce-v33-stable')"
      }
    }
    description = "Block LFI and RCE attacks"
  }

  # 4. (선택적) 봇(Bot) 또는 특정 대륙 차단 예시 - 필요 없으면 주석 처리
  /*
  rule {
    action   = "deny(403)"
    priority = 1002
    match {
      expr {
        # 예: 중국(CN)이나 러시아(RU) 발 트래픽 차단
        expression = "origin.region_code == 'CN' || origin.region_code == 'RU'"
      }
    }
    description = "Block traffic from specific countries"
  }
  */
}