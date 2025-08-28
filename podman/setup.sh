#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
POSTIZ_DIR="/srv/postiz"

echo "Setting up Postiz service..."

# Verify service directories exist (should be created by services.sh)
echo "Verifying service directories..."
if [ ! -d "$POSTIZ_DIR" ]; then
    echo "Error: Service directory $POSTIZ_DIR does not exist"
    echo "This should be created by services.sh with proper permissions"
    exit 1
fi

# Create required subdirectories
echo "Creating required subdirectories..."
mkdir -p "$POSTIZ_DIR"/{config,uploads,postgres-data,redis-data}
chmod -R 755 "$POSTIZ_DIR"

# Set up environment file
echo "Setting up environment file..."
cp "$SCRIPT_DIR/postiz.env" "$POSTIZ_DIR/postiz.env"

# Update Quadlet files with actual paths
echo "Updating Quadlet files..."

# Process pod file
sed "s|ENV_FILE_PLACEHOLDER|$POSTIZ_DIR/postiz.env|g" "$SCRIPT_DIR/postiz.pod" > ~/.config/containers/systemd/postiz.pod

# Process postgres container file
sed -e "s|ENV_FILE_PLACEHOLDER|$POSTIZ_DIR/postiz.env|g" \
    -e "s|POSTGRES_VOLUME_PLACEHOLDER|$POSTIZ_DIR/postgres-data:/var/lib/postgresql/data:Z|g" \
    "$SCRIPT_DIR/postiz-postgres.container" > ~/.config/containers/systemd/postiz-postgres.container

# Process redis container file
sed "s|REDIS_VOLUME_PLACEHOLDER|$POSTIZ_DIR/redis-data:/data:Z|g" \
    "$SCRIPT_DIR/postiz-redis.container" > ~/.config/containers/systemd/postiz-redis.container

# Process main app container file
sed -e "s|ENV_FILE_PLACEHOLDER|$POSTIZ_DIR/postiz.env|g" \
    -e "s|CONFIG_VOLUME_PLACEHOLDER|$POSTIZ_DIR/config:/config:Z|g" \
    -e "s|UPLOADS_VOLUME_PLACEHOLDER|$POSTIZ_DIR/uploads:/uploads:Z|g" \
    "$SCRIPT_DIR/postiz.container" > ~/.config/containers/systemd/postiz.container

# Check Podman version and handle pod creation
PODMAN_VERSION=$(podman version --format "{{.Client.Version}}")
echo "Detected Podman version: $PODMAN_VERSION"

if echo "$PODMAN_VERSION" | grep -q "^4\."; then
    echo "Podman 4.x detected - manually creating pod..."
    
    # Clean up existing pod and containers if they exist
    podman pod stop postiz-pod 2>/dev/null || true
    podman ps -a --pod --filter pod=postiz-pod --format "{{.ID}}" | xargs -r podman rm -f 2>/dev/null || true
    podman pod rm -f postiz-pod 2>/dev/null || true
    
    # Create pod manually based on .pod file settings
    podman pod create \
        --name postiz-pod \
        --network bridge \
        --publish 8082:5000
    
    echo "Pod created manually for Podman 4.x compatibility"
fi

# Pre-pull images to avoid systemd timeouts
echo "Pre-pulling container images..."
podman pull docker.io/library/postgres:17-alpine
podman pull docker.io/library/redis:7.2
podman pull ghcr.io/gitroomhq/postiz-app:latest

# Reload systemd user daemon
echo "Reloading systemd daemon..."
systemctl --user daemon-reload

# Start services
echo "Starting Postiz services..."
systemctl --user start postiz-postgres.service
systemctl --user start postiz-redis.service
systemctl --user start postiz.service

echo "Postiz setup completed!"
echo "Access Postiz at: http://localhost:8082"