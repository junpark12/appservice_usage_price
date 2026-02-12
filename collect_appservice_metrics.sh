#!/bin/bash

# App Service Plan and App Service Usage Report Generator
# Purpose: Collect CPU and Memory usage metrics for billing allocation
# Date: $(date +%Y-%m-%d)

set -e

# Configuration
DAYS_BACK=7
INTERVAL="1h"
OUTPUT_CSV="appservice_usage_report_$(date +%Y%m%d_%H%M%S).csv"
START_TIME=$(date -u -d "$DAYS_BACK days ago" '+%Y-%m-%dT%H:%M:%SZ')
END_TIME=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
PRICING_FILE="$(dirname "$0")/appservice_pricing.conf"
USD_TO_KRW=1400  # Exchange rate: 1 USD = 1400 KRW

echo "========================================="
echo "App Service Usage Report Generator"
echo "========================================="
echo "Time Range: $START_TIME to $END_TIME"
echo "Interval: $INTERVAL"
echo "Output File: $OUTPUT_CSV"
echo ""

# Create CSV header
echo "SubscriptionId,ResourceGroup,AppServicePlan,PlanSKU,PlanTier,PlanCapacity,Plan_Monthly_Cost_USD,Plan_Monthly_Cost_KRW,Plan_AvgCPU%,Plan_AvgMemory%,Plan_AvgDataOut(MB),AppService,AppService_AvgCPUTime(sec/hour),AppService_AvgMemory(MB/hour),AppService_AvgDataOut(MB/hour),Billing_Allocation%,AppService_Monthly_Cost_USD,AppService_Monthly_Cost_KRW" > "$OUTPUT_CSV"

# Get current subscription info
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
SUBSCRIPTION_NAME=$(az account show --query name -o tsv)

echo "Analyzing Subscription: $SUBSCRIPTION_NAME ($SUBSCRIPTION_ID)"
echo ""

# Function to get price from pricing file
get_sku_price() {
    local sku="$1"
    local os="$2"
    if [ -f "$PRICING_FILE" ]; then
        grep "^${sku}|${os}|" "$PRICING_FILE" | cut -d'|' -f3 || echo "0"
    else
        echo "0"
    fi
}

# Get all App Service Plans in the subscription
echo "Fetching App Service Plans..."
PLANS=$(az appservice plan list --query "[].{id:id,name:name,rg:resourceGroup,sku:sku.name,tier:sku.tier,capacity:sku.capacity}" -o json)

PLAN_COUNT=$(echo "$PLANS" | jq -r 'length')
echo "Found $PLAN_COUNT App Service Plan(s)"
echo ""

# Temporary file to store app data
TEMP_APP_DATA=$(mktemp)

