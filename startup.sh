#!/bin/sh
set -e

# Print environment variables for debugging
echo "Startup Script Running..."
echo "PORT (from Cloud Run): $PORT"

# Set PORT for n8n
if [ -n "$PORT" ]; then
  export N8N_PORT=$PORT
else
  export PORT=5678
  export N8N_PORT=5678
fi

# Ensure N8N_HOST is set to 0.0.0.0 for proper binding
export N8N_HOST="0.0.0.0"

# Set health check endpoint
export N8N_METRICS_HTTP_ENDPOINT="/healthz"
export N8N_METRICS=true

# Print configuration
echo "Final configuration:"
echo "PORT: $PORT"
echo "N8N_PORT: $N8N_PORT"
echo "N8N_HOST: $N8N_HOST"
echo "DB_TYPE: $DB_TYPE"
echo "DB_POSTGRESDB_HOST: $DB_POSTGRESDB_HOST"
echo "N8N_METRICS_HTTP_ENDPOINT: $N8N_METRICS_HTTP_ENDPOINT"

# Improved database wait logic with retry
if [ "$DB_TYPE" = "postgresdb" ]; then
  echo "Postgres database configured. Checking connection..."
  MAX_RETRIES=30
  RETRY_INTERVAL=2
  RETRIES=0
  
  until PGPASSWORD=$DB_POSTGRESDB_PASSWORD psql -h "$DB_POSTGRESDB_HOST" -U "$DB_POSTGRESDB_USER" -d "$DB_POSTGRESDB_DATABASE" -c "SELECT 1" > /dev/null 2>&1; do
    RETRIES=$((RETRIES+1))
    if [ $RETRIES -ge $MAX_RETRIES ]; then
      echo "Error: Failed to connect to database after $MAX_RETRIES attempts. Exiting."
      exit 1
    fi
    echo "Waiting for database to be ready... Attempt $RETRIES of $MAX_RETRIES"
    sleep $RETRY_INTERVAL
  done
  
  echo "Database connection successful!"
else
  echo "Not using Postgres database, skipping connection check."
fi

# Ensure data directory is writable
if [ ! -d "/home/node/.n8n" ]; then
  mkdir -p /home/node/.n8n
fi
chown -R node:node /home/node/.n8n

# Print startup message
echo "Starting n8n on port $N8N_PORT..."

# Start n8n as the node user
exec sudo -E -u node node /usr/local/lib/node_modules/n8n/bin/n8n start