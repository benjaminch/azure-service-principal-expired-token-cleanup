FROM mcr.microsoft.com/azure-cli:latest

# Download jq binary using curl (should be available in Azure CLI image)
RUN curl -L -o /usr/local/bin/jq https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 && \
  chmod +x /usr/local/bin/jq

# Copy the script file
COPY bulk-cleanup.sh /bulk-cleanup.sh

# Make script executable
RUN chmod +x /bulk-cleanup.sh

# Set the cleanup script as the default command
CMD ["/bin/bash", "/bulk-cleanup.sh"]