# Process each App Service Plan
echo "$PLANS" | jq -c '.[]' | while IFS= read -r plan; do
    PLAN_NAME=$(echo "$plan" | jq -r '.name')
    PLAN_RG=$(echo "$plan" | jq -r '.rg')
    PLAN_ID=$(echo "$plan" | jq -r '.id')
    PLAN_SKU=$(echo "$plan" | jq -r '.sku')
    PLAN_TIER=$(echo "$plan" | jq -r '.tier')
    PLAN_CAPACITY=$(echo "$plan" | jq -r '.capacity // "N/A"')
    
    # Get Plan kind (linux or windows)
    PLAN_KIND=$(az appservice plan show --ids "$PLAN_ID" --query "kind" -o tsv 2>/dev/null || echo "windows")
    # Extract OS from kind (e.g., "linux" or "app" for windows)
    if [[ "$PLAN_KIND" == *"linux"* ]]; then
        PLAN_OS="linux"
    else
        PLAN_OS="windows"
    fi
    
    echo "Processing Plan: $PLAN_NAME (RG: $PLAN_RG, OS: $PLAN_OS)"
    
    # Get App Service Plan level metrics (CPU Percentage)
    echo "  - Fetching Plan CPU metrics..."
    PLAN_CPU=$(az monitor metrics list \
        --resource "$PLAN_ID" \
        --metric "CpuPercentage" \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --interval "$INTERVAL" \
        --aggregation Average \
        --query "value[0].timeseries[0].data[].average" \
        -o tsv 2>/dev/null | awk '{sum+=$1; count++} END {if(count>0) printf "%.2f", sum/count; else print "N/A"}')
    
    # Get App Service Plan level metrics (Memory Percentage)
    echo "  - Fetching Plan Memory metrics..."
    PLAN_MEMORY=$(az monitor metrics list \
        --resource "$PLAN_ID" \
        --metric "MemoryPercentage" \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --interval "$INTERVAL" \
        --aggregation Average \
        --query "value[0].timeseries[0].data[].average" \
        -o tsv 2>/dev/null | awk '{sum+=$1; count++} END {if(count>0) printf "%.2f", sum/count; else print "N/A"}')
    
    # Get App Service Plan level metrics (Data Out - BytesSent in MB)
    echo "  - Fetching Plan Data Out metrics..."
    PLAN_DATAOUT=$(az monitor metrics list \
        --resource "$PLAN_ID" \
        --metric "BytesSent" \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --interval "$INTERVAL" \
        --aggregation Total \
        --query "value[0].timeseries[0].data[].total" \
        -o tsv 2>/dev/null | awk '{sum+=$1; count++} END {if(count>0) printf "%.2f", sum/count/1024/1024; else print "N/A"}')
    
    echo "  - Plan Average CPU: $PLAN_CPU%, Memory: $PLAN_MEMORY%, Data Out: ${PLAN_DATAOUT}MB"
    
    # Get pricing information
    UNIT_PRICE=$(get_sku_price "$PLAN_SKU" "$PLAN_OS")
    PLAN_TOTAL_COST_USD=$(awk -v price="$UNIT_PRICE" -v cap="$PLAN_CAPACITY" 'BEGIN {printf "%.2f", price * cap}')
    PLAN_TOTAL_COST_KRW=$(awk -v cost="$PLAN_TOTAL_COST_USD" -v rate="$USD_TO_KRW" 'BEGIN {printf "%.0f", cost * rate}')
    
    echo "  - Plan Monthly Cost: \$${PLAN_TOTAL_COST_USD} USD (₩${PLAN_TOTAL_COST_KRW} KRW) - $PLAN_OS"
    
    # Get all App Services in this Plan
    echo "  - Fetching App Services in this Plan..."
    APPS=$(az webapp list --query "[?appServicePlanId=='$PLAN_ID'].{name:name,id:id}" -o json)
    
    APP_COUNT=$(echo "$APPS" | jq -r 'length')
    echo "  - Found $APP_COUNT App Service(s)"
    
    if [ "$APP_COUNT" -eq 0 ]; then
        # No apps in this plan, write plan-only row
        echo "$SUBSCRIPTION_ID,$PLAN_RG,$PLAN_NAME,$PLAN_SKU,$PLAN_TIER,$PLAN_CAPACITY,$PLAN_TOTAL_COST_USD,$PLAN_TOTAL_COST_KRW,$PLAN_CPU,$PLAN_MEMORY,$PLAN_DATAOUT,N/A,N/A,N/A,N/A,N/A,N/A,N/A" >> "$OUTPUT_CSV"
    else
        # First pass: collect all app metrics
        > "$TEMP_APP_DATA"  # Clear temp file
        TOTAL_CPU=0
        TOTAL_MEMORY=0
        
        echo "$APPS" | jq -c '.[]' | while IFS= read -r app; do
            APP_NAME=$(echo "$app" | jq -r '.name')
            APP_ID=$(echo "$app" | jq -r '.id')
            
            echo "    - Processing App: $APP_NAME"
            
            # Get App Service level metrics (CPU Time in seconds - total over period)
            APP_CPU_TIME=$(az monitor metrics list \
                --resource "$APP_ID" \
                --metric "CpuTime" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --interval "$INTERVAL" \
                --aggregation Total \
                --query "value[0].timeseries[0].data[].total" \
                -o tsv 2>/dev/null | awk '{sum+=$1; count++} END {if(count>0) printf "%.2f", sum/count; else print "0"}')
            
            # Get App Service level metrics (Average Memory Working Set in MB)
            APP_MEMORY=$(az monitor metrics list \
                --resource "$APP_ID" \
                --metric "AverageMemoryWorkingSet" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --interval "$INTERVAL" \
                --aggregation Average \
                --query "value[0].timeseries[0].data[].average" \
                -o tsv 2>/dev/null | awk '{sum+=$1; count++} END {if(count>0) printf "%.2f", sum/count/1024/1024; else print "0"}')
            
            # Get App Service level metrics (Data Out - BytesSent in MB per hour)
            APP_DATAOUT=$(az monitor metrics list \
                --resource "$APP_ID" \
                --metric "BytesSent" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --interval "$INTERVAL" \
                --aggregation Total \
                --query "value[0].timeseries[0].data[].total" \
                -o tsv 2>/dev/null | awk '{sum+=$1; count++} END {if(count>0) printf "%.2f", sum/count/1024/1024; else print "0"}')
            
            echo "      Raw - CPU: ${APP_CPU_TIME}sec, Memory: ${APP_MEMORY}MB, Data Out: ${APP_DATAOUT}MB"
            
            # Store values in temp file
            echo "$APP_NAME|$APP_CPU_TIME|$APP_MEMORY|$APP_DATAOUT" >> "$TEMP_APP_DATA"
        done
        
        # Calculate totals
        TOTAL_CPU=$(awk -F'|' '{sum+=$2} END {printf "%.2f", sum}' "$TEMP_APP_DATA")
        TOTAL_MEMORY=$(awk -F'|' '{sum+=$3} END {printf "%.2f", sum}' "$TEMP_APP_DATA")
        TOTAL_DATAOUT=$(awk -F'|' '{sum+=$4} END {printf "%.2f", sum}' "$TEMP_APP_DATA")
        
        echo "  - Plan Total from Apps - CPU: ${TOTAL_CPU}sec, Memory: ${TOTAL_MEMORY}MB, Data Out: ${TOTAL_DATAOUT}MB"
        
        # Second pass: calculate percentages and write to CSV
        while IFS='|' read -r APP_NAME APP_CPU_RAW APP_MEMORY_RAW APP_DATAOUT_RAW; do
            # Calculate CPU percentage using awk
            CPU_PERCENT=$(awk -v raw="$APP_CPU_RAW" -v total="$TOTAL_CPU" 'BEGIN {if(total>0) printf "%.2f", (raw/total)*100; else print "0"}')
            if awk -v total="$TOTAL_CPU" 'BEGIN {exit !(total > 0)}'; then
                APP_CPU_DISPLAY="$APP_CPU_RAW ($CPU_PERCENT%)"
            else
                CPU_PERCENT=0
                APP_CPU_DISPLAY="N/A"
            fi
            
            # Calculate Memory percentage using awk
            MEMORY_PERCENT=$(awk -v raw="$APP_MEMORY_RAW" -v total="$TOTAL_MEMORY" 'BEGIN {if(total>0) printf "%.2f", (raw/total)*100; else print "0"}')
            if awk -v total="$TOTAL_MEMORY" 'BEGIN {exit !(total > 0)}'; then
                APP_MEMORY_DISPLAY="$APP_MEMORY_RAW ($MEMORY_PERCENT%)"
            else
                MEMORY_PERCENT=0
                APP_MEMORY_DISPLAY="N/A"
            fi
            
            # Calculate Data Out percentage using awk
            DATAOUT_PERCENT=$(awk -v raw="$APP_DATAOUT_RAW" -v total="$TOTAL_DATAOUT" 'BEGIN {if(total>0) printf "%.2f", (raw/total)*100; else print "0"}')
            if awk -v total="$TOTAL_DATAOUT" 'BEGIN {exit !(total > 0)}'; then
                APP_DATAOUT_DISPLAY="$APP_DATAOUT_RAW ($DATAOUT_PERCENT%)"
            else
                DATAOUT_PERCENT=0
                APP_DATAOUT_DISPLAY="N/A"
            fi
            
            # Calculate Billing Allocation (average of CPU, Memory, and Data Out percentages) using awk
            if [[ "$APP_CPU_DISPLAY" != "N/A" && "$APP_MEMORY_DISPLAY" != "N/A" && "$APP_DATAOUT_DISPLAY" != "N/A" ]]; then
                BILLING_ALLOCATION=$(awk -v cpu="$CPU_PERCENT" -v mem="$MEMORY_PERCENT" -v data="$DATAOUT_PERCENT" 'BEGIN {printf "%.2f", (cpu+mem+data)/3}')
            else
                BILLING_ALLOCATION="N/A"
            fi
            
            # Calculate App Service cost based on billing allocation
            if [[ "$BILLING_ALLOCATION" != "N/A" ]]; then
                APP_COST_USD=$(awk -v total="$PLAN_TOTAL_COST_USD" -v alloc="$BILLING_ALLOCATION" 'BEGIN {printf "%.2f", total * alloc / 100}')
                APP_COST_KRW=$(awk -v cost="$APP_COST_USD" -v rate="$USD_TO_KRW" 'BEGIN {printf "%.0f", cost * rate}')
            else
                APP_COST_USD="N/A"
                APP_COST_KRW="N/A"
            fi
            
            echo "      $APP_NAME - CPU: $APP_CPU_DISPLAY, Memory: $APP_MEMORY_DISPLAY, Data Out: $APP_DATAOUT_DISPLAY, Billing: $BILLING_ALLOCATION%, Cost: \$${APP_COST_USD} (₩${APP_COST_KRW})"
            
            # Write to CSV with quotes for fields containing parentheses
            echo "$SUBSCRIPTION_ID,$PLAN_RG,$PLAN_NAME,$PLAN_SKU,$PLAN_TIER,$PLAN_CAPACITY,$PLAN_TOTAL_COST_USD,$PLAN_TOTAL_COST_KRW,$PLAN_CPU,$PLAN_MEMORY,$PLAN_DATAOUT,$APP_NAME,\"$APP_CPU_DISPLAY\",\"$APP_MEMORY_DISPLAY\",\"$APP_DATAOUT_DISPLAY\",$BILLING_ALLOCATION,$APP_COST_USD,$APP_COST_KRW" >> "$OUTPUT_CSV"
        done < "$TEMP_APP_DATA"
    fi
    
    echo ""
done

# Cleanup
rm -f "$TEMP_APP_DATA"

echo "========================================="
echo "Report generation completed!"
echo "Output file: $OUTPUT_CSV"
echo "========================================="
echo ""
echo "Summary:"
wc -l "$OUTPUT_CSV" | awk '{print "Total rows (including header): " $1}'
echo ""
echo "Preview (first 10 rows):"
head -10 "$OUTPUT_CSV" | column -t -s','
