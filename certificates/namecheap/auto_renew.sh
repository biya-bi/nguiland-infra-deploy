#!/usr/bin/env sh

set -eou pipefail

# 1. Define Git repository details
REPO_URL="https://github.com/acmesh-official/acme.sh.git"
TAG_NAME="3.1.2"
SOURCE_DIR="acme_source"

# 2. Clone the tag if it doesn't yet exist.
if [ ! -d "$SOURCE_DIR" ] || [ ! -f "$SOURCE_DIR/acme.sh" ]; then
    git clone --depth 1 --branch "$TAG_NAME" "$REPO_URL" "$SOURCE_DIR"
fi

# 3. Define the credentials directory and set appropriate permissions
CREDENTIALS_DIR="${HOME}/.nguiland/namecheap/credentials"
chmod 700 "${CREDENTIALS_DIR}"
chmod 600 "${CREDENTIALS_DIR}/"*

# 3. Enter the ACME source directory
cd "$SOURCE_DIR"

# 4. Define the ACME_HOME directory
ACME_HOME="${HOME}/.acme"

# 5. Read the credentials and remove any hidden characters or newlines to prevent API errors
EMAIL=$(cat "${CREDENTIALS_DIR}/email" | tr -d '\r\n')
USERNAME=$(cat "${CREDENTIALS_DIR}/username" | tr -d '\r\n')
API_KEY=$(cat "${CREDENTIALS_DIR}/api_key" | tr -d '\r\n')

# 6. Install acme.sh
./acme.sh --install  \
  --home "$ACME_HOME" \
  --accountemail  "$EMAIL"

# 7. Enter the ACME_HOME directory
cd "$ACME_HOME"

# 8. Register the account with Let's Encrypt
./acme.sh --register-account \
  -m "$EMAIL" \
  --server letsencrypt \
  --home "$ACME_HOME"

# 10. Export Namecheap credentials and source IP for the API hook
export NAMECHEAP_USERNAME="$USERNAME"
export NAMECHEAP_API_KEY="$API_KEY"
export NAMECHEAP_SOURCEIP=$(curl -s4 https://ifconfig.co/ip)

# 11. Issue the Wildcard Certificate
./acme.sh --issue --dns dns_namecheap \
  -d nguiland.org \
  -d '*.nguiland.org' \
  --server letsencrypt \
  --home "$ACME_HOME"

# 12. Install the certificate and set up the reload command for nginx
./acme.sh --install-cert -d nguiland.org \
  --key-file       /etc/letsencrypt/live/nguiland.org/privkey.pem  \
  --fullchain-file /etc/letsencrypt/live/nguiland.org/fullchain.pem \
  --reloadcmd     "service nginx force-reload"
