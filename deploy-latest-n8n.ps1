# --- Configuration Variables (Adapt as needed) ---
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
    "N8N_VERSION_LATEST", 
    "SQL_INSTANCE_NAME_V4", 
    "DB_NAME_V4", 
    "DB_USER_V4", 
    "DB_PASSWORD_V4", 
    "DB_SECRET_NAME_V4", 
    "ENCRYPTION_KEY_SECRET_NAME_V2",
    "AR_REPO_NAME", 
    "SERVICE_ACCOUNT_NAME", 
    "CLOUD_RUN_SERVICE_NAME"
)

$missingVars = @()
foreach ($varName in $requiredVars) {
    # Use IsNullOrEmpty for robust check
    if ([string]::IsNullOrEmpty($env:$varName)) {
        $missingVars += $varName
    }
}

if ($missingVars.Count -gt 0) {
    Write-Host "Error: Required environment variables not set or empty in .env file: $($missingVars -join ', ')" -ForegroundColor Red
    exit 1
}

# Derive Service Account Email
$env:SERVICE_ACCOUNT_EMAIL = "$($env:SERVICE_ACCOUNT_NAME)@$($env:PROJECT_ID).iam.gserviceaccount.com"

Write-Host "Configuration loaded successfully from .env file."

# Get the SQL connection name
Write-Host "Getting SQL Connection Name for $($env:SQL_INSTANCE_NAME_V4)..."
$env:SQL_CONNECTION_NAME_V4 = $(gcloud sql instances describe $env:SQL_INSTANCE_NAME_V4 --format='value(connectionName)' 2>$null)
if ([string]::IsNullOrEmpty($env:SQL_CONNECTION_NAME_V4)) {
    Write-Host "Error: Could not get connection name for SQL instance $($env:SQL_INSTANCE_NAME_V4). Please verify the instance exists and the name is correct in your .env file." -ForegroundColor Red
    exit 1
}
Write-Host "SQL Connection Name: $($env:SQL_CONNECTION_NAME_V4)"

# Check if the database user exists
Write-Host "Checking DB User $($env:DB_USER_V4)..."
$userExists = $null
try {
    $userExists = $(gcloud sql users list --instance=$env:SQL_INSTANCE_NAME_V4 --filter="name=$($env:DB_USER_V4)" --format="value(name)" 2>$null)
} catch {
    Write-Host "Warning: Could not check if user '$($env:DB_USER_V4)' exists (maybe permissions issue?), but continuing script..." -ForegroundColor Yellow
}

if ([string]::IsNullOrEmpty($userExists)) {
    Write-Host "Creating user $($env:DB_USER_V4)..." -ForegroundColor Yellow
    # Use Invoke-Expression for commands with potential special characters in passwords
    Invoke-Expression "gcloud sql users create $($env:DB_USER_V4) --instance=$($env:SQL_INSTANCE_NAME_V4) --password='$($env:DB_PASSWORD_V4)' -q"
} else {
    Write-Host "User $($env:DB_USER_V4) already exists." -ForegroundColor Green
}

# Check if secret exists
Write-Host "Checking if secret $($env:DB_SECRET_NAME_V4) exists..."
$secretExists = $null
try {
    $secretExists = $(gcloud secrets describe $env:DB_SECRET_NAME_V4 --format="value(name)" 2>$null)
} catch {
    # Catching specific exception might be better, but this handles non-existence
    Write-Host "Secret '$($env:DB_SECRET_NAME_V4)' does not exist or cannot be accessed." -ForegroundColor Yellow
}

# Create or update the DB password secret
$tempPwFile = ".\temp_pw.txt"
$env:DB_PASSWORD_V4 | Out-File -Encoding ASCII -FilePath $tempPwFile -NoNewline
if ([string]::IsNullOrEmpty($secretExists)) {
    Write-Host "Creating secret $($env:DB_SECRET_NAME_V4)..."
    gcloud secrets create $env:DB_SECRET_NAME_V4 --data-file=$tempPwFile --replication-policy="automatic" -q
} else {
    Write-Host "Updating secret $($env:DB_SECRET_NAME_V4)..."
    gcloud secrets versions add $env:DB_SECRET_NAME_V4 --data-file=$tempPwFile -q
}
if (Test-Path $tempPwFile) { Remove-Item $tempPwFile }

