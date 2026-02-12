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

echo "========================================="
echo "App Service Usage Report Generator"
echo "========================================="
echo "Time Range: $START_TIME to $END_TIME"
echo "Interval: $INTERVAL"
echo "Output File: $OUTPUT_CSV"
echo ""

# Create CSV header
echo "SubscriptionId,SubscriptionName,ResourceGroup,AppServicePlan,PlanSKU,PlanTier,PlanCapacity,Plan_AvgCPU%,Plan_AvgMemory%,AppService,AppService_AvgCPUTime(sec/hour),AppService_AvgMemory(MB/hour),Billing_Allocation%" > "$OUTPUT_CSV"

# Get current subscription info
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
SUBSCRIPTION_NAME=$(az account show --query name -o tsv)

echo "Analyzing Subscription: $SUBSCRIPTION_NAME ($SUBSCRIPTION_ID)"
echo ""

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
    
    echo "Processing Plan: $PLAN_NAME (RG: $PLAN_RG)"
    
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
    
    echo "  - Plan Average CPU: $PLAN_CPU%, Memory: $PLAN_MEMORY%"
    
    # Get all App Services in this Plan
    echo "  - Fetching App Services in this Plan..."
    APPS=$(az webapp list --query "[?appServicePlanId=='$PLAN_ID'].{name:name,id:id}" -o json)
    
    APP_COUNT=$(echo "$APPS" | jq -r 'length')
    echo "  - Found $APP_COUNT App Service(s)"
    
    if [ "$APP_COUNT" -eq 0 ]; then
        # No apps in this plan, write plan-only row
        echo "$SUBSCRIPTION_ID,$SUBSCRIPTION_NAME,$PLAN_RG,$PLAN_NAME,$PLAN_SKU,$PLAN_TIER,$PLAN_CAPACITY,$PLAN_CPU,$PLAN_MEMORY,N/A,N/A,N/A,N/A" >> "$OUTPUT_CSV"
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
            
            echo "      Raw - CPU: ${APP_CPU_TIME}sec, Memory: ${APP_MEMORY}MB"
            
            # Store values in temp file
            echo "$APP_NAME|$APP_CPU_TIME|$APP_MEMORY" >> "$TEMP_APP_DATA"
        done
        
        # Calculate totals
        TOTAL_CPU=$(awk -F'|' '{sum+=$2} END {printf "%.2f", sum}' "$TEMP_APP_DATA")
        TOTAL_MEMORY=$(awk -F'|' '{sum+=$3} END {printf "%.2f", sum}' "$TEMP_APP_DATA")
        
        echo "  - Plan Total from Apps - CPU: ${TOTAL_CPU}sec, Memory: ${TOTAL_MEMORY}MB"
        
        # Second pass: calculate percentages and write to CSV
        while IFS='|' read -r APP_NAME APP_CPU_RAW APP_MEMORY_RAW; do
            # Calculate CPU percentage
            if (( $(echo "$TOTAL_CPU > 0" | bc -l) )); then
                CPU_PERCENT=$(echo "scale=2; ($APP_CPU_RAW / $TOTAL_CPU) * 100" | bc)
                APP_CPU_DISPLAY="$APP_CPU_RAW ($CPU_PERCENT%)"
            else
                CPU_PERCENT=0
                APP_CPU_DISPLAY="N/A"
            fi
            
            # Calculate Memory percentage
            if (( $(echo "$TOTAL_MEMORY > 0" | bc -l) )); then
                MEMORY_PERCENT=$(echo "scale=2; ($APP_MEMORY_RAW / $TOTAL_MEMORY) * 100" | bc)
                APP_MEMORY_DISPLAY="$APP_MEMORY_RAW ($MEMORY_PERCENT%)"
            else
                MEMORY_PERCENT=0
                APP_MEMORY_DISPLAY="N/A"
            fi
            
            # Calculate Billing Allocation (average of CPU and Memory percentages)
            if [[ "$APP_CPU_DISPLAY" != "N/A" && "$APP_MEMORY_DISPLAY" != "N/A" ]]; then
                BILLING_ALLOCATION=$(echo "scale=2; ($CPU_PERCENT + $MEMORY_PERCENT) / 2" | bc)
            else
                BILLING_ALLOCATION="N/A"
            fi
            
            echo "      $APP_NAME - CPU: $APP_CPU_DISPLAY, Memory: $APP_MEMORY_DISPLAY, Billing: $BILLING_ALLOCATION%"
            
            # Write to CSV with quotes for fields containing parentheses
            echo "$SUBSCRIPTION_ID,$SUBSCRIPTION_NAME,$PLAN_RG,$PLAN_NAME,$PLAN_SKU,$PLAN_TIER,$PLAN_CAPACITY,$PLAN_CPU,$PLAN_MEMORY,$APP_NAME,\"$APP_CPU_DISPLAY\",\"$APP_MEMORY_DISPLAY\",$BILLING_ALLOCATION" >> "$OUTPUT_CSV"
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
