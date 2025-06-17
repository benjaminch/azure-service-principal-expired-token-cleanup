# Azure service principal expired secrets cleanup

This tool is removing expired secrets from Azure service principals.

# Usage

Build the image:

```bash
docker build -t azure-bulk-cleanup .
```

Run it:

```bash
docker run --rm \
  -e DRY_RUN=true \
  -e AZURE_CLIENT_ID="your-client-id" \
  -e AZURE_CLIENT_SECRET="your-client-secret" \
  -e AZURE_TENANT_ID="your-tenant-id" \
  azure-bulk-cleanup
```
