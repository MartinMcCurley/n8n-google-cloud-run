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
    "REGION",
    "PROJECT_ID",
    "ARTIFACT_REGISTRY_REPO" # Specific repo name for this setup path
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

# Assign to local variables for clarity
$REGION = $env:REGION
$PROJECT_ID = $env:PROJECT_ID
$AR_REPO_NAME = $env:ARTIFACT_REGISTRY_REPO

Write-Host "Step 1: Enabling required Google Cloud APIs for project '$PROJECT_ID'..."
# Enable APIs
$apisToEnable = @(
    "artifactregistry.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "sqladmin.googleapis.com"
)
foreach ($api in $apisToEnable) {
    Write-Host "Enabling $api..."
    gcloud services enable $api --project=$PROJECT_ID
}

Write-Host "Step 2: Creating Artifact Registry repository '$AR_REPO_NAME' in region '$REGION'..."
$createArArgs = @(
    "artifacts", "repositories", "create", $AR_REPO_NAME,
    "--repository-format=docker",
    "--location=$REGION",
    "--description='Docker repository for MMA database n8n images'",
    "--project=$PROJECT_ID"
)
gcloud @createArArgs

Write-Host "Step 3: Configuring Docker for Artifact Registry $REGION-docker.pkg.dev..."
gcloud auth configure-docker "$REGION-docker.pkg.dev" --quiet --project=$PROJECT_ID

Write-Host "Artifact Registry setup completed successfully!"
Write-Host "Now you can run setup-postgres.ps1 to set up the PostgreSQL database."