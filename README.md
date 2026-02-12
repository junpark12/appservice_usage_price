# App Service Usage Report - 과금 분배용 데이터

## 개요
이 도구는 Azure 구독 내의 모든 App Service Plan과 해당 App Service들의 리소스 사용량을 수집하여 과금 분배를 위한 기초 데이터를 생성합니다.

## 파일 구성
- `collect_appservice_metrics.sh`: 메트릭 수집 스크립트
- `appservice_usage_report_YYYYMMDD_HHMMSS.csv`: 생성된 리포트 (타임스탬프 포함)

## 수집 데이터

### App Service Plan 수준
- **CPU 사용률 (%)**: 7일 평균 CPU Percentage
- **메모리 사용률 (%)**: 7일 평균 Memory Percentage
- **Data Out (MB)**: 7일 평균 시간당 송신 데이터량 (MB)
- **SKU 정보**: Plan의 가격 계층 (B1, S1, P1v2 등)
- **Capacity**: 인스턴스 수
- **월 비용**: USD 및 KRW (Linux/Windows 구분)

### App Service 수준
- **CPU 시간 (초/시간)**: 시간당 평균 CPU Time + Plan 내 비율 (%)
  - 형식: "27.12 (99.00%)" - 시간당 평균 27.12초 사용, Plan 내 전체 CPU의 99% 차지
  - 7일 총합: 27.12초 × 168시간 = 1.26시간
- **메모리 (MB/시간)**: 시간당 평균 Memory Working Set + Plan 내 비율 (%)
  - 형식: "61.76 (99.00%)" - 시간당 평균 61.76MB 사용, Plan 내 전체 메모리의 99% 차지
- **Data Out (MB/시간)**: 시간당 평균 송신 데이터량 + Plan 내 비율 (%)
  - 형식: "543.20 (65.00%)" - 시간당 평균 543.20MB 송신, Plan 내 전체 Data Out의 65% 차지
- **과금 분배 비율**: CPU, Memory, Data Out 비율의 평균
- **월 비용**: USD 및 KRW (Billing_Allocation% 기반 계산)

**비율 계산 방식:**
- 같은 Plan 내 모든 App Service의 리소스 사용량 합계 대비 각 App의 비율
- 예: WeatherSidecar 27.12초, jpsamplewebapp 0.01초 → 합계 27.13초
  - WeatherSidecar: (27.12 / 27.13) × 100 = 99.96% → 99%로 표시
  - jpsamplewebapp: (0.01 / 27.13) × 100 = 0.04% → 0%로 표시
- CPU, Memory, Data Out 각각 독립적으로 비율 계산

## 사용 방법

### 1. 기본 실행
```bash
./collect_appservice_metrics.sh
```

### 2. 출력 파일
- CSV 파일명: `appservice_usage_report_YYYYMMDD_HHMMSS.csv`
- 위치: 스크립트와 동일한 디렉토리

### 3. 스크립트 설정 변경
스크립트 상단의 Configuration 섹션에서 설정 변경 가능:
```bash
DAYS_BACK=7        # 데이터 수집 기간 (기본: 7일)
INTERVAL="1h"      # 메트릭 수집 간격 (1h, 12h, 1d 등)
USD_TO_KRW=1400    # USD/KRW 환율 (기본: 1400)
```

### 4. 가격 정보 업데이트
`appservice_pricing.conf` 파일에서 SKU별 가격 수정 가능:
```bash
# Format: SKU|OS|Monthly_Price_USD
S1|linux|69.35
S1|windows|70.00
P2v3|linux|226.30
P2v3|windows|260.00
```

## CSV 파일 구조

| 컬럼명 | 설명 |
|--------|------|
| SubscriptionId | Azure 구독 ID |
| ResourceGroup | 리소스 그룹명 |
| AppServicePlan | App Service Plan 이름 |
| PlanSKU | Plan SKU (B1, S1, P1v2 등) |
| PlanTier | Plan 계층 (Basic, Standard, Premium 등) |
| PlanCapacity | 인스턴스 수 |
| Plan_AvgCPU% | Plan의 평균 CPU 사용률 (%) |
| Plan_AvgMemory% | Plan의 평균 메모리 사용률 (%) |
| Plan_AvgDataOut(MB) | Plan의 평균 시간당 Data Out (MB) |
| AppService | App Service 이름 (없으면 N/A) |
| AppService_AvgCPUTime(sec/hour) | App Service의 시간당 평균 CPU 시간 (초) + Plan 내 비율 (%) |
| AppService_AvgMemory(MB/hour) | App Service의 시간당 평균 메모리 (MB) + Plan 내 비율 (%) |
| AppService_AvgDataOut(MB/hour) | App Service의 시간당 평균 Data Out (MB) + Plan 내 비율 (%) |
| Billing_Allocation% | 과금 분배 비율 (CPU%, Memory%, Data Out%의 평균) |

