# MMA Database with n8n on Google Cloud Run

This repository contains scripts and configuration to deploy n8n workflow automation platform on Google Cloud Run with a PostgreSQL 13 database for the MMA database project.

## Overview

This deployment uses:
- n8n version 1.40.0 (can be upgraded to latest stable)
- PostgreSQL 13 database
- Google Cloud Run for serverless container hosting
- Google Cloud SQL for managed PostgreSQL
- Google Secret Manager for secure credentials storage

## Prerequisites

1. Google Cloud account with billing enabled
2. [Google Cloud SDK](https://cloud.google.com/sdk/docs/install) installed
3. [Docker](https://docs.docker.com/get-docker/) installed
4. PowerShell (this guide uses PowerShell commands)

## Setup Process

This deployment uses three PowerShell scripts to set up the infrastructure:

1. `setup-artifact-registry.ps1` - Sets up Google Cloud APIs and Artifact Registry
2. `setup-postgres.ps1` - Creates a PostgreSQL 13 database and service account
3. `deploy-n8n.ps1` - Builds and deploys the n8n container to Cloud Run

## Configuration

The scripts are pre-configured for the MMA database project using europe-west2 (London) region with the following settings:

- Project ID: metamma
- Region: europe-west2 (London)
- Database: PostgreSQL 13 (mma-db-pg13)
- n8n Container: 1.40.0-mma

All passwords and encryption keys are securely configured in the scripts.

## Deployment Steps

1. **Enable Google Cloud APIs and Set Up Artifact Registry**:
   ```powershell
   .\setup-artifact-registry.ps1
   ```

2. **Set Up PostgreSQL Database**:
   ```powershell
   .\setup-postgres.ps1
   ```

3. **Deploy n8n to Cloud Run**:
   ```powershell
   .\deploy-n8n.ps1
   ```

The deployment script will display the URL where your n8n instance is available.

## Using Environment Variables for Configuration

All deployment scripts **now require** configuration through environment variables, allowing you to customize your deployment without modifying the scripts directly. This is especially useful for:

1.  Avoiding hardcoded secrets and passwords in scripts
2.  Customizing your deployment for different environments
3.  Sharing the code without exposing sensitive information

### How to Use the `.env` File (Mandatory)

1.  **Create `.env`:** If you don't have a `.env` file, copy the example environment file to create your own:
    ```powershell
    # If you don't have an .env file yet:
    cp env.example .env 
    ```
    *Note: Ensure `env.example` exists or create `.env` manually.*

2.  **Edit `.env`:** Edit the `.env` file with your **specific, actual values** for all required variables listed in the `$requiredVars` array at the beginning of each script. These typically include:
    *   Project ID and region
    *   Database configuration (instance names, DB names, user names, passwords)
    *   Secret names and the encryption key itself (for initial setup)
    *   Service account names
    *   Artifact Registry repository name
    *   Container configuration (image names, tags, versions)

3.  **Run Scripts:** Run the deployment scripts as normal. They will **only** use the values from your `.env` file. **If any required variable is missing or empty, the script will stop with an error.**

### Environment Variables and Security

*   The `.gitignore` file is configured to exclude your `.env` file from version control.
*   The scripts **no longer contain default values**; they rely entirely on the `.env` file.
*   Sensitive values like passwords and keys defined in `.env` are used for initial resource creation (like setting the DB user password or creating secrets) but are then securely managed via Google Secret Manager for the running application.

This approach allows you to safely share and version control these scripts while keeping your specific configuration private in the `.env` file.

## Enhanced Reliability Features

This deployment includes several features to enhance reliability:

- **Database Connection Validation**: The startup script tests database connectivity before launching n8n
- **Health Check Endpoint**: Uses the `/healthz` endpoint for reliable container health monitoring
- **Improved Startup Checks**: Cloud Run configuration includes optimized startup probe settings
- **PostgreSQL Client**: Included in the container for database connection testing

## Resource Configuration

The default deployment includes:
- **Memory**: 1GB (suitable for basic workflows)
- **CPU**: 1 vCPU
- **Min Instances**: 1 (keeps n8n always running)
- **Concurrency**: 160 (max requests per instance)
- **Database**: PostgreSQL 13 on Cloud SQL (db-g1-small tier with 10GB storage)
- **Startup Duration**: Up to 900s allowed for complete startup
- **Health Checks**: Configured for both startup and liveness with appropriate thresholds

These resources can be adjusted based on your workload requirements. n8n's own service tiers for comparison:
- Basic: 320MB RAM, 10 millicore CPU
- Standard: 640MB RAM, 20 millicore CPU
- Professional: 1280MB RAM, 80 millicore CPU

## Managing Your n8n Instance

### Accessing the Admin Panel

After deployment, access your n8n instance at the URL provided in the deployment output. The default admin credentials will need to be set on first login.

### Checking Logs

```powershell
gcloud run services logs read mma-n8n-service --region=europe-west2
```

### Updating Environment Variables

```powershell
gcloud run services update mma-n8n-service --region=europe-west2 --set-env-vars="KEY=VALUE"
```

### Upgrading n8n Version

To upgrade to a newer n8n version:
1. Update the Dockerfile to reference the new version
2. Run the deploy-n8n.ps1 script again

## Important Environment Variables

The deployment includes these critical n8n environment variables:
- `N8N_HOST`: The domain where n8n is accessible
- `N8N_PROTOCOL`: Set to "https" for secure access
- `N8N_PATH`: Set to "/" to serve at the root path
- `WEBHOOK_URL`: External webhook URL (same as the instance URL)
- `N8N_ENCRYPTION_KEY`: Secret for encrypting workflow data
- `EXECUTIONS_PROCESS`: Set to "main" for Cloud Run compatibility
- `N8N_METRICS`: Enabled for health checks
- `N8N_METRICS_HTTP_ENDPOINT`: Set to "/healthz" for monitoring

## Troubleshooting

If you encounter issues:

1. Check Cloud Run logs:
   ```powershell
   gcloud run services logs read mma-n8n-service --region=europe-west2
   ```

2. Verify database connectivity:
   ```powershell
   gcloud sql instances describe mma-db-pg13
   ```

3. Common issues:
   - Container startup failures: Often related to environment variables or database connectivity
   - 404 errors: Check that N8N_PATH and N8N_HOST are set correctly
   - Database errors: Verify PostgreSQL connection settings and permissions

## Full Redeployment from Scratch

If you lose your n8n instance or need to start from a clean slate, follow these steps to fully redeploy using the scripts in this repository. This process assumes you have a fresh Google Cloud project and want to set up everything as intended by these scripts.

### **Step 0: Prerequisites**

Before you start, make sure you have:
- A Google Cloud project (with billing enabled)
- The [Google Cloud SDK](https://cloud.google.com/sdk/docs/install) installed and authenticated (`gcloud init`)
- [Docker](https://docs.docker.com/get-docker/) installed
- PowerShell available (Windows or via pwsh on other OS)
- Your project directory (`n8n-custom-image`) as your working directory

---

### **Step 1: Enable Google Cloud APIs & Set Up Artifact Registry**

Run the script to enable required APIs and create the Artifact Registry for Docker images:

```powershell
.\setup-artifact-registry.ps1
```

---

### **Step 2: Set Up PostgreSQL Database and Service Account**

Run the script to create your Cloud SQL PostgreSQL instance, database, user, secrets, and service account:

```powershell
.\setup-postgres.ps1
```

---

### **Step 3: Build and Deploy n8n to Cloud Run**

You have two deployment scripts. Use **one** depending on which setup you want:

#### **A. For the MMA custom setup:**

```powershell
.\deploy-n8n.ps1
```

- Builds your Docker image using the included `Dockerfile` and `startup.sh`
- Pushes the image to Artifact Registry
- Retrieves DB and secret info
- Deploys the container to Cloud Run with all required environment variables, secrets, and health checks

#### **B. For the latest n8n version (as per your newer script):**

If you want to deploy the latest n8n version (as defined in `deploy-latest-n8n.ps1`), run:

```powershell
.\deploy-latest-n8n.ps1
```

- Uses a prebuilt official n8n image (version set in the script)
- Tags and uploads it to your Artifact Registry via Cloud Build
- Ensures DB user and secrets exist and are up to date
- Updates the Cloud Run service to use the new image and DB credentials

---

### **Step 4: Access Your n8n Instance**

After deployment, the script will output the URL for your n8n instance, typically:

```
https://<cloud-run-service-name>-<project-number>.<region>.run.app
```

- Open this URL in your browser.
- On first login, set up your admin credentials.

---

### **Step 5: Managing and Troubleshooting**

- **View logs:**  
  ```powershell
  gcloud run services logs read mma-n8n-service --region=europe-west2
  ```
- **Check deployment status:**  
  ```powershell
  gcloud run services describe mma-n8n-service --region=europe-west2 --format='value(status)'
  ```
- **Update environment variables:**  
  ```powershell
  gcloud run services update mma-n8n-service --region=europe-west2 --set-env-vars="KEY=VALUE"
  ```

---

### **Summary Table**

| Step | Script/File                  | Purpose                                      |
|------|-----------------------------|----------------------------------------------|
| 1    | setup-artifact-registry.ps1  | Enable APIs, create Artifact Registry        |
| 2    | setup-postgres.ps1           | Create DB, user, secrets, service account    |
| 3    | deploy-n8n.ps1 or deploy-latest-n8n.ps1 | Build & deploy n8n to Cloud Run    |
| 4    | (Browser)                    | Access n8n at the provided URL               |
| 5    | (gcloud CLI)                 | Manage, update, or troubleshoot              |

---

If you follow these steps in order, you'll have a working n8n instance on Google Cloud Run, fully managed and ready to use! If you need a more detailed explanation of any step or want to know which script to use for your specific scenario, just ask. 