# Use the specific version we know starts correctly
FROM docker.n8n.io/n8nio/n8n:1.40.0

# Switch to root for installation
USER root

# Install curl for health checks
RUN apk --no-cache add curl

# Install PostgreSQL client, sudo and other required utilities
RUN apk --no-cache add postgresql-client sudo

# Configure sudo for node user
RUN echo "node ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/node && \
    chmod 0440 /etc/sudoers.d/node

# Copy startup script
COPY startup.sh /
RUN chmod +x /startup.sh

# Create a directory for n8n data and set proper permissions
RUN mkdir -p /home/node/.n8n && \
    chown -R node:node /home/node/.n8n

# Switch back to node user for runtime
USER node

# Set environment variables
ENV N8N_PORT=5678
ENV N8N_SKIP_WEBHOOK_DEREGISTRATION_SHUTDOWN=true
ENV N8N_USER_FOLDER=/home/node/.n8n
ENV NODE_ENV=production
ENV N8N_DIAGNOSTICS_ENABLED=false
ENV N8N_METRICS=true
ENV N8N_METRICS_HTTP_ENDPOINT="/healthz"
ENV N8N_PATH=/
ENV N8N_HOST=0.0.0.0

# Expose port
EXPOSE 5678

# Set healthcheck
HEALTHCHECK --interval=30s --timeout=15s --start-period=45s --retries=3 \
  CMD curl -f http://localhost:${N8N_PORT}/healthz || exit 1

# Use startup script
CMD ["/startup.sh"]