# Ensure the service account can access the secret
Write-Host "Granting SA $($env:SERVICE_ACCOUNT_EMAIL) access to secret $($env:DB_SECRET_NAME_V4)..."
gcloud secrets add-iam-policy-binding $env:DB_SECRET_NAME_V4 `
    --member="serviceAccount:$($env:SERVICE_ACCOUNT_EMAIL)" `
    --role="roles/secretmanager.secretAccessor" -q

# 5. Prepare n8n Image using Cloud Build instead of local Docker
Write-Host "Preparing n8n image using Cloud Build..."
$env:OFFICIAL_N8N_IMAGE_LATEST="docker.n8n.io/n8nio/n8n:$($env:N8N_VERSION_LATEST)"
$env:AR_IMAGE_PATH_LATEST="$($env:REGION)-docker.pkg.dev/$($env:PROJECT_ID)/$($env:AR_REPO_NAME)/n8n:$($env:N8N_VERSION_LATEST)"

# Create Cloud Build config file using proper variable expansion
$cloudBuildConfigFile = ".\cloudbuild.yaml"
$cloudBuildConfig = @"
steps:
- name: 'gcr.io/cloud-builders/docker'
  args: ['pull', '$($env:OFFICIAL_N8N_IMAGE_LATEST)']
- name: 'gcr.io/cloud-builders/docker'
  args: ['tag', '$($env:OFFICIAL_N8N_IMAGE_LATEST)', '$($env:AR_IMAGE_PATH_LATEST)']
images: ['$($env:AR_IMAGE_PATH_LATEST)']
"@
$cloudBuildConfig | Out-File -Encoding ASCII -FilePath $cloudBuildConfigFile

# Run Cloud Build
Write-Host "Submitting Cloud Build job ($cloudBuildConfigFile)..."
gcloud builds submit --config=$cloudBuildConfigFile --no-source
if (Test-Path $cloudBuildConfigFile) { Remove-Item $cloudBuildConfigFile }

# 6. Update Cloud Run Service (use latest stable image, new DB resources, minimal vars, high compute)
Write-Host "Updating Cloud Run service $($env:CLOUD_RUN_SERVICE_NAME)..."

# Set required environment variables for the Cloud Run service
$cloudRunEnvVars = @("DB_TYPE=postgresdb", "DB_POSTGRESDB_DATABASE=$($env:DB_NAME_V4)", "DB_POSTGRESDB_USER=$($env:DB_USER_V4)", "DB_POSTGRESDB_HOST=/cloudsql/$($env:SQL_CONNECTION_NAME_V4)", "DB_POSTGRESDB_PORT=5432", "DB_POSTGRESDB_SCHEMA=public", "GENERIC_TIMEZONE=Europe/London", "N8N_PORT=5678", "QUEUE_HEALTH_CHECK_ACTIVE=true", "N8N_PATH=/") -join ","

# Set secrets to be mounted in the Cloud Run service
$cloudRunSecrets = @("DB_POSTGRESDB_PASSWORD=$($env:DB_SECRET_NAME_V4):latest", "N8N_ENCRYPTION_KEY=$($env:ENCRYPTION_KEY_SECRET_NAME_V2):latest") -join ","

# Update the service
gcloud run services update $env:CLOUD_RUN_SERVICE_NAME `
    --image=$env:AR_IMAGE_PATH_LATEST `
    --memory=4Gi `
    --cpu=2 `
    --platform=managed `
    --region=$env:REGION `
    --update-env-vars="$cloudRunEnvVars" `
    --set-secrets="$cloudRunSecrets" `
    --add-cloudsql-instances=$env:SQL_CONNECTION_NAME_V4 `
    --service-account=$env:SERVICE_ACCOUNT_EMAIL

# --- Verification ---
Write-Host "Deployment command sent. Check Cloud Run console for status."
Write-Host "Service URL (once ready): Check Cloud Run console or use 'gcloud run services describe ...'"
Write-Host "To view logs: gcloud run services logs tail $($env:CLOUD_RUN_SERVICE_NAME) --region=$($env:REGION) --project=$($env:PROJECT_ID)"