## 과금 분배 활용 방안

### 1. Plan 수준 과금
Plan에 App Service가 없는 경우, 해당 Plan의 비용을 단독으로 할당

### 2. App Service별 비용 분배
같은 Plan 내 여러 App Service가 있는 경우, **Billing_Allocation%** 컬럼을 직접 사용:

**계산 방식:**
```
Billing_Allocation% = (CPU% + Memory% + Data Out%) / 3
```

**예시 (linuxplan - S1 Standard, 월 $70 가정):**
- App A: CPU 60%, Memory 70%, Data Out 80% → Billing 70% → $70 × 70% = $49
- App B: CPU 40%, Memory 30%, Data Out 20% → Billing 30% → $70 × 30% = $21

**실제 적용 예시:**
- ProductAPI: CPU 65%, Memory 60%, Data Out 70% → Billing 65% → 비용의 65%
- OrderService: CPU 35%, Memory 40%, Data Out 30% → Billing 35% → 비용의 35%

## 주의사항

1. **Dynamic Plan (Y1)**: Consumption 기반 Function App Plan은 메트릭이 다르게 동작할 수 있음
2. **N/A 값**: 메트릭 데이터가 없는 경우 N/A로 표시됨
   - 새로 생성된 리소스
   - 정지된 App Service
   - 메트릭 수집이 지원되지 않는 Plan 타입
3. **실행 시간**: App Service 수가 많을 경우 스크립트 실행에 시간이 소요될 수 있음

## 예시 출력

```
SubscriptionId,ResourceGroup,AppServicePlan,PlanSKU,PlanTier,PlanCapacity,Plan_AvgCPU%,Plan_AvgMemory%,Plan_AvgDataOut(MB),AppService,AppService_AvgCPUTime(sec/hour),AppService_AvgMemory(MB/hour),AppService_AvgDataOut(MB/hour),Billing_Allocation%
xxx-xxx-xxx,Appservice,linuxplan,S1,Standard,2,38.79,82.26,2450.00,ProductAPI,"35.40 (65.00%)","128.50 (60.00%)","543.20 (70.00%)",65.00
xxx-xxx-xxx,Appservice,linuxplan,S1,Standard,2,38.79,82.26,2450.00,OrderService,"19.10 (35.00%)","85.70 (40.00%)","232.80 (30.00%)",35.00
```

**데이터 해석:**
- ProductAPI는 시간당 평균 35.40초의 CPU, 128.50MB 메모리, 543.20MB Data Out 사용
- CPU 65%, Memory 60%, Data Out 70% → 과금 비율 65%

**과금 분배 예시 (Billing_Allocation% 사용):**
linuxplan의 월 비용이 $70라면:
- ProductAPI: $70 × 65% = $45.50
- OrderService: $70 × 35% = $24.50

합계: $45.50 + $24.50 = $70.00 ✅

## 요구사항
- Azure CLI 설치 및 로그인 필요 (또는 Azure Cloud Shell 사용)
- jq 패키지 설치 필요
- 구독에 대한 읽기 권한 필요
- Azure Monitor 메트릭 접근 권한 필요

**참고:** Azure Cloud Shell에서 바로 실행 가능 (bc 의존성 제거됨)

## 문제 해결

### Azure Cloud Shell에서 실행
스크립트는 Azure Cloud Shell에서 바로 실행 가능합니다:
```bash
# Cloud Shell에 업로드 후
chmod +x collect_appservice_metrics.sh
./collect_appservice_metrics.sh
```

### jq 미설치 (로컬 환경)
```bash
# Ubuntu/Debian
sudo apt-get install jq

# CentOS/RHEL
sudo yum install jq

# macOS
brew install jq
```

### Azure CLI 로그인
```bash
az login
az account set --subscription <subscription-id>
```

## 버전 정보
- 작성일: 2026-02-12
- 메트릭 수집 기간: 최근 7일
- 메트릭 수집 간격: 1시간
