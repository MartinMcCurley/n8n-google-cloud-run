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

# Check for essential environment variables for this script
$requiredVars = @(
    "REGION",
    "PROJECT_ID",
    "SQL_INSTANCE_NAME", # Uses the specific name for this setup
    "DB_NAME",
    "DB_USER",
    "DB_PASSWORD", # Actual password needed for initial setup/update
    "DB_SECRET_NAME",
    "ENCRYPTION_KEY", # Actual key needed for initial setup/update
    "ENCRYPTION_KEY_SECRET_NAME",
    "N8N_SA_NAME" # Service account name specific to this setup
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

Write-Host "Configuration loaded successfully."

# Assign loaded env vars to local script variables for clarity/consistency with original script
$REGION = $env:REGION
$PROJECT_ID = $env:PROJECT_ID
$SQL_INSTANCE_NAME = $env:SQL_INSTANCE_NAME
$DB_NAME = $env:DB_NAME
$DB_USER = $env:DB_USER
$DB_PASSWORD = $env:DB_PASSWORD
$DB_SECRET_NAME = $env:DB_SECRET_NAME
$ENCRYPTION_KEY = $env:ENCRYPTION_KEY
$ENCRYPTION_KEY_SECRET_NAME = $env:ENCRYPTION_KEY_SECRET_NAME
$SERVICE_ACCOUNT_NAME = $env:N8N_SA_NAME # Use the specific SA name for this path
$SERVICE_ACCOUNT_EMAIL = "$SERVICE_ACCOUNT_NAME@$PROJECT_ID.iam.gserviceaccount.com"


Write-Host "Step 1: Creating PostgreSQL 13 instance '$SQL_INSTANCE_NAME'..."
$createInstanceArgs = @(
    "sql", "instances", "create", $SQL_INSTANCE_NAME,
    "--database-version=POSTGRES_13",
    "--tier=db-g1-small",
    "--region=$REGION",
    "--storage-type=SSD",
    "--storage-size=10GB",
    "--availability-type=ZONAL",
    "--root-password=$DB_PASSWORD" # Note: Root password set here
)
Write-Host "Executing: gcloud $($createInstanceArgs -join ' ')"
gcloud @createInstanceArgs

Write-Host "Step 2: Creating database '$DB_NAME'..."
gcloud sql databases create $DB_NAME --instance=$SQL_INSTANCE_NAME

Write-Host "Step 3: Creating user '$DB_USER'..."
# Use Invoke-Command for password handling robustness
Invoke-Command -ScriptBlock { gcloud sql users create $using:DB_USER --instance=$using:SQL_INSTANCE_NAME --password=$using:DB_PASSWORD }

Write-Host "Step 4: Creating secrets in Secret Manager..."
# Create DB password secret
Write-Host "Creating secret '$DB_SECRET_NAME'..."
Invoke-Command -ScriptBlock { $using:DB_PASSWORD | gcloud secrets create $using:DB_SECRET_NAME --data-file=- }

# Create encryption key secret
Write-Host "Creating secret '$ENCRYPTION_KEY_SECRET_NAME'..."
Invoke-Command -ScriptBlock { $using:ENCRYPTION_KEY | gcloud secrets create $using:ENCRYPTION_KEY_SECRET_NAME --data-file=- }

Write-Host "Step 5: Creating service account '$SERVICE_ACCOUNT_NAME'..."
gcloud iam service-accounts create $SERVICE_ACCOUNT_NAME --display-name='MMA Database n8n Service Account'

Write-Host "Step 6: Granting permissions to service account '$SERVICE_ACCOUNT_EMAIL'..."
# Grant Cloud SQL Client role
Write-Host "Granting roles/cloudsql.client..."
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" --role="roles/cloudsql.client"

# Grant Secret Manager Secret Accessor role
Write-Host "Granting roles/secretmanager.secretAccessor..."
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" --role="roles/secretmanager.secretAccessor"

Write-Host "Step 7: Setting password for user '$DB_USER' (ensures consistency)..."
# Use Invoke-Command for password handling robustness
Invoke-Command -ScriptBlock { gcloud sql users set-password $using:DB_USER --instance=$using:SQL_INSTANCE_NAME --password=$using:DB_PASSWORD }

Write-Host "Step 8: Adding current values as latest secret versions..."
# Update DB password secret version
Write-Host "Adding new version to secret '$DB_SECRET_NAME'..."
Invoke-Command -ScriptBlock { $using:DB_PASSWORD | gcloud secrets versions add $using:DB_SECRET_NAME --data-file=- }

# Update encryption key secret version
Write-Host "Adding new version to secret '$ENCRYPTION_KEY_SECRET_NAME'..."
Invoke-Command -ScriptBlock { $using:ENCRYPTION_KEY | gcloud secrets versions add $using:ENCRYPTION_KEY_SECRET_NAME --data-file=- }

Write-Host "PostgreSQL setup completed successfully!"
Write-Host "Now you can run deploy-n8n.ps1 to deploy your MMA database n8n instance."