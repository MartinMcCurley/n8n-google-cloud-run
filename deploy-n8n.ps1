#!/usr/bin/env pwsh
# Script to deploy n8n to Google Cloud Run

# Load environment variables from .env file
$envFilePath = ".env"

if (-not (Test-Path $envFilePath)) {
    Write-Host "Error: .env file not found at '$envFilePath'. Please create it." -ForegroundColor Red
    exit 1
}

Write-Host "Loading configuration from $envFilePath..."
Get-Content $envFilePath | ForEach-Object {
    $line = $_.Trim()
    # Skip comments and empty lines
    if ($line -and $line -notmatch '^\s*#') {
        $parts = $line -split '=', 2
        if ($parts.Length -eq 2) {
            $key = $parts[0].Trim()
            $value = $parts[1].Trim()
            # Remove surrounding quotes (double or single)
            if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            # Set environment variable for the current process
            [System.Environment]::SetEnvironmentVariable($key, $value, [System.EnvironmentVariableTarget]::Process)
            # Write-Host "Loaded: $key" # Optional debug output
        }
    }
}

# Check for essential environment variables
$requiredVars = @(
    "PROJECT_ID",
    "REGION",
    "ARTIFACT_REGISTRY_REPO",
    "IMAGE_NAME",
    "IMAGE_TAG",
    "CLOUD_RUN_SERVICE_NAME",
    "N8N_SA_NAME",
    "SQL_INSTANCE_NAME", # Note: Uses SQL_INSTANCE_NAME, not V4
    "DB_NAME",
    "DB_USER",
    "DB_SECRET_NAME",
    "ENCRYPTION_KEY_SECRET_NAME" # Note: Uses original secret name
)

$missingVars = @()
foreach ($varName in $requiredVars) {
    # Use Test-Path combined with IsNullOrEmpty for robust check
    if (-not (Test-Path "Env:\$varName") -or [string]::IsNullOrEmpty($env:$varName)) {
        $missingVars += $varName
    }
}

if ($missingVars.Count -gt 0) {
    Write-Host "Error: Required environment variables not set or empty in .env file: $($missingVars -join ', ')" -ForegroundColor Red
    exit 1
}

# Construct full image path using environment variables
$FULL_IMAGE_PATH = "$($env:REGION)-docker.pkg.dev/$($env:PROJECT_ID)/$($env:ARTIFACT_REGISTRY_REPO)/$($env:IMAGE_NAME):$($env:IMAGE_TAG)"

Write-Host "Starting deployment process for n8n on Google Cloud Run..."
Write-Host "Using Image: $FULL_IMAGE_PATH"

# Build the Docker image
Write-Host "Building Docker image..."
docker build -t $FULL_IMAGE_PATH .

# Authenticate Docker to Artifact Registry
Write-Host "Authenticating Docker to Artifact Registry..."
gcloud auth configure-docker $env:REGION-docker.pkg.dev --quiet

# Push the image to Artifact Registry
Write-Host "Pushing image to Artifact Registry..."
docker push $FULL_IMAGE_PATH

# Get Database connection information for Cloud Run
Write-Host "Getting database connection information for instance $($env:SQL_INSTANCE_NAME)..."
$DB_HOST = $(gcloud sql instances describe $env:SQL_INSTANCE_NAME --format='value(ipAddresses.ipAddress)' 2>$null)
$DB_CONNECTION_NAME = $(gcloud sql instances describe $env:SQL_INSTANCE_NAME --format='value(connectionName)' 2>$null)

if ([string]::IsNullOrEmpty($DB_CONNECTION_NAME)) {
    Write-Host "Error: Could not get connection name for SQL instance $($env:SQL_INSTANCE_NAME). Verify name in .env and instance exists." -ForegroundColor Red
    exit 1
}

# Get project number for the URL (needed for WEBHOOK_TUNNEL_URL)
$PROJECT_NUMBER = $(gcloud projects describe $env:PROJECT_ID --format='value(projectNumber)')

# Define Cloud Run Environment Variables
$cloudRunEnvVars = @(
    "NODE_ENV=production",
    "WEBHOOK_TUNNEL_URL=https://$($env:CLOUD_RUN_SERVICE_NAME)-$PROJECT_NUMBER.$($env:REGION).run.app/",
    "DB_TYPE=postgresdb",
    "DB_POSTGRESDB_DATABASE=$($env:DB_NAME)",
    "DB_POSTGRESDB_HOST=$DB_HOST", # Uses direct IP, not Cloud SQL Proxy path
    "DB_POSTGRESDB_PORT=5432",
    "DB_POSTGRESDB_USER=$($env:DB_USER)",
    "N8N_METRICS=false", # Check if this should be true based on Dockerfile (Dockerfile says true)
    "N8N_DIAGNOSTICS_ENABLED=false",
    "N8N_PATH=/",
    "N8N_HOST=0.0.0.0",
    "N8N_SKIP_WEBHOOK_DEREGISTRATION_SHUTDOWN=true",
    "N8N_USER_FOLDER=/home/node/.n8n"
) -join ","

# Define Cloud Run Secrets
$cloudRunSecrets = @(
    "DB_POSTGRESDB_PASSWORD=$($env:DB_SECRET_NAME):latest",
    "N8N_ENCRYPTION_KEY=$($env:ENCRYPTION_KEY_SECRET_NAME):latest"
) -join ","

# Service account email is derived
$SERVICE_ACCOUNT_EMAIL = "$($env:N8N_SA_NAME)@$($env:PROJECT_ID).iam.gserviceaccount.com"

# Deploy to Cloud Run
Write-Host "Deploying to Cloud Run service $($env:CLOUD_RUN_SERVICE_NAME)..."
gcloud run deploy $env:CLOUD_RUN_SERVICE_NAME `
  --image=$FULL_IMAGE_PATH `
  --platform=managed `
  --region=$env:REGION `
  --allow-unauthenticated `
  --service-account=$SERVICE_ACCOUNT_EMAIL `
  --memory=1Gi `
  --cpu=1 `
  --min-instances=1 `
  --max-instances=20 `
  --concurrency=160 `
  --update-env-vars="$cloudRunEnvVars" `
  --set-secrets="$cloudRunSecrets" `
  --port=5678 `
  --no-cpu-throttling `
  --startup-cpu-boost `
  --timeout=900s `
  --cpu-always-allocated `
  --execution-environment=gen2 `
  # Note: Cloud SQL Proxy connection (`--add-cloudsql-instances`) is NOT used here
  # If DB_POSTGRESDB_HOST needs proxy, this must be added and HOST changed to /cloudsql/...
  # --add-cloudsql-instances=$DB_CONNECTION_NAME ` 
  # Volume mounting seems specific to this deployment - ensure it's needed
  --add-volume=mount=data-volume,target=/home/node/.n8n `
  --add-volume-mode=mount=data-volume,mode=rw `
  --container-command=/startup.sh ` # Assumes startup.sh handles DB wait etc.
  --http-probe-startup-path=/healthz `
  --http-probe-startup-initial-delay=180s `
  --startup-probe-failure-threshold=15 `
  --startup-probe-period=30s `
  --liveness-http-probe-path=/healthz `
  --liveness-probe-period=60s `
  --liveness-probe-timeout=15s `
  --liveness-probe-failure-threshold=3 `
  --min-instances-always-allocated=1

Write-Host "Deployment complete!"
Write-Host "Your n8n instance should be available shortly at: https://$($env:CLOUD_RUN_SERVICE_NAME)-$PROJECT_NUMBER.$($env:REGION).run.app" 